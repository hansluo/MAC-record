import Foundation
import AVFoundation

/// 原生 ASR 服务 — VAD + 分段离线识别 = 流式效果
///
/// 架构：
///   音频流 → Silero VAD（实时检测语音段） → 检测到一段说完 → 离线识别
///   → 拼接到已有文本 → UI 实时更新
///
/// 支持 SenseVoice 和 Qwen3-ASR 模型族
actor NativeASRService {

    // MARK: - 数据结构

    struct TranscribeResult {
        let plainText: String
        let detectedLanguage: String?
        let emotion: String?
        let duration: Double?
    }

    /// 说话人分离 + ASR 合并结果
    struct DiarizedTranscribeResult {
        let text: String                 // 带说话人标签的完整文本
        let numSpeakers: Int32
        let segments: [SpeakerSegment]   // 每段详情

        struct SpeakerSegment {
            let speaker: Int32
            let start: Float
            let end: Float
            let text: String
        }
    }

    struct RealtimeSnapshot {
        let plainText: String
        let isSpeaking: Bool
    }

    // MARK: - 状态

    private var recognizer: SherpaOnnxOfflineRecognizerWrapper?
    private var isReady = false
    private var vadModelPath: String?
    private var currentModelId: ASRModelID?

    /// 实时会话
    private var realtimeSessions: [String: RealtimeSession] = [:]

    private class RealtimeSession {
        let vad: SherpaOnnxVADWrapper
        let recognizer: SherpaOnnxOfflineRecognizerWrapper
        var confirmedSegments: [String] = []
        var pendingText: String = ""
        let startTime: Date = Date()
        var sampleBuffer: [Float] = []
        var totalSamplesProcessed: Int = 0
        var pendingSegmentQueue: [[Float]] = []
        var isProcessingSegment = false

        init(vad: SherpaOnnxVADWrapper, recognizer: SherpaOnnxOfflineRecognizerWrapper) {
            self.vad = vad
            self.recognizer = recognizer
        }

        func processNextSegment() {
            guard !isProcessingSegment, !pendingSegmentQueue.isEmpty else { return }
            isProcessingSegment = true
            let segSamples = pendingSegmentQueue.removeFirst()
            let enhanced = AudioEnhancer.enhance(samples: segSamples, sampleRate: 16000)
            let text = recognizer.recognize(
                samples: enhanced, sampleRate: 16000
            ).text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                confirmedSegments.append(text)
            }
            pendingText = ""
            isProcessingSegment = false
            processNextSegment()
        }

        var fullText: String {
            let confirmed = confirmedSegments.joined(separator: "")
            return pendingText.isEmpty ? confirmed : confirmed + pendingText
        }
    }

    // MARK: - VAD 模型路径

    private static func findVADModel() -> String? {
        if let bundlePath = Bundle.main.resourceURL {
            let p = bundlePath.appendingPathComponent("silero_vad.onnx").path
            if FileManager.default.fileExists(atPath: p) { return p }
            let p2 = bundlePath.appendingPathComponent("vad/silero_vad.onnx").path
            if FileManager.default.fileExists(atPath: p2) { return p2 }
        }
        let projectVAD = NSHomeDirectory() + "/Desktop/Mac-Record/MacRecord/Resources/vad/silero_vad.onnx"
        if FileManager.default.fileExists(atPath: projectVAD) { return projectVAD }
        return nil
    }

    // MARK: - 生命周期

    /// 初始化指定模型
    func initialize(modelId: ASRModelID) throws -> String {
        // 如果已加载相同模型，直接返回
        if isReady, currentModelId == modelId { return getModelStatus() }

        // 切换模型需要先释放旧的
        if isReady { shutdown() }

        guard let paths = ModelRegistry.modelPaths(for: modelId) else {
            throw NativeASRError.modelNotFound("未找到模型文件: \(modelId.rawValue)")
        }

        guard let vadPath = Self.findVADModel() else {
            throw NativeASRError.modelNotFound("未找到 Silero VAD 模型")
        }

        let modelInfo = ModelRegistry.model(for: modelId)
        let recognizerConfig: SherpaOnnxRecognizerConfig

        switch paths {
        case .senseVoice(let modelPath, let tokensPath):
            recognizerConfig = SherpaOnnxRecognizerConfig(
                modelConfig: .senseVoice(.init(
                    modelPath: modelPath,
                    tokensPath: tokensPath,
                    language: "auto",
                    useITN: true
                )),
                numThreads: 4,
                sampleRate: 16000,
                featureDim: 80,
                decodingMethod: "greedy_search",
                provider: "cpu"
            )
        case .qwen3ASR(let convFrontend, let encoder, let decoder, let tokenizer):
            recognizerConfig = SherpaOnnxRecognizerConfig(
                modelConfig: .qwen3ASR(.init(
                    convFrontendPath: convFrontend,
                    encoderPath: encoder,
                    decoderPath: decoder,
                    tokenizerPath: tokenizer
                )),
                numThreads: 4,
                sampleRate: 16000,
                featureDim: 80,
                decodingMethod: "greedy_search",
                provider: "cpu"
            )
        }

        guard let rec = SherpaOnnxOfflineRecognizerWrapper(config: recognizerConfig) else {
            throw NativeASRError.initFailed("OfflineRecognizer 初始化失败")
        }

        self.recognizer = rec
        self.vadModelPath = vadPath
        self.currentModelId = modelId
        self.isReady = true
        print("[NativeASR] \(modelInfo.displayName) + Silero VAD 初始化成功")
        return "✅ \(modelInfo.displayName) 已就绪"
    }

    func getModelStatus() -> String {
        if isReady, let modelId = currentModelId {
            let name = ModelRegistry.model(for: modelId).displayName
            return "✅ \(name) 已就绪"
        }
        return "⏳ ASR 引擎未初始化"
    }

    func shutdown() {
        recognizer = nil
        realtimeSessions.removeAll()
        isReady = false
        currentModelId = nil
    }

    // MARK: - Diarization 模型路径

    private static func findDiarizationModels() -> (segmentation: String, embedding: String)? {
        let fm = FileManager.default

        // Bundle 内查找
        if let bundlePath = Bundle.main.resourceURL {
            let seg = bundlePath
                .appendingPathComponent("speaker-diarization/sherpa-onnx-pyannote-segmentation-3-0/model.onnx").path
            let emb = bundlePath
                .appendingPathComponent("speaker-diarization/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx").path
            if fm.fileExists(atPath: seg) && fm.fileExists(atPath: emb) {
                return (seg, emb)
            }
        }

        // 开发目录
        let base = NSHomeDirectory() + "/Desktop/Mac-Record/MacRecord/Resources/speaker-diarization"
        let seg = base + "/sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
        let emb = base + "/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx"
        if fm.fileExists(atPath: seg) && fm.fileExists(atPath: emb) {
            return (seg, emb)
        }

        return nil
    }

    /// 检查 diarization 模型是否可用
    func isDiarizationAvailable() -> Bool {
        Self.findDiarizationModels() != nil
    }

    // MARK: - 说话人分离

    /// 对音频文件执行说话人分离 + ASR，返回带说话人标签的文本
    func diarize(
        audioPath: String,
        numSpeakers: Int32 = 0,
        onProgress: ((Float) -> Void)? = nil
    ) throws -> DiarizedTranscribeResult {
        guard let recognizer = recognizer else {
            throw NativeASRError.notReady
        }

        guard let models = Self.findDiarizationModels() else {
            throw NativeASRError.modelNotFound("未找到说话人分离模型（segmentation + embedding）")
        }

        let totalStart = CFAbsoluteTimeGetCurrent()

        // 1. 读取并重采样音频
        let fileURL = URL(fileURLWithPath: audioPath)
        guard let raw = AudioEnhancer.readAndResample(url: fileURL) else {
            throw NativeASRError.initFailed("无法读取音频文件: \(audioPath)")
        }
        let audioDuration = Double(raw.samples.count) / Double(raw.sampleRate)
        print("[NativeASR] diarize: 音频 \(String(format: "%.1f", audioDuration))s, \(raw.samples.count) samples")

        // 2. 创建 Diarization 引擎
        guard let diarizer = SherpaOnnxDiarizationWrapper(
            segmentationModelPath: models.segmentation,
            embeddingModelPath: models.embedding,
            numSpeakers: numSpeakers,
            threshold: numSpeakers > 0 ? 0.5 : 0.92,
            numThreads: 4
        ) else {
            throw NativeASRError.initFailed("Speaker Diarization 引擎创建失败")
        }

        // 3. 执行说话人分离
        let diarStart = CFAbsoluteTimeGetCurrent()
        let diarResult = diarizer.process(samples: raw.samples) { processed, total in
            let progress = Float(processed) / Float(max(total, 1))
            onProgress?(progress * 0.6)  // diarization 占进度 60%
            return 0
        }
        let diarTime = CFAbsoluteTimeGetCurrent() - diarStart
        print("[NativeASR] diarize: 分离完成 \(diarResult.numSpeakers)人 \(diarResult.segments.count)段, 耗时\(String(format: "%.2f", diarTime))s")

        guard !diarResult.segments.isEmpty else {
            return DiarizedTranscribeResult(text: "", numSpeakers: 0, segments: [])
        }

        // 4. 对每个段做 ASR
        var resultSegments: [DiarizedTranscribeResult.SpeakerSegment] = []
        let sampleRate = raw.sampleRate

        for (idx, seg) in diarResult.segments.enumerated() {
            let startSample = max(0, Int(seg.start * Float(sampleRate)))
            let endSample = min(raw.samples.count, Int(seg.end * Float(sampleRate)))
            guard endSample > startSample else { continue }

            let segSamples = Array(raw.samples[startSample..<endSample])
            let enhanced = AudioEnhancer.enhance(samples: segSamples, sampleRate: Float(sampleRate))
            let asrResult = recognizer.recognize(samples: enhanced, sampleRate: Int32(sampleRate))
            let text = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                resultSegments.append(.init(
                    speaker: seg.speaker,
                    start: seg.start,
                    end: seg.end,
                    text: text
                ))
            }

            // 更新进度 (ASR 占 40%)
            let progress = 0.6 + 0.4 * Float(idx + 1) / Float(diarResult.segments.count)
            onProgress?(progress)
        }

        // 5. 合并带说话人标签的文本
        let fullText = resultSegments.map { seg in
            "说话人\(seg.speaker + 1): \(seg.text)"
        }.joined(separator: "\n")

        let totalTime = CFAbsoluteTimeGetCurrent() - totalStart
        print("[NativeASR] diarize 完成: \(diarResult.numSpeakers)人, \(resultSegments.count)段有效文本, 总耗时\(String(format: "%.2f", totalTime))s")

        onProgress?(1.0)

        return DiarizedTranscribeResult(
            text: fullText,
            numSpeakers: diarResult.numSpeakers,
            segments: resultSegments
        )
    }

    // MARK: - 文件转录

    func transcribeFile(audioPath: String, language: String = "auto") throws -> TranscribeResult {
        guard let recognizer = recognizer, let vadPath = vadModelPath else {
            throw NativeASRError.notReady
        }

        let totalStart = CFAbsoluteTimeGetCurrent()

        let fileURL = URL(fileURLWithPath: audioPath)
        guard let raw = AudioEnhancer.readAndResample(url: fileURL) else {
            print("[NativeASR] readAndResample 失败，fallback 到原始路径")
            let result = recognizer.recognizeFile(path: audioPath)
            return TranscribeResult(
                plainText: result.text, detectedLanguage: result.lang,
                emotion: result.emotion, duration: nil
            )
        }

        let audioDuration = Double(raw.samples.count) / Double(raw.sampleRate)

        let vadBufferSize = max(120.0, Float(audioDuration) + 60.0)
        guard let vad = SherpaOnnxVADWrapper(
            modelPath: vadPath, bufferSizeInSeconds: vadBufferSize
        ) else {
            print("[NativeASR] 文件转录 VAD 创建失败，fallback 到整段识别")
            var samples = raw.samples
            samples = AudioEnhancer.enhance(samples: samples, sampleRate: Float(raw.sampleRate))
            let result = recognizer.recognize(samples: samples, sampleRate: raw.sampleRate)
            return TranscribeResult(
                plainText: result.text, detectedLanguage: result.lang,
                emotion: result.emotion, duration: audioDuration
            )
        }

        let vadStart = CFAbsoluteTimeGetCurrent()
        let windowSize = Int(vad.windowSize)
        var offset = 0

        raw.samples.withUnsafeBufferPointer { ptr in
            while offset + windowSize <= raw.samples.count {
                vad.acceptWaveform(samples: ptr.baseAddress! + offset, count: Int32(windowSize))
                offset += windowSize
            }
        }
        if offset < raw.samples.count {
            var tail = Array(raw.samples[offset...])
            tail.append(contentsOf: [Float](repeating: 0, count: windowSize - tail.count))
            tail.withUnsafeBufferPointer { ptr in
                vad.acceptWaveform(samples: ptr.baseAddress!, count: Int32(windowSize))
            }
        }
        vad.flush()

        var speechSegments: [[Float]] = []
        while vad.hasSegment {
            if let (segSamples, _) = vad.popFrontSegment() {
                speechSegments.append(segSamples)
            }
        }
        let vadTime = CFAbsoluteTimeGetCurrent() - vadStart

        if speechSegments.isEmpty {
            print("[NativeASR] 文件转录: VAD 未检测到语音段，整段识别")
            var samples = raw.samples
            samples = AudioEnhancer.enhance(samples: samples, sampleRate: Float(raw.sampleRate))
            let result = recognizer.recognize(samples: samples, sampleRate: raw.sampleRate)
            return TranscribeResult(
                plainText: result.text, detectedLanguage: result.lang,
                emotion: result.emotion, duration: audioDuration
            )
        }

        var confirmedTexts: [String] = []
        var firstLang: String?
        var firstEmotion: String?
        var totalEnhTime: Double = 0
        var totalRecTime: Double = 0

        for (idx, segSamples) in speechSegments.enumerated() {
            let segDur = Double(segSamples.count) / Double(raw.sampleRate)
            let enhStart = CFAbsoluteTimeGetCurrent()
            let enhanced = AudioEnhancer.enhance(
                samples: segSamples, sampleRate: Float(raw.sampleRate)
            )
            totalEnhTime += CFAbsoluteTimeGetCurrent() - enhStart

            let recStart = CFAbsoluteTimeGetCurrent()
            let result = recognizer.recognize(samples: enhanced, sampleRate: raw.sampleRate)
            totalRecTime += CFAbsoluteTimeGetCurrent() - recStart

            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { confirmedTexts.append(text) }
            if idx == 0 {
                firstLang = result.lang
                firstEmotion = result.emotion
            }
            print("[NativeASR] 段\(idx+1)/\(speechSegments.count): \(String(format: "%.1f", segDur))s → \"\(text.prefix(30))\"")
        }

        let totalTime = CFAbsoluteTimeGetCurrent() - totalStart
        let speechRatio = speechSegments.reduce(0) { $0 + $1.count } * 100 / raw.samples.count
        print("[NativeASR] 文件转录完成: \(speechSegments.count)段, 语音占比\(speechRatio)%, VAD=\(String(format: "%.2f", vadTime))s 增强=\(String(format: "%.2f", totalEnhTime))s 识别=\(String(format: "%.2f", totalRecTime))s 总计=\(String(format: "%.2f", totalTime))s")

        return TranscribeResult(
            plainText: confirmedTexts.joined(separator: ""),
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

    func realtimeStartForVoiceInput(sessionId: String) {
        guard let recognizer = recognizer, let vadPath = vadModelPath else { return }
        guard let vad = SherpaOnnxVADWrapper(
            modelPath: vadPath, minSilenceDuration: 0.2
        ) else {
            print("[NativeASR] VAD 创建失败 (voiceInput)")
            return
        }
        let session = RealtimeSession(vad: vad, recognizer: recognizer)
        realtimeSessions[sessionId] = session
        print("[NativeASR] 语音输入会话启动: \(sessionId)")
    }

    func realtimeFeed(sessionId: String, samples: [Float]) -> String {
        guard let session = realtimeSessions[sessionId] else { return "" }

        session.sampleBuffer.append(contentsOf: samples)
        session.totalSamplesProcessed += samples.count

        let windowSize = Int(session.vad.windowSize)

        while session.sampleBuffer.count >= windowSize {
            let window = Array(session.sampleBuffer.prefix(windowSize))
            session.sampleBuffer.removeFirst(windowSize)

            window.withUnsafeBufferPointer { ptr in
                session.vad.acceptWaveform(
                    samples: ptr.baseAddress!, count: Int32(windowSize)
                )
            }

            while session.vad.hasSegment {
                if let (segSamples, _) = session.vad.popFrontSegment() {
                    session.pendingSegmentQueue.append(segSamples)
                }
            }
        }

        session.processNextSegment()
        return session.fullText
    }

    func realtimeFeedBase64(sessionId: String, audioBase64: String) -> String {
        guard let data = Data(base64Encoded: audioBase64) else { return "" }
        let floatCount = data.count / MemoryLayout<Float>.size
        let samples = data.withUnsafeBytes { buffer -> [Float] in
            let floatBuffer = buffer.bindMemory(to: Float.self)
            return Array(floatBuffer.prefix(floatCount))
        }
        return realtimeFeed(sessionId: sessionId, samples: samples)
    }

    func getRealtimeSnapshot(sessionId: String) -> RealtimeSnapshot {
        guard let session = realtimeSessions[sessionId] else {
            return RealtimeSnapshot(plainText: "", isSpeaking: false)
        }
        return RealtimeSnapshot(
            plainText: session.fullText,
            isSpeaking: session.vad.isSpeechDetected
        )
    }

    func realtimeGetConfirmedText(sessionId: String) -> String {
        guard let session = realtimeSessions[sessionId] else { return "" }
        return session.fullText
    }

    func realtimeStop(sessionId: String) throws -> TranscribeResult {
        guard let session = realtimeSessions[sessionId] else {
            throw NativeASRError.sessionNotFound(sessionId)
        }
        defer { realtimeSessions.removeValue(forKey: sessionId) }

        let stopStart = CFAbsoluteTimeGetCurrent()

        let windowSize = Int(session.vad.windowSize)
        if !session.sampleBuffer.isEmpty {
            let padding = windowSize - session.sampleBuffer.count % windowSize
            if padding < windowSize {
                session.sampleBuffer.append(
                    contentsOf: [Float](repeating: 0, count: padding)
                )
            }
            while session.sampleBuffer.count >= windowSize {
                let window = Array(session.sampleBuffer.prefix(windowSize))
                session.sampleBuffer.removeFirst(windowSize)
                window.withUnsafeBufferPointer { ptr in
                    session.vad.acceptWaveform(
                        samples: ptr.baseAddress!, count: Int32(windowSize)
                    )
                }
            }
        }

        session.vad.flush()

        var tailSegmentCount = 0
        while session.vad.hasSegment {
            if let (segSamples, _) = session.vad.popFrontSegment() {
                let enhanced = AudioEnhancer.enhance(
                    samples: segSamples, sampleRate: 16000
                )
                let text = session.recognizer.recognize(
                    samples: enhanced, sampleRate: 16000
                ).text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    session.confirmedSegments.append(text)
                }
                tailSegmentCount += 1
            }
        }

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
