import Accelerate
import AVFoundation

/// Swift 原生音频增强管道 — 对标 Python 版 audio_enhance.py
///
/// 三步处理：
///   1. 高通滤波（4 阶级联双二阶 Biquad，80Hz 截止）
///   2. 谱减法降噪（STFT → 噪声估计 → 逐帧谱减 → ISTFT）
///   3. 动态范围压缩（低音量帧增益提升）
///
/// 使用 Accelerate.framework（vDSP FFT + vDSP 向量运算），零第三方依赖。
enum AudioEnhancer {

    // MARK: - 参数（与 Python audio_enhance.py 对齐）

    /// 高通滤波截止频率
    private static let hpCutoffHz: Float = 80.0
    /// 谱减法 — 用前 N 秒估计噪声
    private static let noiseEstSec: Float = 0.5
    /// 谱减法 — 过减保护（保留原始幅度的 5%）
    private static let spectralFloor: Float = 0.05
    /// 谱减法 — 过减系数
    private static let overSubtract: Float = 1.0
    /// FFT 窗口长度
    private static let nperseg: Int = 512
    /// FFT 重叠长度
    private static let noverlap: Int = 256
    /// 动态压缩 — 帧长 ms
    private static let compressFrameMs: Float = 30.0
    /// 动态压缩 — RMS 低于此值触发增益
    private static let compressRmsThresh: Float = 0.02
    /// 动态压缩 — 最大增益倍数
    private static let compressMaxGain: Float = 4.0
    /// 动态压缩 — 目标 RMS
    private static let compressTargetRms: Float = 0.06

    // MARK: - 公开 API

