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
    let transcriptionQueue = TranscriptionQueue()
    let persistenceCoordinator: RecordingPersistenceCoordinator
    var realtimeAudioPump: RealtimeAudioPump?
    var stopRequestedWhileStarting = false
    private var engineStartGeneration = UUID()
    private var engineStartInFlightModel: ASRModelID?
    private var modelSwitchGeneration = UUID()
    private var transcriptionGenerations: [UUID: UUID] = [:]
    private var transcriptionTaskGenerations: [UUID: UUID] = [:]
    var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    @Published var modelStatus: String = "⏳ 正在启动 ASR 引擎..."
    @Published var isModelReady: Bool = false
    @Published var transcriptionStatus: String?

    // MARK: - ASR 配置
    @Published var asrConfigStore = ASRConfigStore()

    // MARK: - 模型下载管理
    @Published var modelDownloadManager = ModelDownloadManager()
    private var cancellables = Set<AnyCancellable>()

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

    /// 文件型 ASR 不要求实时引擎常驻；只要模型已安装即可录音后转录。
    var canStartRecording: Bool {
        guard isIdle else { return false }
        let model = selectedASRModel
        if model.capabilities.supportsRealtime {
            return isModelReady && ModelRegistry.isModelDownloaded(model.id)
        }
        return model.capabilities.supportsFileTranscription
            && ModelRegistry.isModelDownloaded(model.id)
    }

    var canTranscribeFile: Bool {
        guard isIdle,
              selectedASRModel.capabilities.supportsFileTranscription,
              ModelRegistry.isModelDownloaded(selectedASRModel.id) else { return false }
        return selectedASRModel.capabilities.supportsRealtime ? isModelReady : true
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
        modelDownloadManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        modelDownloadManager.$downloadedModelIds
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] downloaded in
                guard let self,
                      downloaded.contains(self.asrConfigStore.selectedModelId),
                      !self.isModelReady else { return }
                Task { await self.startASREngine() }
            }
            .store(in: &cancellables)
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
        guard engineStartInFlightModel != modelId else { return }
        let generation = UUID()
        engineStartGeneration = generation
        engineStartInFlightModel = modelId
        defer {
            if engineStartGeneration == generation {
                engineStartInFlightModel = nil
            }
        }

        guard ModelRegistry.isModelDownloaded(modelId) else {
            modelStatus = "⏳ 模型未下载: \(ModelRegistry.model(for: modelId).displayName)"
            isModelReady = false
            return
        }

        // 如果已加载相同模型，跳过
        if let service = nativeASRService {
            let status = await service.getModelStatus()
            guard engineStartGeneration == generation,
                  asrConfigStore.selectedModelId == modelId else { return }
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
            guard engineStartGeneration == generation,
                  asrConfigStore.selectedModelId == modelId,
                  nativeASRService === service else { return }
            self.modelStatus = status
            self.isModelReady = true
        } catch {
            guard engineStartGeneration == generation,
                  asrConfigStore.selectedModelId == modelId,
                  nativeASRService === service else { return }
            self.modelStatus = "❌ \(modelName) 启动失败: \(error.localizedDescription)"
            self.isModelReady = false
            print("[AppState] \(self.modelStatus)")
        }
    }

    func switchASRModel(to modelId: ASRModelID) async {
        guard isIdle else {
            modelStatus = "录音期间不能切换识别引擎"
            return
        }
        if asrConfigStore.selectedModelId == modelId {
            if isModelReady { return }
            if engineStartInFlightModel == modelId {
                modelStatus = "⏳ 正在初始化 \(ModelRegistry.model(for: modelId).displayName)…"
                return
            }
        }
        let switchGeneration = UUID()
        modelSwitchGeneration = switchGeneration
        engineStartGeneration = UUID()
        engineStartInFlightModel = nil
        isModelReady = false
        asrConfigStore.selectedModelId = modelId
        asrConfigStore.save()

        // 只释放切换开始时捕获的旧引擎；更晚的切换可能已经创建了新实例。
        let serviceToShutdown = nativeASRService
        if let serviceToShutdown {
            await serviceToShutdown.shutdown()
        }
        guard modelSwitchGeneration == switchGeneration,
              asrConfigStore.selectedModelId == modelId else { return }
        if let serviceToShutdown, nativeASRService === serviceToShutdown {
            nativeASRService = nil
        }

        await startASREngine()
    }

    func beginTranscription(for recordingId: UUID) -> UUID {
        let generation = UUID()
        transcriptionGenerations[recordingId] = generation
        return generation
    }

    func isCurrentTranscription(_ generation: UUID, for recordingId: UUID) -> Bool {
        transcriptionGenerations[recordingId] == generation
    }

    func finishTranscription(_ generation: UUID, for recordingId: UUID) {
        guard isCurrentTranscription(generation, for: recordingId) else { return }
        transcriptionGenerations.removeValue(forKey: recordingId)
    }

    func registerTranscriptionTask(
        _ task: Task<Void, Never>,
        generation: UUID,
        recordingId: UUID
    ) {
        transcriptionTasks[recordingId]?.cancel()
        transcriptionTasks[recordingId] = task
        transcriptionTaskGenerations[recordingId] = generation
    }

    func unregisterTranscriptionTask(generation: UUID, recordingId: UUID) {
        guard transcriptionTaskGenerations[recordingId] == generation else { return }
        transcriptionTasks.removeValue(forKey: recordingId)
        transcriptionTaskGenerations.removeValue(forKey: recordingId)
        transcriptionStatus = transcriptionTasks.isEmpty ? nil : "转录队列处理中"
    }

    func retranscribe(recordingId: UUID, audioURL: URL) async throws {
        let generation = beginTranscription(for: recordingId)
        persistenceCoordinator.markProcessing(recordingId: recordingId, engineId: asrConfigStore.selectedModelId)
        defer { finishTranscription(generation, for: recordingId) }
        do {
            let result = try await transcribeFile(at: audioURL)
            guard isCurrentTranscription(generation, for: recordingId) else {
                throw ASRCoordinationError.superseded
            }
            try persistenceCoordinator.apply(result, to: recordingId)
        } catch {
            guard isCurrentTranscription(generation, for: recordingId) else {
                throw ASRCoordinationError.superseded
            }
            persistenceCoordinator.markFailed(error, recordingId: recordingId)
            throw error
        }
    }

    func transcribeFile(at url: URL, hotwords: [String] = []) async throws -> UnifiedTranscriptionResult {
        guard isIdle else { throw ASRCoordinationError.busy }
        let modelId = asrConfigStore.selectedModelId
        switch ModelRegistry.model(for: modelId).family {
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
        for recordingId in transcriptionTasks.keys {
            transcriptionGenerations[recordingId] = UUID()
            persistenceCoordinator.markCancelled(recordingId: recordingId)
        }
        for task in transcriptionTasks.values { task.cancel() }
        transcriptionTasks.removeAll()
        transcriptionTaskGenerations.removeAll()
        transcriptionStatus = nil
    }
}

enum ASRCoordinationError: LocalizedError {
    case busy
    case superseded

    var errorDescription: String? {
        switch self {
        case .busy: return "录音或语音输入进行中，请结束后再执行文件转录"
        case .superseded: return "该转录已被更新的请求替代"
        }
    }
}
