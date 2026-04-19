import Foundation
import AVFoundation
import Combine

/// 语音输入状态机
enum VoiceInputState: Equatable {
    case idle
    case recording
    case correcting
    case injecting
}

/// 语音输入核心控制器
/// 编排：热键触发 → 录音(实时注入文字) → 松开 → LLM 优化替换 → 完成
@MainActor
class VoiceInputService: ObservableObject {

    // MARK: - 状态
    @Published private(set) var state: VoiceInputState = .idle
    @Published private(set) var lastInjectedText: String = ""
    @Published private(set) var errorMessage: String?

    // MARK: - 依赖
    private let hotkeyManager = HotkeyManager()
    private let correctionService = VoiceInputCorrectionService()
    private var recorder: AudioRecorder?
    private var voiceInputSessionId: String?
    private var liveTextPollingTask: Task<Void, Never>?

    /// 当前已注入到光标处的文本（用于增量更新和 LLM 替换）
    private var currentInjectedText: String = ""

    // MARK: - 外部引用（由 AppState 注入）
    weak var appState: AppState?

    // MARK: - 配置
    let configStore = VoiceInputConfigStore()
    private var configStoreCancellable: AnyCancellable?

    // MARK: - 生命周期

    func setup(appState: AppState) {
        self.appState = appState

        configStoreCancellable = configStore.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        hotkeyManager.hotkeyType = configStore.hotkeyType
        hotkeyManager.longPressThresholdMs = configStore.longPressThresholdMs
        hotkeyManager.isEnabled = configStore.isEnabled
        correctionService.shortThreshold = configStore.shortThreshold

        hotkeyManager.onLongPressStart = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.startVoiceInput()
            }
        }
        hotkeyManager.onLongPressEnd = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.stopVoiceInput()
            }
        }

        hotkeyManager.start()
        print("[VoiceInput] 语音输入服务已初始化")
    }

    func shutdown() {
        hotkeyManager.stop()
        if state == .recording {
            stopRecordingOnly()
        }
        state = .idle
    }

    func reloadConfig() {
        hotkeyManager.stop()
        hotkeyManager.hotkeyType = configStore.hotkeyType
        hotkeyManager.longPressThresholdMs = configStore.longPressThresholdMs
        hotkeyManager.isEnabled = configStore.isEnabled
        hotkeyManager.start()
        correctionService.shortThreshold = configStore.shortThreshold
        print("[VoiceInput] 配置已重载: hotkey=\(configStore.hotkeyType.displayName)")
    }

    // MARK: - 语音输入流程

    private func startVoiceInput() async {
        guard let appState = appState else { return }

        guard appState.isIdle else {
            print("[VoiceInput] 正常录音进行中，忽略语音输入")
            return
        }

        guard appState.isModelReady else {
            errorMessage = "ASR 引擎未就绪"
            return
        }

        guard AccessibilityHelper.isAccessibilityGranted else {
            errorMessage = "需要辅助功能权限"
            AccessibilityHelper.checkAndRequestAccessibility()
            return
        }

        errorMessage = nil
        currentInjectedText = ""

        // 显示浮窗（录音状态）
        VoiceInputIndicatorWindow.shared.show()

        appState.recordingMode = .voiceInput

        let rec = AudioRecorder()
        self.recorder = rec

        let sessionId = UUID().uuidString
        self.voiceInputSessionId = sessionId

        if let service = appState.nativeASRService {
            await service.realtimeStartForVoiceInput(sessionId: sessionId)
        }

        // buffer 回调：只做 ASR feed
        rec.onAudioBuffer = { [weak appState] buffer in
            guard let appState = appState else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: count))

            Task {
                if let service = appState.nativeASRService {
                    _ = await service.realtimeFeed(sessionId: sessionId, samples: samples)
                }
            }
        }

        // ★ 实时轮询：ASR 文字变化时立即注入到光标处（替换旧文本）
        liveTextPollingTask = Task { [weak self, weak appState] in
            while !Task.isCancelled {
                guard let self = self,
                      let appState = appState,
                      let service = appState.nativeASRService else { break }
                let snapshot = await service.getRealtimeSnapshot(sessionId: sessionId)
                let newText = snapshot.plainText
                if !newText.isEmpty, newText != self.currentInjectedText {
                    let oldLen = self.currentInjectedText.count
                    // 更新浮窗
                    VoiceInputIndicatorWindow.shared.updateLiveText(newText)
                    // ★ 实时注入到光标处（替换之前的文本）
                    if oldLen == 0 {
                        await TextInjector.inject(text: newText)
                    } else {
                        await TextInjector.replaceInjected(oldLength: oldLen, newText: newText)
                    }
                    self.currentInjectedText = newText
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }

        // 启动轻量录音
        do {
            try rec.startRecordingLite()
            state = .recording
            print("[VoiceInput] 录音开始")
        } catch {
            appState.recordingMode = .idle
            errorMessage = "录音启动失败: \(error.localizedDescription)"
            state = .idle
            VoiceInputIndicatorWindow.shared.showError(message: "录音启动失败")
        }
    }

    private func stopVoiceInput() async {
        guard state == .recording, let appState = appState else { return }

        // 停止录音 + 轮询
        stopRecordingOnly()

        guard let sessionId = voiceInputSessionId,
              let service = appState.nativeASRService else {
            VoiceInputIndicatorWindow.shared.hide()
            finishVoiceInput(appState: appState)
            return
        }

        // ★ realtimeStop 处理尾部段（通常 0-1 段，快速返回）
        let result: NativeASRService.TranscribeResult?
        do {
            result = try await service.realtimeStop(sessionId: sessionId)
        } catch {
            print("[VoiceInput] realtimeStop 失败: \(error)")
            result = nil
        }

        let asrText = (result?.plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if asrText.isEmpty {
            print("[VoiceInput] ASR 无结果")
            VoiceInputIndicatorWindow.shared.hide()
            finishVoiceInput(appState: appState)
            return
        }

        // ★ 如果 realtimeStop 返回的文本比录音中已注入的更完整，先更新
        if asrText != currentInjectedText {
            let oldLen = currentInjectedText.count
            if oldLen == 0 {
                await TextInjector.inject(text: asrText)
            } else {
                await TextInjector.replaceInjected(oldLength: oldLen, newText: asrText)
            }
            currentInjectedText = asrText
        }

        // ★ LLM 纠错（如果开启）：优化后替换已注入的 ASR 原文
        if configStore.llmCorrectionEnabled {
            state = .correcting
            VoiceInputIndicatorWindow.shared.showCorrecting()
            let resolvedModel = configStore.resolvedModel(from: appState.llmConfigStore)
            let customPrompt = appState.llmConfigStore.asrOptimizePrompt.isEmpty ? nil : appState.llmConfigStore.asrOptimizePrompt
            let correctionResult = await correctionService.correct(
                text: asrText,
                model: resolvedModel,
                customPrompt: customPrompt
            )
            let finalText = correctionResult.correctedText

            if correctionResult.didUseLLM, finalText != currentInjectedText {
                // ★ 用 LLM 优化后的文本替换已注入的 ASR 原文
                await TextInjector.replaceInjected(oldLength: currentInjectedText.count, newText: finalText)
                currentInjectedText = finalText
                print("[VoiceInput] LLM 替换: \(asrText.prefix(20))... → \(finalText.prefix(20))...")
            }
            lastInjectedText = finalText
        } else {
            lastInjectedText = asrText
        }

        // 浮窗短暂显示结果后关闭
        VoiceInputIndicatorWindow.shared.showResult(text: currentInjectedText)
        finishVoiceInput(appState: appState)
    }

    private func stopRecordingOnly() {
        liveTextPollingTask?.cancel()
        liveTextPollingTask = nil
        recorder?.stopRecordingLite()
        recorder?.onAudioBuffer = nil
        recorder = nil
    }

    private func finishVoiceInput(appState: AppState) {
        appState.recordingMode = .idle
        voiceInputSessionId = nil
        currentInjectedText = ""
        state = .idle
    }
}
