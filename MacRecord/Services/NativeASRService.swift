import Foundation
import AVFoundation

/// 原生 SenseVoice ASR 服务 — VAD + 分段离线识别 = 流式效果
///
/// 架构：
///   音频流 → Silero VAD（实时检测语音段） → 检测到一段说完 → SenseVoice 离线识别
///   → 拼接到已有文本 → UI 实时更新
///
/// 比之前的"累积 3 秒做一次"方案优势：
/// - VAD 精确切分，不会把句子切断
/// - 说完一句立刻出结果，延迟更低
/// - 不会在静音期浪费计算
actor NativeASRService {

    // MARK: - 数据结构

    struct TranscribeResult {
        let plainText: String
        let detectedLanguage: String?
        let emotion: String?
        let duration: Double?
    }

    struct RealtimeSnapshot {
        let plainText: String
        /// 当前是否检测到语音
        let isSpeaking: Bool
    }

    // MARK: - 状态

    private var recognizer: SherpaOnnxOfflineRecognizerWrapper?
    private var isReady = false
    private var vadModelPath: String?

    /// 实时会话
    private var realtimeSessions: [String: RealtimeSession] = [:]

    private class RealtimeSession {
        let vad: SherpaOnnxVADWrapper
        let recognizer: SherpaOnnxOfflineRecognizerWrapper
        var confirmedSegments: [String] = []  // 已确认的段落文本
        var pendingText: String = ""           // 当前正在说的（尚未确认）
        let startTime: Date = Date()
        var sampleBuffer: [Float] = []         // VAD window 对齐缓冲
        var totalSamplesProcessed: Int = 0
        var pendingSegmentQueue: [[Float]] = [] // 待处理的语音段队列（不丢弃）
        var isProcessingSegment = false         // 防止并发识别

        init(vad: SherpaOnnxVADWrapper, recognizer: SherpaOnnxOfflineRecognizerWrapper) {
            self.vad = vad
            self.recognizer = recognizer
        }

        /// 处理队列中下一个待处理的语音段
        func processNextSegment() {
            guard !isProcessingSegment, !pendingSegmentQueue.isEmpty else { return }
            isProcessingSegment = true
            let segSamples = pendingSegmentQueue.removeFirst()
            let enhanced = AudioEnhancer.enhance(samples: segSamples, sampleRate: 16000)
            let text = recognizer.recognize(
                samples: enhanced,
                sampleRate: 16000
            ).text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                confirmedSegments.append(text)
            }
            pendingText = ""
            isProcessingSegment = false

            // 递归处理队列中的下一个（如果有）
            processNextSegment()
        }

        /// 当前完整文本
        var fullText: String {
            let confirmed = confirmedSegments.joined(separator: "")
            if pendingText.isEmpty {
                return confirmed
            }
            return confirmed + pendingText
        }
    }

    // MARK: - 模型路径

    private static func findModelDir() -> URL? {
        if let bundlePath = Bundle.main.resourceURL {
            if FileManager.default.fileExists(atPath: bundlePath.appendingPathComponent("model.int8.onnx").path) {
                return bundlePath
            }
            let bundleModel = bundlePath.appendingPathComponent("sensevoice-model")
            if FileManager.default.fileExists(atPath: bundleModel.appendingPathComponent("model.int8.onnx").path) {
                return bundleModel
            }
        }

        let projectModel = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/Mac-Record/MacRecord/Resources/sensevoice-model")
        if FileManager.default.fileExists(atPath: projectModel.appendingPathComponent("model.int8.onnx").path) {
            return projectModel
        }

        return nil
    }

    private static func findVADModel() -> String? {
        // 1. Bundle 根目录
        if let bundlePath = Bundle.main.resourceURL {
            let p = bundlePath.appendingPathComponent("silero_vad.onnx").path
            if FileManager.default.fileExists(atPath: p) { return p }
            // vad 子目录
            let p2 = bundlePath.appendingPathComponent("vad/silero_vad.onnx").path
            if FileManager.default.fileExists(atPath: p2) { return p2 }
        }

        // 2. 项目 Resources
        let projectVAD = NSHomeDirectory() + "/Desktop/Mac-Record/MacRecord/Resources/vad/silero_vad.onnx"
        if FileManager.default.fileExists(atPath: projectVAD) { return projectVAD }

        return nil
    }

    // MARK: - 生命周期

    func initialize() throws -> String {
        guard !isReady else { return "✅ SenseVoice (原生流式) 已就绪" }

        guard let modelDir = NativeASRService.findModelDir() else {
            throw NativeASRError.modelNotFound("未找到 SenseVoice 模型文件")
        }

        let modelPath = modelDir.appendingPathComponent("model.int8.onnx").path
        let tokensPath = modelDir.appendingPathComponent("tokens.txt").path

        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw NativeASRError.modelNotFound("模型文件不存在: \(modelPath)")
        }

        guard let vadPath = NativeASRService.findVADModel() else {
            throw NativeASRError.modelNotFound("未找到 Silero VAD 模型")
        }

        var config = SherpaOnnxOfflineRecognizerSwiftConfig()
        config.senseVoiceModelPath = modelPath
        config.tokensPath = tokensPath
        config.language = "auto"
        config.useITN = true
        config.numThreads = 4
        config.sampleRate = 16000
        config.featureDim = 80
        config.decodingMethod = "greedy_search"
        config.provider = "cpu"

        guard let rec = SherpaOnnxOfflineRecognizerWrapper(config: config) else {
            throw NativeASRError.initFailed("SherpaOnnx OfflineRecognizer 初始化失败")
        }

        self.recognizer = rec
        self.vadModelPath = vadPath
        self.isReady = true
        print("[NativeASR] SenseVoice + Silero VAD 初始化成功")
        return "✅ SenseVoice (原生流式) 已就绪"
    }

    func getModelStatus() -> String {
        isReady ? "✅ SenseVoice (原生流式) 已就绪" : "⏳ SenseVoice 未初始化"
    }

    func shutdown() {
        recognizer = nil
        realtimeSessions.removeAll()
        isReady = false
    }

    // MARK: - 文件转录

    func transcribeFile(audioPath: String, language: String = "auto") throws -> TranscribeResult {
        guard let recognizer = recognizer, let vadPath = vadModelPath else {
            throw NativeASRError.notReady
        }

        let totalStart = CFAbsoluteTimeGetCurrent()

        // ★ 1. 读取音频并重采样到 16kHz mono（不做增强）
        let fileURL = URL(fileURLWithPath: audioPath)
        guard let raw = AudioEnhancer.readAndResample(url: fileURL) else {
            // Fallback：读取失败时直接用原始文件识别
            print("[NativeASR] readAndResample 失败，fallback 到原始路径")
            let result = recognizer.recognizeFile(path: audioPath)
            return TranscribeResult(
                plainText: result.text,
                detectedLanguage: result.lang,
                emotion: result.emotion,
                duration: nil
            )
        }

        let audioDuration = Double(raw.samples.count) / Double(raw.sampleRate)

        // ★ 2. VAD 分段 — 将完整音频切分为语音段
        // 文件转录需要足够大的 VAD 缓冲区（至少覆盖音频时长 + 余量）
        let vadBufferSize = max(120.0, Float(audioDuration) + 60.0)
        guard let vad = SherpaOnnxVADWrapper(modelPath: vadPath, bufferSizeInSeconds: vadBufferSize) else {
            // VAD 创建失败，fallback 到整段增强+识别
            print("[NativeASR] 文件转录 VAD 创建失败，fallback 到整段识别")
            var samples = raw.samples
            let enhStart = CFAbsoluteTimeGetCurrent()
            samples = AudioEnhancer.enhance(samples: samples, sampleRate: Float(raw.sampleRate))
            let enhTime = CFAbsoluteTimeGetCurrent() - enhStart
            let recStart = CFAbsoluteTimeGetCurrent()
            let result = recognizer.recognize(samples: samples, sampleRate: raw.sampleRate)
            let recTime = CFAbsoluteTimeGetCurrent() - recStart
            print("[NativeASR] 文件转录(fallback): 增强=\(String(format: "%.2f", enhTime))s 识别=\(String(format: "%.2f", recTime))s")
            return TranscribeResult(
                plainText: result.text,
                detectedLanguage: result.lang,
                emotion: result.emotion,
                duration: audioDuration
            )
        }

        let vadStart = CFAbsoluteTimeGetCurrent()
        let windowSize = Int(vad.windowSize)
        var offset = 0

        // 逐窗喂入 VAD
        raw.samples.withUnsafeBufferPointer { ptr in
            while offset + windowSize <= raw.samples.count {
                vad.acceptWaveform(samples: ptr.baseAddress! + offset, count: Int32(windowSize))
                offset += windowSize
            }
        }
        // 尾部填零喂入
        if offset < raw.samples.count {
            var tail = Array(raw.samples[offset...])
            tail.append(contentsOf: [Float](repeating: 0, count: windowSize - tail.count))
            tail.withUnsafeBufferPointer { ptr in
                vad.acceptWaveform(samples: ptr.baseAddress!, count: Int32(windowSize))
            }
        }
        vad.flush()

        // 收集所有语音段
        var speechSegments: [[Float]] = []
        while vad.hasSegment {
            if let (segSamples, _) = vad.popFrontSegment() {
                speechSegments.append(segSamples)
            }
        }
        let vadTime = CFAbsoluteTimeGetCurrent() - vadStart

        // 如果 VAD 没检测到任何语音段，用整段识别
        if speechSegments.isEmpty {
            print("[NativeASR] 文件转录: VAD 未检测到语音段，整段识别")
            var samples = raw.samples
            samples = AudioEnhancer.enhance(samples: samples, sampleRate: Float(raw.sampleRate))
            let result = recognizer.recognize(samples: samples, sampleRate: raw.sampleRate)
            return TranscribeResult(
                plainText: result.text,
                detectedLanguage: result.lang,
                emotion: result.emotion,
                duration: audioDuration
            )
        }

        // ★ 3. 逐段增强 + 识别
        var confirmedTexts: [String] = []
        var firstLang: String?
        var firstEmotion: String?
        var totalEnhTime: Double = 0
        var totalRecTime: Double = 0

        for (idx, segSamples) in speechSegments.enumerated() {
            let segDur = Double(segSamples.count) / Double(raw.sampleRate)
            let enhStart = CFAbsoluteTimeGetCurrent()
            let enhanced = AudioEnhancer.enhance(samples: segSamples, sampleRate: Float(raw.sampleRate))
            totalEnhTime += CFAbsoluteTimeGetCurrent() - enhStart

            let recStart = CFAbsoluteTimeGetCurrent()
            let result = recognizer.recognize(samples: enhanced, sampleRate: raw.sampleRate)
            totalRecTime += CFAbsoluteTimeGetCurrent() - recStart

            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                confirmedTexts.append(text)
            }
            if idx == 0 {
                firstLang = result.lang
                firstEmotion = result.emotion
            }
            print("[NativeASR] 段\(idx+1)/\(speechSegments.count): \(String(format: "%.1f", segDur))s → \"\(text.prefix(30))\"")
        }

        let totalTime = CFAbsoluteTimeGetCurrent() - totalStart
        let speechRatio = speechSegments.reduce(0) { $0 + $1.count } * 100 / raw.samples.count
        print("[NativeASR] 文件转录完成: \(speechSegments.count)段, 语音占比\(speechRatio)%, VAD=\(String(format: "%.2f", vadTime))s 增强=\(String(format: "%.2f", totalEnhTime))s 识别=\(String(format: "%.2f", totalRecTime))s 总计=\(String(format: "%.2f", totalTime))s")

        let finalText = confirmedTexts.joined(separator: "")
        return TranscribeResult(
            plainText: finalText,
            detectedLanguage: firstLang,
            emotion: firstEmotion,
            duration: audioDuration
        )
    }

    // MARK: - 实时流式转录

    func realtimeStart(sessionId: String, language: String) {
        guard let recognizer = recognizer, let vadPath = vadModelPath else { return }
        guard let vad = SherpaOnnxVADWrapper(modelPath: vadPath) else {
            print("[NativeASR] VAD 创建失败")
            return
        }

        let session = RealtimeSession(vad: vad, recognizer: recognizer)
        realtimeSessions[sessionId] = session
        print("[NativeASR] 流式会话启动: \(sessionId)")
    }

    /// 语音输入模式专用 — 更快的 VAD 响应（min_silence_duration=0.2s）
    func realtimeStartForVoiceInput(sessionId: String) {
        guard let recognizer = recognizer, let vadPath = vadModelPath else { return }
        guard let vad = SherpaOnnxVADWrapper(modelPath: vadPath, minSilenceDuration: 0.2) else {
            print("[NativeASR] VAD 创建失败 (voiceInput)")
            return
        }

        let session = RealtimeSession(vad: vad, recognizer: recognizer)
        realtimeSessions[sessionId] = session
        print("[NativeASR] 语音输入会话启动: \(sessionId)")
    }

    /// 喂入 PCM Float32 数据（16kHz mono）
    /// 返回当前实时文本
    func realtimeFeed(sessionId: String, samples: [Float]) -> String {
        guard let session = realtimeSessions[sessionId] else { return "" }

        // 将新数据追加到缓冲
        session.sampleBuffer.append(contentsOf: samples)
        session.totalSamplesProcessed += samples.count

        let windowSize = Int(session.vad.windowSize)

        // 按 VAD window size (512) 逐窗喂入
        while session.sampleBuffer.count >= windowSize {
            let window = Array(session.sampleBuffer.prefix(windowSize))
            session.sampleBuffer.removeFirst(windowSize)

            window.withUnsafeBufferPointer { ptr in
                session.vad.acceptWaveform(samples: ptr.baseAddress!, count: Int32(windowSize))
            }

            // ★ 所有完成的语音段入队（不丢弃）
            while session.vad.hasSegment {
                if let (segSamples, _) = session.vad.popFrontSegment() {
                    session.pendingSegmentQueue.append(segSamples)
                }
            }
        }

        // 处理队列中的段（串行处理，不阻塞新数据入队）
        session.processNextSegment()

        return session.fullText
    }

    /// 喂入 Base64 编码的 Float32 PCM 数据
    func realtimeFeedBase64(sessionId: String, audioBase64: String) -> String {
        guard let data = Data(base64Encoded: audioBase64) else { return "" }
        let floatCount = data.count / MemoryLayout<Float>.size
        let samples = data.withUnsafeBytes { buffer -> [Float] in
            let floatBuffer = buffer.bindMemory(to: Float.self)
            return Array(floatBuffer.prefix(floatCount))
        }
        return realtimeFeed(sessionId: sessionId, samples: samples)
    }

    /// 获取实时快照
    func getRealtimeSnapshot(sessionId: String) -> RealtimeSnapshot {
        guard let session = realtimeSessions[sessionId] else {
            return RealtimeSnapshot(plainText: "", isSpeaking: false)
        }

        return RealtimeSnapshot(
            plainText: session.fullText,
            isSpeaking: session.vad.isSpeechDetected
        )
    }

    /// 快速获取当前已确认文本（不等待队列处理完成）
    /// 用于语音输入等需要快速响应的场景
    func realtimeGetConfirmedText(sessionId: String) -> String {
        guard let session = realtimeSessions[sessionId] else { return "" }
        return session.fullText
    }

    /// 停止实时会话，只处理 VAD 尾部的最后一段
    /// 已确认的段不再重新处理，确保快速返回
    func realtimeStop(sessionId: String) throws -> TranscribeResult {
        guard let session = realtimeSessions[sessionId] else {
            throw NativeASRError.sessionNotFound(sessionId)
        }
        defer { realtimeSessions.removeValue(forKey: sessionId) }

        let stopStart = CFAbsoluteTimeGetCurrent()

        // ★ 1. flush VAD 尾部缓冲（把最后的语音段也弹出来）
        let windowSize = Int(session.vad.windowSize)
        if !session.sampleBuffer.isEmpty {
            let padding = windowSize - session.sampleBuffer.count % windowSize
            if padding < windowSize {
                session.sampleBuffer.append(contentsOf: [Float](repeating: 0, count: padding))
            }
            while session.sampleBuffer.count >= windowSize {
                let window = Array(session.sampleBuffer.prefix(windowSize))
                session.sampleBuffer.removeFirst(windowSize)
                window.withUnsafeBufferPointer { ptr in
                    session.vad.acceptWaveform(samples: ptr.baseAddress!, count: Int32(windowSize))
                }
            }
        }

        session.vad.flush()

        // ★ 2. 只处理 VAD flush 出来的尾部新段（通常 0-1 段）
        var tailSegmentCount = 0
        while session.vad.hasSegment {
            if let (segSamples, _) = session.vad.popFrontSegment() {
                let enhanced = AudioEnhancer.enhance(samples: segSamples, sampleRate: 16000)
                let text = session.recognizer.recognize(
                    samples: enhanced,
                    sampleRate: 16000
                ).text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    session.confirmedSegments.append(text)
                }
                tailSegmentCount += 1
            }
        }

        // ★ 3. 处理队列中还没来得及处理的积压段（如果有的话）
        session.isProcessingSegment = false
        session.processNextSegment()

        let finalText = session.confirmedSegments.joined(separator: "")
        let duration = Date().timeIntervalSince(session.startTime)
        let stopTime = CFAbsoluteTimeGetCurrent() - stopStart

        print("[NativeASR] 流式会话结束: \(sessionId), 段数: \(session.confirmedSegments.count), 尾部段: \(tailSegmentCount), stop耗时: \(String(format: "%.2f", stopTime))s, 文本: \(finalText.prefix(50))...")
        return TranscribeResult(
            plainText: finalText,
            detectedLanguage: nil,
            emotion: nil,
            duration: duration
        )
    }
}

// MARK: - Errors

enum NativeASRError: LocalizedError {
    case modelNotFound(String)
    case initFailed(String)
    case notReady
    case sessionNotFound(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let msg): return "模型未找到: \(msg)"
        case .initFailed(let msg): return "初始化失败: \(msg)"
        case .notReady: return "ASR 引擎未就绪"
        case .sessionNotFound(let id): return "会话不存在: \(id)"
        }
    }
}
