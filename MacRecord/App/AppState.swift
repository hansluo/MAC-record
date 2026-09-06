import SwiftUI
import Combine
import SwiftData

/// 录音源类型
enum AudioSourceType: String, CaseIterable, Identifiable {
    case microphone = "mic"
    case systemAudio = "system"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: return "麦克风"
        case .systemAudio: return "Self 记录"
        }
    }

    var iconName: String {
        switch self {
        case .microphone: return "mic.fill"
        case .systemAudio: return "speaker.wave.3.fill"
        }
    }
}

/// 录音模式状态机 — 确保正常录音和语音输入互斥
enum RecordingMode: Equatable {
    case idle
    case starting(sessionId: UUID)
    case normalRecording(sessionId: UUID, paused: Bool)
    case stopping(sessionId: UUID)
    case voiceInput
}

/// 全局应用状态
@MainActor
class AppState: ObservableObject {
    // MARK: - ASR 引擎
    @Published var nativeASRService: NativeASRService?
    let mossSidecarRunner = MOSSSidecarRunner()
    let transcriptionQueue = TranscriptionQueue()
    let persistenceCoordinator: RecordingPersistenceCoordinator
    var realtimeAudioPump: RealtimeAudioPump?
    var stopRequestedWhileStarting = false
    var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    @Published var modelStatus: String = "⏳ 正在启动 ASR 引擎..."
    @Published var isModelReady: Bool = false
    @Published var transcriptionStatus: String?

    // MARK: - ASR 配置
    @Published var asrConfigStore = ASRConfigStore()

    // MARK: - 模型下载管理
    @Published var modelDownloadManager = ModelDownloadManager()

    // MARK: - 录音状态（状态机）
    @Published var recordingMode: RecordingMode = .idle
    @Published var recordingStartTime: Date?
    @Published var audioSource: AudioSourceType = .microphone

    var isRecording: Bool {
        switch recordingMode {
        case .starting, .normalRecording, .stopping: return true
        case .idle, .voiceInput: return false
        }
    }

    var isPaused: Bool {
        if case .normalRecording(_, let paused) = recordingMode { return paused }
        return false
    }

    var currentSessionId: UUID? {
        switch recordingMode {
        case .starting(let id), .normalRecording(let id, _), .stopping(let id): return id
        case .idle, .voiceInput: return nil
        }
    }

    var isVoiceInputActive: Bool {
        if case .voiceInput = recordingMode { return true }
        return false
    }

    var isIdle: Bool {
        recordingMode == .idle
    }

    // MARK: - 系统音频录制
    @Published var systemAudioRecorder: SystemAudioRecorder?

    // MARK: - 麦克风录音器（惰性实例）
    var _recorder: AudioRecorder?

    // MARK: - 选中的历史记录
    @Published var selectedRecordingId: UUID?

    // MARK: - AI 配置
    @Published var llmConfigStore = LLMConfigStore()

    // MARK: - 语音输入
    @Published var voiceInputService = VoiceInputService()

    // MARK: - 休眠/唤醒管理
    let sleepWakeManager = SleepWakeManager()

    init(modelContainer: ModelContainer) {
        persistenceCoordinator = RecordingPersistenceCoordinator(modelContainer: modelContainer)
        persistenceCoordinator.markInterruptedTasksAfterLaunch()
        Task {
            await startASREngine()
            voiceInputService.setup(appState: self)
            sleepWakeManager.setup(appState: self)
        }
    }

    var selectedASRModel: ASRModelInfo {
        asrConfigStore.selectedModel
    }

    func startASREngine() async {
        let modelId = asrConfigStore.selectedModelId

        guard ModelRegistry.isModelDownloaded(modelId) else {
            modelStatus = "⏳ 模型未下载: \(ModelRegistry.model(for: modelId).displayName)"
            isModelReady = false
            return
        }

        if ModelRegistry.model(for: modelId).family == .mossTranscribeDiarize {
            if let service = nativeASRService { await service.shutdown() }
            nativeASRService = nil
            do {
                try await mossSidecarRunner.healthCheck()
                modelStatus = "✅ MOSS-TD MLX 已就绪"
                isModelReady = true
            } catch {
                modelStatus = "❌ MOSS-TD 启动失败: \(error.localizedDescription)"
                isModelReady = false
            }
            return
        }

        // 如果已加载相同模型，跳过
        if let service = nativeASRService {
            let status = await service.getModelStatus()
            if status.hasPrefix("✅") {
                modelStatus = status
                isModelReady = true
                return
            }
        }

        let modelName = ModelRegistry.model(for: modelId).displayName
        modelStatus = "⏳ 正在初始化 \(modelName)..."

        let service = NativeASRService()
        self.nativeASRService = service

        do {
            let status = try await service.initialize(modelId: modelId)
            self.modelStatus = status
            self.isModelReady = true
        } catch {
            self.modelStatus = "❌ \(modelName) 启动失败: \(error.localizedDescription)"
            self.isModelReady = false
        }
    }

    func switchASRModel(to modelId: ASRModelID) async {
        guard isIdle else {
            modelStatus = "录音期间不能切换识别引擎"
            return
        }
        isModelReady = false
        asrConfigStore.selectedModelId = modelId
        asrConfigStore.save()

        // 先释放旧引擎
        if let service = nativeASRService {
            await service.shutdown()
        }
        nativeASRService = nil

        await startASREngine()
    }

    func transcribeFile(at url: URL, hotwords: [String] = []) async throws -> UnifiedTranscriptionResult {
        guard isIdle else { throw ASRCoordinationError.busy }
        let modelId = asrConfigStore.selectedModelId
        switch ModelRegistry.model(for: modelId).family {
        case .mossTranscribeDiarize:
            let effectiveHotwords = hotwords.isEmpty ? asrConfigStore.mossHotwords : hotwords
            let runner = mossSidecarRunner
            return try await transcriptionQueue.enqueue {
                try await runner.transcribeFile(at: url, hotwords: effectiveHotwords)
            }
        case .senseVoice, .qwen3ASR:
            guard let nativeASRService else { throw NativeASRError.notReady }
            return try await NativeASRBackend(modelId: modelId, service: nativeASRService)
                .transcribeFile(at: url, hotwords: hotwords)
        case .appleSpeech:
            let result = try await AppleSpeechService().transcribeFile(url: url)
            return UnifiedTranscriptionResult(
                text: result.plainText,
                language: nil,
                segments: [],
                engineId: modelId.rawValue,
                modelVersion: nil,
                duration: result.duration,
                elapsed: nil,
                diagnostics: nil
            )
        }
    }

    func cancelTranscription() async {
        for task in transcriptionTasks.values { task.cancel() }
        transcriptionTasks.removeAll()
        await mossSidecarRunner.cancel()
        transcriptionStatus = nil
    }
}

enum ASRCoordinationError: LocalizedError {
    case busy

    var errorDescription: String? {
        "录音或语音输入进行中，请结束后再执行文件转录"
    }
}
