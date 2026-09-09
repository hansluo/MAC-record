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
            // XcodeGen 当前将目录资源平铺到 Bundle 根目录。
            let flatSeg = bundlePath.appendingPathComponent("model.onnx").path
            let flatEmb = bundlePath.appendingPathComponent("3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx").path
            if fm.fileExists(atPath: flatSeg) && fm.fileExists(atPath: flatEmb) {
                return (flatSeg, flatEmb)
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

    func transcribeFile(
        audioPath: String,
        language: String = "auto",
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) throws -> TranscribeResult {
        guard let recognizer = recognizer, let vadPath = vadModelPath else {
            throw NativeASRError.notReady
        }

        let totalStart = CFAbsoluteTimeGetCurrent()
        onProgress?(.init(
            phase: .reading,
            fraction: 0.01,
            message: "正在读取并转换音频…",
            completedSegments: 0
        ))
        try Task.checkCancellation()

        let fileURL = URL(fileURLWithPath: audioPath)
        let sampleRate: Int32 = 16_000
        var audioDuration: Double = 0
        var totalSamples = 0
        guard let vad = SherpaOnnxVADWrapper(
            modelPath: vadPath,
            maxSpeechDuration: 10.0,
            bufferSizeInSeconds: 120.0
        ) else {
            throw NativeASRError.transcriptionFailed("无法创建语音活动检测器")
        }

        func timeText(_ seconds: Double) -> String {
            let value = max(0, Int(seconds.rounded(.down)))
            return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
        }

        var confirmedTexts: [String] = []
        var firstLang: String?
        var firstEmotion: String?
        var completedSegments = 0
        var recognizedSamples = 0
        var totalEnhTime: Double = 0
        var totalRecTime: Double = 0
        let maximumSegmentSamples = Int(sampleRate) * 10

        func report(processedSamples: Int, message: String? = nil) {
            let processedSeconds = min(
                Double(processedSamples) / Double(sampleRate),
                audioDuration
            )
            let fraction = min(max(0.03 + 0.94 * processedSeconds / max(audioDuration, 0.001), 0.03), 0.97)
            onProgress?(.init(
                phase: .recognizing,
                fraction: fraction,
                message: message ?? "已处理 \(timeText(processedSeconds)) / \(timeText(audioDuration)) · \(completedSegments) 段",
                completedSegments: completedSegments
            ))
        }

        func recognizeSegment(_ samples: [Float], startIndex: Int) throws {
            guard !samples.isEmpty else { return }
            var chunkOffset = 0
            while chunkOffset < samples.count {
                try Task.checkCancellation()
                let end = min(chunkOffset + maximumSegmentSamples, samples.count)
                let chunk = Array(samples[chunkOffset..<end])
                let segmentNumber = completedSegments + 1
                let segmentEnd = min(startIndex + end, totalSamples)
                report(
                    processedSamples: max(startIndex + chunkOffset, 0),
                    message: "正在识别第 \(segmentNumber) 段 · \(timeText(Double(segmentEnd) / Double(sampleRate))) / \(timeText(audioDuration))"
                )

                let enhStart = CFAbsoluteTimeGetCurrent()
                let enhanced = AudioEnhancer.enhance(
                    samples: chunk,
                    sampleRate: Float(sampleRate)
                )
                totalEnhTime += CFAbsoluteTimeGetCurrent() - enhStart
                try Task.checkCancellation()

                let recStart = CFAbsoluteTimeGetCurrent()
                let result = recognizer.recognize(samples: enhanced, sampleRate: sampleRate)
                totalRecTime += CFAbsoluteTimeGetCurrent() - recStart
                try Task.checkCancellation()

                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { confirmedTexts.append(text) }
                if completedSegments == 0 {
                    firstLang = result.lang
                    firstEmotion = result.emotion
                }
                completedSegments += 1
                recognizedSamples += chunk.count
                report(processedSamples: segmentEnd)
                print("[NativeASR] 段\(completedSegments): \(String(format: "%.1f", Double(chunk.count) / Double(sampleRate)))s → \"\(text.prefix(30))\"")
                chunkOffset = end
            }
        }

        func drainSegments() throws {
            while vad.hasSegment {
                guard let (segmentSamples, startIndex) = vad.popFrontSegment() else {
                    throw NativeASRError.transcriptionFailed("VAD 返回了无效语音段")
                }
                try recognizeSegment(segmentSamples, startIndex: Int(startIndex))
            }
        }

        let vadStart = CFAbsoluteTimeGetCurrent()
        let windowSize = Int(vad.windowSize)
        var pendingSamples: [Float] = []
        var acceptedSamples = 0
        var nextHeartbeat = Int(sampleRate) * 5

        do {
            try AudioFileChunkReader.read(
                url: fileURL,
                targetSampleRate: sampleRate,
                chunkDuration: 10
            ) { samples, _, totalDuration in
                try Task.checkCancellation()
                audioDuration = totalDuration
                totalSamples = max(
                    totalSamples,
                    Int((totalDuration * Double(sampleRate)).rounded())
                )
                pendingSamples.append(contentsOf: samples)
                var consumed = 0
                try pendingSamples.withUnsafeBufferPointer { pointer in
                    guard let baseAddress = pointer.baseAddress else { return }
                    while consumed + windowSize <= pointer.count {
                        if acceptedSamples >= nextHeartbeat {
                            try Task.checkCancellation()
                            report(
                                processedSamples: acceptedSamples,
                                message: "正在检测语音 \(timeText(Double(acceptedSamples) / Double(sampleRate))) / \(timeText(audioDuration))"
                            )
                            nextHeartbeat += Int(sampleRate) * 5
                        }
                        vad.acceptWaveform(
                            samples: baseAddress + consumed,
                            count: Int32(windowSize)
                        )
                        consumed += windowSize
                        acceptedSamples += windowSize
                        try drainSegments()
                    }
                }
                if consumed > 0 {
                    pendingSamples = Array(pendingSamples.dropFirst(consumed))
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NativeASRError.transcriptionFailed(error.localizedDescription)
        }

        try Task.checkCancellation()
        totalSamples = max(totalSamples, acceptedSamples + pendingSamples.count)
        if !pendingSamples.isEmpty {
            pendingSamples.append(contentsOf: [Float](
                repeating: 0,
                count: windowSize - pendingSamples.count
            ))
            pendingSamples.withUnsafeBufferPointer { pointer in
                if let baseAddress = pointer.baseAddress {
                    vad.acceptWaveform(samples: baseAddress, count: Int32(windowSize))
                }
            }
            acceptedSamples += windowSize
        }
        pendingSamples.removeAll(keepingCapacity: false)
        vad.flush()
        try drainSegments()
        try Task.checkCancellation()

        guard completedSegments > 0 else {
            throw NativeASRError.transcriptionFailed("未检测到可转录的语音")
        }

        let vadTime = CFAbsoluteTimeGetCurrent() - vadStart
        let totalTime = CFAbsoluteTimeGetCurrent() - totalStart
        let speechRatio = recognizedSamples * 100 / max(totalSamples, 1)
        onProgress?(.init(
            phase: .saving,
            fraction: 0.99,
            message: "识别完成，正在保存 \(completedSegments) 段结果…",
            completedSegments: completedSegments
        ))
        print("[NativeASR] 文件转录完成: \(completedSegments)段, 语音占比\(speechRatio)%, VAD+识别=\(String(format: "%.2f", vadTime))s 增强=\(String(format: "%.2f", totalEnhTime))s 识别=\(String(format: "%.2f", totalRecTime))s 总计=\(String(format: "%.2f", totalTime))s")

        return TranscribeResult(
            plainText: confirmedTexts.joined(separator: "\n"),
            detectedLanguage: firstLang,
            emotion: firstEmotion,
            duration: audioDuration
        )
    }

    // MARK: - 实时流式转录

    func realtimeStart(sessionId: String, language: String) throws {
        guard let recognizer = recognizer, let vadPath = vadModelPath else {
            throw NativeASRError.notReady
        }
        guard let vad = SherpaOnnxVADWrapper(modelPath: vadPath) else {
            throw NativeASRError.initFailed("VAD 创建失败")
        }
        let session = RealtimeSession(vad: vad, recognizer: recognizer)
        realtimeSessions[sessionId] = session
        print("[NativeASR] 流式会话启动: \(sessionId)")
    }

    func realtimeStartForVoiceInput(sessionId: String) throws {
        guard let recognizer = recognizer, let vadPath = vadModelPath else {
            throw NativeASRError.notReady
        }
        guard let vad = SherpaOnnxVADWrapper(
            modelPath: vadPath, minSilenceDuration: 0.2
        ) else {
            throw NativeASRError.initFailed("语音输入 VAD 创建失败")
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

    func realtimeCancel(sessionId: String) {
        realtimeSessions.removeValue(forKey: sessionId)
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
    case transcriptionFailed(String)
    case notReady
    case sessionNotFound(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let msg): return "模型未找到: \(msg)"
        case .initFailed(let msg): return "初始化失败: \(msg)"
        case .transcriptionFailed(let msg): return "转录失败: \(msg)"
        case .notReady: return "ASR 引擎未就绪"
        case .sessionNotFound(let id): return "会话不存在: \(id)"
        }
    }
}