    /// 对 AVAudioPCMBuffer 仅做动态范围压缩（原地修改）
    /// 适用于实时 buffer：增强弱麦克风信号让 VAD 能正确检测语音
    /// 不做高通滤波和谱减法，避免短 buffer 上的 artifacts
    static func boostBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 100 else { return }
        let sampleRate = Float(buffer.format.sampleRate)
        var samples = Array(UnsafeBufferPointer(start: channelData, count: count))
        dynamicRangeCompress(&samples, sampleRate: sampleRate)
        for i in 0..<count {
            channelData[i] = max(-1.0, min(1.0, samples[i]))
        }
    }

    /// 对 AVAudioPCMBuffer 执行**实时安全**的轻量增强（原地修改）
    /// ⚠️ 实时 buffer（~0.1s）太短，不能做谱减法（需要完整音频估噪声）
    /// 只做：高通滤波 + 动态范围压缩 + 限幅
    static func enhance(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 100 else { return }

        let sampleRate = Float(buffer.format.sampleRate)
        var samples = Array(UnsafeBufferPointer(start: channelData, count: count))

        realtimeEnhanceInPlace(&samples, sampleRate: sampleRate)

        // 写回 buffer
        for i in 0..<count {
            channelData[i] = samples[i]
        }
    }

    /// 对 Float 数组执行**完整**三步增强（适用于 VAD 切出的语音段或文件）
    /// 需要至少 0.5 秒音频才能正确估计噪声
    static func enhance(samples: [Float], sampleRate: Float = 16000) -> [Float] {
        guard samples.count > 100 else { return samples }
        var result = samples
        // 语音段通常由 VAD 切出，前面可能没有纯噪声段
        // 如果太短（< 1 秒），只做轻量增强避免误伤
        let minSamplesForSpectral = Int(sampleRate * 1.0)
        if result.count >= minSamplesForSpectral {
            enhanceInPlace(&result, sampleRate: sampleRate)
        } else {
            realtimeEnhanceInPlace(&result, sampleRate: sampleRate)
        }
        return result
    }

    // MARK: - 核心管道

    /// 完整三步增强（文件级 / 长语音段 ≥ 1 秒）
    private static func enhanceInPlace(_ samples: inout [Float], sampleRate: Float) {
        // Step 1: 高通滤波
        highpassFilter(&samples, sampleRate: sampleRate)

        // Step 2: 谱减法降噪（需要足够长的音频来估计噪声）
        spectralSubtraction(&samples, sampleRate: sampleRate)

        // Step 3: 动态范围压缩
        dynamicRangeCompress(&samples, sampleRate: sampleRate)

        // 输出限幅 [-1, 1]（vDSP 向量化）
        var lo: Float = -1.0, hi: Float = 1.0
        samples.withUnsafeMutableBufferPointer { ptr in
            vDSP_vclip(ptr.baseAddress!, 1, &lo, &hi, ptr.baseAddress!, 1, vDSP_Length(ptr.count))
        }
    }

    /// 实时安全的轻量增强（短 buffer ≤ 0.2 秒）
    /// 跳过谱减法，避免在短片段上产生 artifacts（突突声）
    private static func realtimeEnhanceInPlace(_ samples: inout [Float], sampleRate: Float) {
        // Step 1: 高通滤波（去除低频噪声）
        highpassFilter(&samples, sampleRate: sampleRate)

        // Step 2: 跳过谱减法（短 buffer 无法正确估噪，会把人声当噪声减掉）

        // Step 3: 动态范围压缩（增强弱人声）
        dynamicRangeCompress(&samples, sampleRate: sampleRate)

        // 输出限幅 [-1, 1]（vDSP 向量化）
        var lo: Float = -1.0, hi: Float = 1.0
        samples.withUnsafeMutableBufferPointer { ptr in
            vDSP_vclip(ptr.baseAddress!, 1, &lo, &hi, ptr.baseAddress!, 1, vDSP_Length(ptr.count))
        }
    }

    // MARK: - Step 1: 高通滤波（4 阶 = 2 级联双二阶）

    /// 4 阶 Butterworth 高通滤波器，用 vDSP_biquad 实现
    private static func highpassFilter(_ samples: inout [Float], sampleRate: Float) {
        let nyquist = sampleRate / 2.0
        guard hpCutoffHz < nyquist else { return }

        // Butterworth 4 阶 = 2 级联 2 阶段
        // 每段的 Q 值：第一段 Q = 0.5412 (cos(3π/8)), 第二段 Q = 1.3066 (cos(π/8))
        let qValues: [Float] = [0.54119610, 1.3065630]
        let omega = 2.0 * Float.pi * hpCutoffHz / sampleRate

        // 构建 2 个双二阶节的系数
        var coefficients: [Double] = []
        for q in qValues {
            let (b0, b1, b2, a1, a2) = biquadHighpassCoeffs(omega: omega, q: q)
            // vDSP_biquad 期望 [b0, b1, b2, a1, a2] 格式
            coefficients.append(contentsOf: [b0, b1, b2, a1, a2])
        }

        // vDSP_biquadm_CreateSetup
        let floatCoeffs = coefficients.map { Float($0) }

        // 手动执行两级 biquad
        applyBiquadCascade(&samples, coeffs: floatCoeffs, numSections: 2)
    }

    /// 计算高通双二阶系数（Direct Form I）
    private static func biquadHighpassCoeffs(omega: Float, q: Float) -> (Double, Double, Double, Double, Double) {
        let sinW = sin(omega)
        let cosW = cos(omega)
        let alpha = sinW / (2.0 * q)

        let a0 = Double(1.0 + alpha)
        let b0 = Double((1.0 + cosW) / 2.0) / a0
        let b1 = Double(-(1.0 + cosW)) / a0
        let b2 = Double((1.0 + cosW) / 2.0) / a0
        let a1 = Double(-2.0 * cosW) / a0
        let a2 = Double(1.0 - alpha) / a0

        return (b0, b1, b2, a1, a2)
    }

    /// 手动执行级联双二阶滤波
    private static func applyBiquadCascade(_ samples: inout [Float], coeffs: [Float], numSections: Int) {
        let n = samples.count
        guard n > 0 else { return }

        for section in 0..<numSections {
            let offset = section * 5
            let b0 = coeffs[offset]
            let b1 = coeffs[offset + 1]
            let b2 = coeffs[offset + 2]
            let a1 = coeffs[offset + 3]
            let a2 = coeffs[offset + 4]

            var x1: Float = 0, x2: Float = 0
            var y1: Float = 0, y2: Float = 0

            for i in 0..<n {
                let x = samples[i]
                let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1
                x1 = x
                y2 = y1
                y1 = y
                samples[i] = y
            }
        }
    }

    // MARK: - Step 2: 谱减法降噪（STFT → 噪声估计 → 谱减 → ISTFT）

    private static func spectralSubtraction(_ samples: inout [Float], sampleRate: Float) {
        let n = samples.count
        guard n >= nperseg else { return }

        let hopSize = nperseg - noverlap  // 256
        let numFrames = (n - noverlap) / hopSize
        guard numFrames > 0 else { return }

        let window = cachedHannWindow
        let windowSq = cachedHannWindowSq
        let halfN = nperseg / 2 + 1  // 257
        let vHalfN = vDSP_Length(halfN)
        let vNperseg = vDSP_Length(nperseg)

        // 预分配帧级复用缓冲区
        var windowed = [Float](repeating: 0, count: nperseg)
        var subtracted = [Float](repeating: 0, count: halfN)
        var floorBuf = [Float](repeating: 0, count: halfN)

        // STFT — 计算每帧的幅度和相位
        var magnitudes = [[Float]](repeating: [Float](repeating: 0, count: halfN), count: numFrames)
        var phases = [[Float]](repeating: [Float](repeating: 0, count: halfN), count: numFrames)

        samples.withUnsafeBufferPointer { samplesPtr in
            for frame in 0..<numFrames {
                let start = frame * hopSize
                // ★ vDSP 窗口乘法（替代手写 for 循环）
                vDSP_vmul(samplesPtr.baseAddress! + start, 1, window, 1, &windowed, 1, vNperseg)
                let (mag, phase) = rfft(windowed)
                magnitudes[frame] = mag
                phases[frame] = phase
            }
        }

        // 噪声估计：取前 noiseEstSec 秒的帧
        let noiseFrameCount = max(1, min(numFrames, Int(noiseEstSec * sampleRate / Float(hopSize))))
        var noiseProfile = [Float](repeating: 0, count: halfN)
        // ★ vDSP 噪声累加（替代嵌套 for 循环）
        for frame in 0..<noiseFrameCount {
            vDSP_vadd(noiseProfile, 1, magnitudes[frame], 1, &noiseProfile, 1, vHalfN)
        }
        // ★ vDSP 噪声均值（替代标量乘法循环）
        var invNoiseFrames = 1.0 / Float(noiseFrameCount)
        vDSP_vsmul(noiseProfile, 1, &invNoiseFrames, &noiseProfile, 1, vHalfN)

        // ★ 预计算 overSubtract * noiseProfile（避免帧循环内重复计算）
        var scaledNoise = [Float](repeating: 0, count: halfN)
        var overSub = overSubtract
        vDSP_vsmul(noiseProfile, 1, &overSub, &scaledNoise, 1, vHalfN)

        // 谱减 + 过减保护（向量化）
        var floorCoeff = spectralFloor
        for frame in 0..<numFrames {
            // subtracted = mag - scaledNoise
            vDSP_vsub(scaledNoise, 1, magnitudes[frame], 1, &subtracted, 1, vHalfN)
            // floor = spectralFloor * mag
            vDSP_vsmul(magnitudes[frame], 1, &floorCoeff, &floorBuf, 1, vHalfN)
            // result = max(subtracted, floor)
            vDSP_vmax(subtracted, 1, floorBuf, 1, &magnitudes[frame], 1, vHalfN)
        }

        // ISTFT — 重建时域信号（overlap-add，向量化）
        var output = [Float](repeating: 0, count: n)
        var windowSum = [Float](repeating: 0, count: n)
        var windowedRecon = [Float](repeating: 0, count: nperseg)

        output.withUnsafeMutableBufferPointer { outPtr in
            windowSum.withUnsafeMutableBufferPointer { wsPtr in
                let outBase = outPtr.baseAddress!
                let wsBase = wsPtr.baseAddress!

                for frame in 0..<numFrames {
                    let start = frame * hopSize
                    let reconstructed = irfft(magnitudes: magnitudes[frame], phases: phases[frame], size: nperseg)

                    let addLen = min(nperseg, n - start)
                    let vAddLen = vDSP_Length(addLen)
                    // ★ vDSP overlap-add（替代手写 for 循环）
                    vDSP_vmul(reconstructed, 1, window, 1, &windowedRecon, 1, vAddLen)
                    vDSP_vadd(outBase + start, 1, windowedRecon, 1, outBase + start, 1, vAddLen)
                    vDSP_vadd(wsBase + start, 1, windowSq, 1, wsBase + start, 1, vAddLen)
                }
            }
        }

        // 归一化（除以窗口累加）
        output.withUnsafeMutableBufferPointer { outPtr in
            windowSum.withUnsafeBufferPointer { wsPtr in
                samples.withUnsafeMutableBufferPointer { sampPtr in
                    for i in 0..<n {
                        sampPtr[i] = wsPtr[i] > 1e-8 ? outPtr[i] / wsPtr[i] : 0
                    }
                }
            }
        }
    }

    /// 缓存 Hann 窗（512 长度，只计算一次）
    private static let cachedHannWindow: [Float] = {
        var w = [Float](repeating: 0, count: nperseg)
        vDSP_hann_window(&w, vDSP_Length(nperseg), Int32(vDSP_HANN_NORM))
        return w
    }()

    /// 缓存 Hann 窗的平方（用于 overlap-add 归一化）
    private static let cachedHannWindowSq: [Float] = {
        var sq = [Float](repeating: 0, count: nperseg)
        vDSP_vmul(cachedHannWindow, 1, cachedHannWindow, 1, &sq, 1, vDSP_Length(nperseg))
        return sq
    }()

    /// 缓存 FFT setup（nperseg=512，log2=9）
    private static let fftLog2n = vDSP_Length(log2(Float(nperseg)))
    private static let cachedFFTSetup: FFTSetup? = vDSP_create_fftsetup(
        vDSP_Length(log2(Float(512))), FFTRadix(kFFTRadix2)
    )

    /// 实数 FFT — 返回 (magnitudes, phases)，长度 N/2+1
    private static func rfft(_ input: [Float]) -> (magnitudes: [Float], phases: [Float]) {
        let n = input.count
        let halfN = n / 2 + 1
        let log2n = vDSP_Length(log2(Float(n)))

        guard let fftSetup = (n == nperseg) ? cachedFFTSetup : vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return ([Float](repeating: 0, count: halfN), [Float](repeating: 0, count: halfN))
        }
        // 只在非缓存时 defer destroy
        let shouldDestroy = (n != nperseg)
        defer { if shouldDestroy { vDSP_destroy_fftsetup(fftSetup) } }

        // 将实数输入打包为 split complex
        var realPart = [Float](repeating: 0, count: n / 2)
        var imagPart = [Float](repeating: 0, count: n / 2)

        input.withUnsafeBufferPointer { inPtr in
            var splitComplex = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
            inPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(n / 2))
            }
        }

        // 执行 FFT
        var splitComplex = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))

        // 缩放因子
        var scale: Float = 1.0 / Float(2 * n)
        vDSP_vsmul(realPart, 1, &scale, &realPart, 1, vDSP_Length(n / 2))
        vDSP_vsmul(imagPart, 1, &scale, &imagPart, 1, vDSP_Length(n / 2))

        // 提取幅度和相位
        var magnitudes = [Float](repeating: 0, count: halfN)
        var phases = [Float](repeating: 0, count: halfN)

        // DC 分量（打包在 realPart[0]）
        magnitudes[0] = abs(realPart[0])
        phases[0] = realPart[0] >= 0 ? 0 : Float.pi

        // Nyquist 分量（打包在 imagPart[0]）
        magnitudes[n / 2] = abs(imagPart[0])
        phases[n / 2] = imagPart[0] >= 0 ? 0 : Float.pi

        // 其他频率分量
        for k in 1..<(n / 2) {
            let re = realPart[k]
            let im = imagPart[k]
            magnitudes[k] = sqrtf(re * re + im * im)
            phases[k] = atan2f(im, re)
        }

        return (magnitudes, phases)
    }

    /// 逆实数 FFT — 从幅度和相位重建时域信号
    private static func irfft(magnitudes: [Float], phases: [Float], size: Int) -> [Float] {
        let n = size
        let log2n = vDSP_Length(log2(Float(n)))

        guard let fftSetup = (n == nperseg) ? cachedFFTSetup : vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return [Float](repeating: 0, count: n)
        }
        let shouldDestroy = (n != nperseg)
        defer { if shouldDestroy { vDSP_destroy_fftsetup(fftSetup) } }

        // 重建 split complex
        var realPart = [Float](repeating: 0, count: n / 2)
        var imagPart = [Float](repeating: 0, count: n / 2)

        // DC → realPart[0], Nyquist → imagPart[0]（vDSP 打包格式）
        realPart[0] = magnitudes[0] * cos(phases[0])
        imagPart[0] = magnitudes[n / 2] * cos(phases[n / 2])

        for k in 1..<(n / 2) {
            realPart[k] = magnitudes[k] * cos(phases[k])
            imagPart[k] = magnitudes[k] * sin(phases[k])
        }

        // 执行逆 FFT
        var splitComplex = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Inverse))

        // 解包为实数
        var output = [Float](repeating: 0, count: n)
        output.withUnsafeMutableBufferPointer { outPtr in
            outPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                vDSP_ztoc(&splitComplex, 1, complexPtr, 2, vDSP_Length(n / 2))
            }
        }

        return output
    }

    // MARK: - Step 3: 动态范围压缩

    private static func dynamicRangeCompress(_ samples: inout [Float], sampleRate: Float) {
        let frameSize = Int(compressFrameMs * sampleRate / 1000.0)
        guard frameSize > 0, samples.count >= frameSize else { return }

        let numFrames = samples.count / frameSize

        samples.withUnsafeMutableBufferPointer { ptr in
            let base = ptr.baseAddress!
            for f in 0..<numFrames {
                let start = f * frameSize
                // ★ vDSP RMS 计算
                var rms: Float = 0
                vDSP_rmsqv(base + start, 1, &rms, vDSP_Length(frameSize))

                if rms < 1e-8 { continue }

                if rms < compressRmsThresh {
                    var gain = min(compressTargetRms / rms, compressMaxGain)
                    // ★ vDSP 批量乘法
                    vDSP_vsmul(base + start, 1, &gain, base + start, 1, vDSP_Length(frameSize))
                }
            }

            // 处理尾部剩余
            let remainderStart = numFrames * frameSize
            let tailCount = ptr.count - remainderStart
            if tailCount > 0 {
                var rms: Float = 0
                vDSP_rmsqv(base + remainderStart, 1, &rms, vDSP_Length(tailCount))
                if rms > 1e-8, rms < compressRmsThresh {
                    var gain = min(compressTargetRms / rms, compressMaxGain)
                    vDSP_vsmul(base + remainderStart, 1, &gain, base + remainderStart, 1, vDSP_Length(tailCount))
                }
            }
        }
    }

    // MARK: - 文件读取 + 增强

    /// 读取音频文件并重采样到目标格式（16kHz Float32 Mono），不做增强
    /// 供外部 VAD 分段流程使用
    static func readAndResample(url: URL, targetSampleRate: Int32 = 16000) -> (samples: [Float], sampleRate: Int32)? {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard frameCount > 0 else { return nil }

            if Int32(format.sampleRate) == targetSampleRate,
               format.channelCount == 1,
               format.commonFormat == .pcmFormatFloat32 {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
                try audioFile.read(into: buffer)
                guard let channelData = buffer.floatChannelData?[0] else { return nil }
                let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
                return (samples, targetSampleRate)
            }

            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(targetSampleRate),
                channels: 1,
                interleaved: false
            ) else { return nil }

            guard let converter = AVAudioConverter(from: format, to: targetFormat) else { return nil }
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
            try audioFile.read(into: inputBuffer)

            let outputFrameCount = AVAudioFrameCount(
                Double(frameCount) * Double(targetSampleRate) / format.sampleRate
            )
            guard outputFrameCount > 0 else { return nil }
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return nil }

            var error: NSError?
            var hasProvidedInput = false
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if hasProvidedInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                hasProvidedInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            guard error == nil else { return nil }

            guard let channelData = outputBuffer.floatChannelData?[0] else { return nil }
            let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))
            print("[AudioEnhancer] readAndResample: \(frameCount)帧 → \(samples.count)帧 (\(String(format: "%.1f", Double(samples.count)/Double(targetSampleRate)))s)")
            return (samples, targetSampleRate)

        } catch {
            print("[AudioEnhancer] 读取音频文件失败: \(error)")
            return nil
        }
    }

    /// 读取音频文件并执行完整三步增强，返回增强后的 samples 和采样率
    /// 支持 AVFoundation 可识别的所有格式（wav/caf/m4a/aiff 等）
    static func enhanceFile(url: URL, targetSampleRate: Int32 = 16000) -> (samples: [Float], sampleRate: Int32)? {
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let format = audioFile.processingFormat
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard frameCount > 0 else { return nil }

            // 如果文件格式已是目标格式（16kHz Float32 Mono），直接读取
            if Int32(format.sampleRate) == targetSampleRate,
               format.channelCount == 1,
               format.commonFormat == .pcmFormatFloat32 {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
                try audioFile.read(into: buffer)
                guard let channelData = buffer.floatChannelData?[0] else { return nil }
                var samples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
                enhanceInPlace(&samples, sampleRate: Float(targetSampleRate))
                return (samples, targetSampleRate)
            }

            // 需要格式转换（重采样 + 单声道）
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(targetSampleRate),
                channels: 1,
                interleaved: false
            ) else { return nil }

            guard let converter = AVAudioConverter(from: format, to: targetFormat) else { return nil }

            // 读取原始数据
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
            try audioFile.read(into: inputBuffer)

            // 计算输出帧数
            let outputFrameCount = AVAudioFrameCount(
                Double(frameCount) * Double(targetSampleRate) / format.sampleRate
            )
            guard outputFrameCount > 0 else { return nil }
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return nil }

            var error: NSError?
            var hasProvidedInput = false
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if hasProvidedInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                hasProvidedInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            guard error == nil else { return nil }

            guard let channelData = outputBuffer.floatChannelData?[0] else { return nil }
            var samples = Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))
            enhanceInPlace(&samples, sampleRate: Float(targetSampleRate))
            return (samples, targetSampleRate)

        } catch {
            print("[AudioEnhancer] 读取音频文件失败: \(error)")
            return nil
        }
    }
}
