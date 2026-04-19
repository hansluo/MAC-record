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
    // MARK: - ASR 引擎
    @Published var asrBridge: ASRBridge?
    @Published var nativeASRService: NativeASRService?
    @Published var modelStatus: String = "⏳ 正在启动 ASR 引擎..."
    @Published var isModelReady: Bool = false

    // MARK: - ASR 配置
    @Published var asrConfigStore = ASRConfigStore()

    // MARK: - 录音状态（状态机）
    @Published var recordingMode: RecordingMode = .idle
    @Published var recordingStartTime: Date?
    @Published var audioSource: AudioSourceType = .microphone

    /// 兼容属性：是否正在进行正常录音
    var isRecording: Bool {
        if case .normalRecording = recordingMode { return true }
        return false
    }

    /// 兼容属性：正常录音是否暂停
    var isPaused: Bool {
        if case .normalRecording(_, let paused) = recordingMode { return paused }
        return false
    }

    /// 当前正常录音的 sessionId
    var currentSessionId: UUID? {
        if case .normalRecording(let sid, _) = recordingMode { return sid }
        return nil
    }

    /// 是否正在语音输入
    var isVoiceInputActive: Bool {
        if case .voiceInput = recordingMode { return true }
        return false
    }

    /// 是否任何录音模式都空闲
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
        switch asrConfigStore.selectedEngine {
        case .senseVoice:
            await startSenseVoice()
        case .senseVoiceNative:
            await startSenseVoiceNative()
        }
    }

    func switchASREngine(to engine: ASREngineType) async {
        isModelReady = false
        asrConfigStore.selectedEngine = engine
        asrConfigStore.save()
        await startASREngine()
    }

    // MARK: - SenseVoice

    private func startSenseVoice() async {
        if let bridge = asrBridge {
            do {
                let status = try await bridge.getModelStatus()
                self.modelStatus = status
                self.isModelReady = true
                return
            } catch {
                // bridge 可能已断，重新创建
            }
        }

        modelStatus = "⏳ 正在启动 SenseVoice..."
        let bridge = ASRBridge()
        self.asrBridge = bridge

        do {
            try await bridge.start()
            let status = try await bridge.initModels()
            self.modelStatus = status
            self.isModelReady = true
        } catch {
            self.modelStatus = "❌ SenseVoice 启动失败: \(error.localizedDescription)"
            self.isModelReady = false
        }
    }

    // MARK: - SenseVoice Native (sherpa-onnx)

    private func startSenseVoiceNative() async {
        if let service = nativeASRService {
            let status = await service.getModelStatus()
            if status.hasPrefix("✅") {
                self.modelStatus = status
                self.isModelReady = true
                return
            }
        }

        modelStatus = "⏳ 正在初始化 SenseVoice (原生)..."
        let service = NativeASRService()
        self.nativeASRService = service

        do {
            let status = try await service.initialize()
            self.modelStatus = status
            self.isModelReady = true
        } catch {
            self.modelStatus = "❌ SenseVoice (原生) 启动失败: \(error.localizedDescription)"
            self.isModelReady = false
        }
    }
}
