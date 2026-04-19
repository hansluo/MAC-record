import AVFoundation
import Combine
import Darwin.libkern.OSAtomic

/// AVAudioEngine 实时录音器
@MainActor
class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var recentLevels: [Float] = []

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioFile: AVAudioFile?
    private var timer: Timer?
    private var startTime: Date?
    private var pausedDuration: TimeInterval = 0
    private var pauseStartTime: Date?

    /// 线程安全的暂停标志（音频线程读，主线程写）
    nonisolated(unsafe) private let _isPausedAtomic = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    /// 16kHz mono PCM buffer 回调（用于 SenseVoice ASR + 写文件）
    /// nonisolated(unsafe) 允许在音频线程中调用
    nonisolated(unsafe) var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// 原始采样率 buffer 回调（用于 Apple Speech）
    nonisolated(unsafe) var onRawAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// 录音文件 URL
    private(set) var recordingURL: URL?

    init() {
        _isPausedAtomic.initialize(to: 0)
    }

    deinit {
        _isPausedAtomic.deallocate()
    }

    /// 线程安全地读取暂停状态
    private nonisolated func isCurrentlyPaused() -> Bool {
        OSAtomicAdd32(0, _isPausedAtomic) != 0
    }

    // MARK: - 录音控制

    func startRecording(deviceUID: String? = nil) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatError
        }

        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            throw RecorderError.converterError
        }

        let url = AudioFileManager.shared.createTempRecordingURL()
        self.recordingURL = url

        let outputFile = try AVAudioFile(
            forWriting: url,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.audioFile = outputFile

        // ★ 关键改动：bufferSize 改小（0.1s），让 Apple Speech 更快出文字
        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(format.sampleRate * 0.1)
        // ★ 捕获需要在音频线程使用的引用（避免跨 actor 访问）
        let pausedFlag = _isPausedAtomic
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, time in
            // 线程安全读取暂停状态
            guard OSAtomicAdd32(0, pausedFlag) == 0 else { return }

            // 原始 buffer 回调（Apple Speech 需要原始采样率 + 小 buffer 才能快速出文字）
            self?.onRawAudioBuffer?(buffer)

            // 转换为 16kHz mono
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / format.sampleRate
            )
            guard frameCount > 0 else { return }
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCount
            ) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error, error == nil else { return }

            // 写入文件（原始 16kHz PCM）
            try? outputFile.write(from: convertedBuffer)

            // ★ 对发给 ASR 的 buffer 做动态范围压缩（增强弱麦克风信号）
            // 注意：只压缩发给 ASR 的副本，文件保留原始音频
            // 动态压缩对短 buffer 安全，不会产生 artifacts
            AudioEnhancer.boostBuffer(convertedBuffer)

            // 计算音频电平
            if let channelData = convertedBuffer.floatChannelData?[0] {
                let count = Int(convertedBuffer.frameLength)
                var rms: Float = 0
                for i in 0..<count {
                    rms += channelData[i] * channelData[i]
                }
                rms = sqrt(rms / Float(max(count, 1)))

                // ★ 用 Task 异步更新避免 "Publishing changes from within view updates"
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.recentLevels.append(rms)
                    if self.recentLevels.count > 150 {
                        self.recentLevels.removeFirst(self.recentLevels.count - 150)
                    }
                }
            }

            // 16kHz buffer 回调（SenseVoice ASR）
            self?.onAudioBuffer?(convertedBuffer)
        }

        try engine.start()

        self.audioEngine = engine
        self.inputNode = input
        self.isRecording = true
        self.isPaused = false
        self.startTime = Date()
        self.pausedDuration = 0
        self.recentLevels = []

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateElapsedTime()
            }
        }
    }

    // MARK: - 仅写文件模式（Apple Speech 用）

    /// 准备写文件（不启动 AVAudioEngine），返回录音文件 URL
    func prepareFileOnly() throws -> URL {
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let url = AudioFileManager.shared.createTempRecordingURL()
        self.recordingURL = url
        let file = try AVAudioFile(
            forWriting: url,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.audioFile = file
        self.isRecording = true
        self.startTime = Date()
        self.pausedDuration = 0
        self.recentLevels = []
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateElapsedTime() }
        }
        return url
    }

    private var fileWriteConverter: AVAudioConverter?
    private var fileWriteFormat: AVAudioFormat?

    /// 从外部 engine（如 Apple Speech）接收 buffer 并转换写入 16kHz WAV
    func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let outputFile = audioFile else { return }
        let srcFormat = buffer.format
        let targetSR = 16000.0

        // 如果格式已经是 16kHz mono float32，直接写
        if srcFormat.sampleRate == targetSR && srcFormat.channelCount == 1 && srcFormat.commonFormat == .pcmFormatFloat32 {
            try? outputFile.write(from: buffer)
            return
        }

        // 需要转换
        if fileWriteConverter == nil || fileWriteFormat != srcFormat {
            let tgt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSR, channels: 1, interleaved: false)!
            fileWriteConverter = AVAudioConverter(from: srcFormat, to: tgt)
            fileWriteFormat = srcFormat
        }
        guard let converter = fileWriteConverter else { return }

        let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * targetSR / srcFormat.sampleRate)
        guard outFrames > 0 else { return }
        let tgtFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSR, channels: 1, interleaved: false)!
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: tgtFmt, frameCapacity: outFrames) else { return }

        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil else { return }
        try? outputFile.write(from: outBuf)

        // 更新电平
        if let cd = outBuf.floatChannelData?[0] {
            let count = Int(outBuf.frameLength)
            var rms: Float = 0
            for i in 0..<count { rms += cd[i] * cd[i] }
            rms = sqrt(rms / Float(max(count, 1)))
            Task { @MainActor [weak self] in
                self?.recentLevels.append(rms)
                if (self?.recentLevels.count ?? 0) > 150 { self?.recentLevels.removeFirst() }
            }
        }
    }

    // MARK: - 轻量模式（语音输入用，不写文件）

    /// 启动轻量录音（仅 AVAudioEngine + buffer 回调，不创建文件）
    /// 用于语音输入场景，音频仅通过 onAudioBuffer 发给 ASR
    func startRecordingLite() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatError
        }

        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
            throw RecorderError.converterError
        }

        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(format.sampleRate * 0.1)
        let pausedFlag = _isPausedAtomic
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            guard OSAtomicAdd32(0, pausedFlag) == 0 else { return }

            // 转换为 16kHz mono
            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * targetFormat.sampleRate / format.sampleRate
            )
            guard frameCount > 0 else { return }
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCount
            ) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else { return }

            // 动态压缩增强弱麦克风信号
            AudioEnhancer.boostBuffer(convertedBuffer)

            // 更新电平
            if let channelData = convertedBuffer.floatChannelData?[0] {
                let count = Int(convertedBuffer.frameLength)
                var rms: Float = 0
                for i in 0..<count { rms += channelData[i] * channelData[i] }
                rms = sqrt(rms / Float(max(count, 1)))
                Task { @MainActor [weak self] in
                    self?.recentLevels.append(rms)
                    if (self?.recentLevels.count ?? 0) > 150 { self?.recentLevels.removeFirst() }
                }
            }

            // 16kHz buffer 回调（给 ASR）
            self?.onAudioBuffer?(convertedBuffer)
        }

        try engine.start()

        self.audioEngine = engine
        self.inputNode = input
        self.audioFile = nil
        self.recordingURL = nil
        self.isRecording = true
        self.isPaused = false
        self.startTime = Date()
        self.pausedDuration = 0
        self.recentLevels = []
    }

    /// 停止轻量录音（不返回文件 URL）
    func stopRecordingLite() {
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        isRecording = false
        isPaused = false
        audioEngine = nil
        inputNode = nil
        recentLevels = []
    }

    func pauseRecording() {
        isPaused = true
        OSAtomicCompareAndSwap32(0, 1, _isPausedAtomic)
        pauseStartTime = Date()
        audioEngine?.pause()
    }

    func resumeRecording() {
        if let pauseStart = pauseStartTime {
            pausedDuration += Date().timeIntervalSince(pauseStart)
        }
        pauseStartTime = nil
        isPaused = false
        OSAtomicCompareAndSwap32(1, 0, _isPausedAtomic)
        try? audioEngine?.start()
    }

    func stopRecording() -> URL? {
        timer?.invalidate()
        timer = nil

        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()

        isRecording = false
        isPaused = false

        audioEngine = nil
        inputNode = nil
        audioFile = nil

        return recordingURL
    }

    private func updateElapsedTime() {
        guard let start = startTime else { return }
        var elapsed = Date().timeIntervalSince(start) - pausedDuration
        if isPaused, let pauseStart = pauseStartTime {
            elapsed -= Date().timeIntervalSince(pauseStart)
        }
        elapsedTime = max(0, elapsed)
    }
}

enum RecorderError: LocalizedError {
    case formatError
    case converterError
    case noPermission

    var errorDescription: String? {
        switch self {
        case .formatError: return "无法创建音频格式"
        case .converterError: return "无法创建音频转换器"
        case .noPermission: return "没有麦克风权限"
        }
    }
}
