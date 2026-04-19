import Foundation
import AppKit
import UserNotifications

/// 系统休眠/唤醒管理器
/// 监听 NSWorkspace 的 willSleep / didWake 通知，在录音时自动暂停/恢复
@MainActor
class SleepWakeManager {

    weak var appState: AppState?

    /// 标记是否因休眠而暂停（区分用户手动暂停）
    private(set) var wasPausedBySleep = false

    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init() {
        requestNotificationPermission()
    }

    func setup(appState: AppState) {
        self.appState = appState
        registerObservers()
    }

    deinit {
        if let sleepObserver { NotificationCenter.default.removeObserver(sleepObserver) }
        if let wakeObserver { NotificationCenter.default.removeObserver(wakeObserver) }
    }

    // MARK: - 通知注册

    private func registerObservers() {
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleWillSleep()
            }
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleDidWake()
            }
        }

        print("[SleepWake] 休眠/唤醒监听已注册")
    }

    // MARK: - 休眠处理

    private func handleWillSleep() {
        guard let appState = appState else { return }

        switch appState.recordingMode {
        case .normalRecording(_, let paused):
            if !paused {
                // 正在录音且未暂停 → 自动暂停
                wasPausedBySleep = true

                if appState.audioSource == .systemAudio {
                    // 系统音频：停止 stream（休眠后 ScreenCaptureKit 会失效）
                    Task {
                        if let sysRecorder = appState.systemAudioRecorder {
                            await sysRecorder.pauseForSleep()
                        }
                    }
                } else {
                    // 麦克风：使用现有暂停逻辑
                    Task { await appState.togglePauseRecording() }
                }
                print("[SleepWake] 录音因休眠自动暂停")
            }

        case .voiceInput:
            // 语音输入模式休眠不处理（短按交互，用户不会在休眠时使用）
            break

        case .idle:
            break
        }
    }

    // MARK: - 唤醒处理

    private func handleDidWake() {
        guard let appState = appState, wasPausedBySleep else { return }
        wasPausedBySleep = false

        // 延迟 1.5 秒等待音频硬件恢复
        Task {
            try? await Task.sleep(for: .milliseconds(1500))

            guard case .normalRecording(_, let paused) = appState.recordingMode, paused else { return }

            if appState.audioSource == .systemAudio {
                if let sysRecorder = appState.systemAudioRecorder {
                    await sysRecorder.resumeFromSleep()
                }
            } else {
                await appState.togglePauseRecording()
            }

            print("[SleepWake] 录音已从休眠恢复")
            sendResumeNotification()
        }
    }

    // MARK: - 系统通知

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendResumeNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Mac-Record"
        content.body = "录音已恢复 — 电脑从休眠中唤醒，录音已自动继续"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "recording-resumed-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
