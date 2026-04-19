import Foundation
import Speech
import AVFoundation

/// Apple 原生语音识别服务
/// 实时模式：自己管理 AVAudioEngine + SFSpeechRecognizer（不依赖外部 AudioRecorder）
class AppleSpeechService: ObservableObject {
    @Published var currentText: String = ""

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    // MARK: - 文件转录

    func transcribeFile(url: URL, language: String = "zh-CN") async throws -> (plainText: String, duration: Double?) {
        let locale = Locale(identifier: language)
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            throw AppleSpeechError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        let asset = AVURLAsset(url: url)
        let duration: Double?
        if let dur = try? await asset.load(.duration) {
            duration = dur.seconds.isNaN ? nil : dur.seconds
        } else {
            duration = nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            rec.recognitionTask(with: request) { result, error in
                if hasResumed { return }
                if let error = error {
                    hasResumed = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result = result, result.isFinal else { return }
                hasResumed = true
                continuation.resume(returning: (result.bestTranscription.formattedString, duration))
            }
        }
    }

    // MARK: - 实时转录（自管理 AVAudioEngine）

    /// 开始实时识别 — 自己启动 AVAudioEngine，不依赖外部 AudioRecorder
    /// onBuffer: 可选回调，每次收到音频 buffer 时回调（用于外部写 WAV 文件）
    func startRealtime(language: String = "zh-CN", onBuffer: ((AVAudioPCMBuffer) -> Void)? = nil) throws {
        stopRealtimeSync()

        let locale = Locale(identifier: language)
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            throw AppleSpeechError.recognizerUnavailable
        }
        self.recognizer = rec

        // 创建识别请求
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
            if rec.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
        }
        self.recognitionRequest = request

        // 创建 AVAudioEngine
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        print("[AppleSpeech] 输入格式: sampleRate=\(recordingFormat.sampleRate) channels=\(recordingFormat.channelCount)")

        // ★ 关键：直接用原始格式 install tap，把 buffer append 到 recognitionRequest
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
            onBuffer?(buffer)
        }

        // 启动引擎
        engine.prepare()
        try engine.start()
        self.audioEngine = engine

        print("[AppleSpeech] AVAudioEngine 已启动")

        // 启动识别任务
        currentText = ""
        recognitionTask = rec.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.currentText = text
                }
                if result.isFinal {
                    print("[AppleSpeech] 识别完成 (isFinal)")
                }
            }
            if let error = error {
                print("[AppleSpeech] 识别错误: \(error.localizedDescription)")
            }
        }

        print("[AppleSpeech] 识别任务已启动")
    }

    /// 不再需要外部 feedBuffer — engine 自己采集
    func feedBuffer(_ buffer: AVAudioPCMBuffer) {
        // 如果外部调了这个方法，忽略（实时模式自己管理 engine）
    }

    /// 同步清理（用于 startRealtime 内部重启前清理）
    private func stopRealtimeSync() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionTask?.finish()
        recognitionRequest = nil
        recognitionTask = nil
    }

    /// 停止实时识别，返回最终文本
    @discardableResult
    func stopRealtime() async -> String {
        stopRealtimeSync()

        // 等一小会让最终结果回来（不阻塞线程）
        try? await Task.sleep(for: .milliseconds(300))

        recognitionRequest = nil
        recognitionTask = nil

        let text = currentText
        print("[AppleSpeech] 停止识别，文本长度: \(text.count)")
        return text
    }

    func getCurrentText() -> String {
        return currentText
    }
}

enum AppleSpeechError: LocalizedError {
    case recognizerUnavailable
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable: return "语音识别不可用（请检查语言设置）"
        case .notAuthorized: return "没有语音识别权限"
        }
    }
}
