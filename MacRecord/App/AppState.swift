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
    @Published private(set) var activeTranscriptionIds: Set<UUID> = []
    @Published private(set) var transcriptionProgressByRecordingId: [UUID: TranscriptionProgress] = [:]

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

    var hasActiveTranscriptions: Bool {
        !activeTranscriptionIds.isEmpty
    }

    func isTranscribing(recordingId: UUID) -> Bool {
        activeTranscriptionIds.contains(recordingId)
    }

    func transcriptionProgress(for recordingId: UUID) -> TranscriptionProgress? {
        transcriptionProgressByRecordingId[recordingId]
    }

    func updateTranscriptionProgress(
        _ progress: TranscriptionProgress,
        recordingId: UUID,
        generation: UUID
    ) {
        guard isCurrentTranscription(generation, for: recordingId) else { return }
        transcriptionProgressByRecordingId[recordingId] = progress
        transcriptionStatus = progress.message
    }

    /// 文件型 ASR 不要求实时引擎常驻；只要模型已安装即可录音后转录。
    var canStartRecording: Bool {
        guard isIdle, !hasActiveTranscriptions else { return false }
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
        if ProcessInfo.processInfo.environment["MACRECORD_TESTING"] != "1" {
            Task {
                await startASREngine()
                voiceInputService.setup(appState: self)
                sleepWakeManager.setup(appState: self)
            }
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
        guard isIdle, !hasActiveTranscriptions else {
            modelStatus = hasActiveTranscriptions
                ? "文件转录期间不能切换识别引擎"
                : "录音期间不能切换识别引擎"
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
        activeTranscriptionIds.insert(recordingId)
        let progress = TranscriptionProgress(
            phase: .queued,
            fraction: 0,
            message: "已加入转录队列",
            completedSegments: 0
        )
        transcriptionProgressByRecordingId[recordingId] = progress
        transcriptionStatus = progress.message
    }

    func unregisterTranscriptionTask(generation: UUID, recordingId: UUID) {
        guard transcriptionTaskGenerations[recordingId] == generation else { return }
        transcriptionTasks.removeValue(forKey: recordingId)
        transcriptionTaskGenerations.removeValue(forKey: recordingId)
        activeTranscriptionIds.remove(recordingId)
        transcriptionProgressByRecordingId.removeValue(forKey: recordingId)
        transcriptionStatus = transcriptionTasks.isEmpty
            ? nil
            : transcriptionProgressByRecordingId.values.first?.message ?? "转录队列处理中"
    }

    func startRetranscription(recordingId: UUID, audioURL: URL) {
        let generation = beginTranscription(for: recordingId)
        persistenceCoordinator.markProcessing(
            recordingId: recordingId,
            engineId: asrConfigStore.selectedModelId
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.finishTranscription(generation, for: recordingId)
                self.unregisterTranscriptionTask(
                    generation: generation,
                    recordingId: recordingId
                )
            }
            do {
                let progressHandler: @Sendable (TranscriptionProgress) -> Void = { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.updateTranscriptionProgress(
                            progress,
                            recordingId: recordingId,
                            generation: generation
                        )
                    }
                }
                let result = try await self.transcriptionQueue.enqueue {
                    try await self.transcribeFile(
                        at: audioURL,
                        onProgress: progressHandler
                    )
                }
                try Task.checkCancellation()
                guard self.isCurrentTranscription(generation, for: recordingId) else { return }
                self.updateTranscriptionProgress(
                    .init(
                        phase: .saving,
                        fraction: 0.99,
                        message: "正在保存转录结果…",
                        completedSegments: self.transcriptionProgressByRecordingId[recordingId]?.completedSegments ?? 0
                    ),
                    recordingId: recordingId,
                    generation: generation
                )
                try self.persistenceCoordinator.apply(result, to: recordingId)
            } catch is CancellationError {
                guard self.isCurrentTranscription(generation, for: recordingId) else { return }
                self.persistenceCoordinator.markCancelled(recordingId: recordingId)
            } catch ASRCoordinationError.superseded {
                // 更新的请求已经接管该录音。
            } catch {
                guard self.isCurrentTranscription(generation, for: recordingId) else { return }
                self.persistenceCoordinator.markFailed(error, recordingId: recordingId)
                self.modelStatus = "❌ 转录失败: \(error.localizedDescription)"
            }
        }
        registerTranscriptionTask(task, generation: generation, recordingId: recordingId)
    }

    func transcribeFile(
        at url: URL,
        hotwords: [String] = [],
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> UnifiedTranscriptionResult {
        guard isIdle else { throw ASRCoordinationError.busy }
        let modelId = asrConfigStore.selectedModelId
        switch ModelRegistry.model(for: modelId).family {
        case .senseVoice, .qwen3ASR:
            guard let nativeASRService else { throw NativeASRError.notReady }
            return try await NativeASRBackend(modelId: modelId, service: nativeASRService)
                .transcribeFile(at: url, hotwords: hotwords, onProgress: onProgress)
        case .appleSpeech:
            onProgress?(.init(
                phase: .recognizing,
                fraction: 0.1,
                message: "正在使用系统语音识别…",
                completedSegments: 0
            ))
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

    func cancelTranscription(recordingId: UUID) {
        guard let task = transcriptionTasks[recordingId],
              let generation = transcriptionTaskGenerations[recordingId] else { return }
        let progress = TranscriptionProgress(
            phase: .cancelling,
            fraction: transcriptionProgressByRecordingId[recordingId]?.fraction ?? 0,
            message: "正在取消，等待当前片段结束…",
            completedSegments: transcriptionProgressByRecordingId[recordingId]?.completedSegments ?? 0
        )
        updateTranscriptionProgress(
            progress,
            recordingId: recordingId,
            generation: generation
        )
        task.cancel()
    }

    func cancelTranscription() async {
        let recordingIds = Array(transcriptionTasks.keys)
        for recordingId in recordingIds {
            cancelTranscription(recordingId: recordingId)
        }
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
