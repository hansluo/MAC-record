import SwiftUI
import Combine

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
    case normalRecording(sessionId: UUID, paused: Bool)
    case voiceInput
}

/// 全局应用状态
@MainActor
class AppState: ObservableObject {
    // MARK: - ASR 引擎（统一为原生引擎）
    @Published var nativeASRService: NativeASRService?
    @Published var modelStatus: String = "⏳ 正在启动 ASR 引擎..."
    @Published var isModelReady: Bool = false

    // MARK: - ASR 配置
    @Published var asrConfigStore = ASRConfigStore()

    // MARK: - 模型下载管理
    @Published var modelDownloadManager = ModelDownloadManager()

    // MARK: - 录音状态（状态机）
    @Published var recordingMode: RecordingMode = .idle
    @Published var recordingStartTime: Date?
    @Published var audioSource: AudioSourceType = .microphone

    var isRecording: Bool {
        if case .normalRecording = recordingMode { return true }
        return false
    }

    var isPaused: Bool {
        if case .normalRecording(_, let paused) = recordingMode { return paused }
        return false
    }

    var currentSessionId: UUID? {
        if case .normalRecording(let sid, _) = recordingMode { return sid }
        return nil
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

    init() {
        Task {
            await startASREngine()
            voiceInputService.setup(appState: self)
            sleepWakeManager.setup(appState: self)
        }
    }

    func startASREngine() async {
        let modelId = asrConfigStore.selectedModelId

        guard ModelRegistry.isModelDownloaded(modelId) else {
            modelStatus = "⏳ 模型未下载: \(ModelRegistry.model(for: modelId).displayName)"
            isModelReady = false
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
}
