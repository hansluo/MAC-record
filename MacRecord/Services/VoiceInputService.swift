import Foundation
import AVFoundation
import Combine

/// 语音输入状态机
enum VoiceInputState: Equatable {
    case idle
    case starting
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
    private var audioPump: RealtimeAudioPump?
    private var stopRequestedWhileStarting = false

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

    func reloadConfig() async {
        hotkeyManager.stop()
        if state == .starting || state == .recording {
            await stopVoiceInput()
        }
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

        guard !appState.hasActiveTranscriptions else {
            errorMessage = "文件转录进行中，请完成或取消后再使用语音输入"
            VoiceInputIndicatorWindow.shared.showError(message: "文件转录进行中")
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
        stopRequestedWhileStarting = false
        state = .starting

        // 显示浮窗（录音状态）
        VoiceInputIndicatorWindow.shared.show()

        appState.recordingMode = .voiceInput

        let rec = AudioRecorder()
        self.recorder = rec

        let sessionId = UUID().uuidString
        self.voiceInputSessionId = sessionId

        guard let service = appState.nativeASRService,
              appState.selectedASRModel.capabilities.supportsRealtime else {
            appState.recordingMode = .idle
            state = .idle
            recorder = nil
            voiceInputSessionId = nil
            errorMessage = "当前引擎不支持实时语音输入，请选择 SenseVoice 或 Qwen"
            VoiceInputIndicatorWindow.shared.showError(message: "请选择实时识别引擎")
            return
        }
        do {
            try await service.realtimeStartForVoiceInput(sessionId: sessionId)
        } catch {
            appState.recordingMode = .idle
            state = .idle
            recorder = nil
            voiceInputSessionId = nil
            errorMessage = error.localizedDescription
            VoiceInputIndicatorWindow.shared.showError(message: "ASR 会话启动失败")
            return
        }

        // buffer 回调只复制采样并投递到有界队列，不创建无上限 Task。
        let pump = RealtimeAudioPump(service: service, sessionId: sessionId)
        audioPump = pump
        rec.onAudioBuffer = { buffer in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(
                start: channelData,
                count: Int(buffer.frameLength)
            ))
            pump.enqueue(samples)
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
            if stopRequestedWhileStarting {
                stopRequestedWhileStarting = false
                await stopVoiceInput()
            }
        } catch {
            liveTextPollingTask?.cancel()
            liveTextPollingTask = nil
            if let audioPump {
                await audioPump.finish()
                self.audioPump = nil
            }
            await service.realtimeCancel(sessionId: sessionId)
            recorder = nil
            voiceInputSessionId = nil
            appState.recordingMode = .idle
            errorMessage = "录音启动失败: \(error.localizedDescription)"
            state = .idle
            VoiceInputIndicatorWindow.shared.showError(message: "录音启动失败")
        }
    }

    private func stopVoiceInput() async {
        if state == .starting {
            stopRequestedWhileStarting = true
            return
        }
        guard state == .recording, let appState = appState else { return }

        // 停止录音并等待有界队列清空，再 finalize ASR。
        stopRecordingOnly()
        if let audioPump {
            await audioPump.finish()
            self.audioPump = nil
        }

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
