import AppKit
import Combine

/// 热键类型
enum HotkeyType: String, Codable, CaseIterable, Identifiable {
    case command
    case rightCommand
    case option
    case control
    case fn

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .command: return "⌘ Command"
        case .rightCommand: return "⌘ 右 Command"
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .fn: return "🌐 Fn"
        }
    }

    /// 对应的 NSEvent.ModifierFlags
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .command, .rightCommand: return .command
        case .option: return .option
        case .control: return .control
        case .fn: return .function
        }
    }
}

/// 全局热键管理器
/// 支持长按修饰键触发语音输入，短按正常传递给系统
@MainActor
class HotkeyManager: ObservableObject {

    // MARK: - 回调
    var onLongPressStart: (() -> Void)?
    var onLongPressEnd: (() -> Void)?

    // MARK: - 配置
    @Published var hotkeyType: HotkeyType = .option
    @Published var longPressThresholdMs: Int = 400
    @Published var isEnabled: Bool = true

    // MARK: - 状态
    @Published private(set) var isLongPressing: Bool = false

    // MARK: - 私有
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var longPressTask: Task<Void, Never>?
    private var keyDownTime: Date?
    private var isKeyHeld: Bool = false
    /// 每次按下递增，松开时检查是否匹配，防止竞态
    private var pressGeneration: UInt64 = 0

    // MARK: - 生命周期

    func start() {
        stop()

        // 全局监听（app 不在前台时）
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
        }

        // 本地监听（app 在前台时）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleFlagsChanged(event)
            }
            return event  // 不拦截事件，让系统继续处理
        }

        print("[HotkeyManager] 热键监听已启动: \(hotkeyType.displayName)")
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        cancelLongPress()
        // 完整重置所有内部状态，防止切换热键时残留
        isKeyHeld = false
        isLongPressing = false
        keyDownTime = nil
        pressGeneration &+= 1
        print("[HotkeyManager] 热键监听已停止（状态已重置）")
    }

    deinit {
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - 事件处理

    private func handleFlagsChanged(_ event: NSEvent) {
        guard isEnabled else { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let targetFlag = hotkeyType.modifierFlag
        let isTargetDown = flags.contains(targetFlag)

        // 对于右 Command，检查 rawValue 中的特定位
        if hotkeyType == .rightCommand {
            let rightCmdBit: UInt = 0x10  // NX_DEVICERCMDKEYMASK
            let isRightCmd = (event.modifierFlags.rawValue & rightCmdBit) != 0
            if isTargetDown && !isRightCmd {
                // 左 Command 按下，忽略
                return
            }
        }

        if isTargetDown && !isKeyHeld {
            // 按键按下
            handleKeyDown()
        } else if !isTargetDown && isKeyHeld {
            // 按键松开
            handleKeyUp()
        }
    }

    private func handleKeyDown() {
        isKeyHeld = true
        keyDownTime = Date()
        pressGeneration &+= 1
        let currentGen = pressGeneration

        // 启动长按检测
        let thresholdMs = longPressThresholdMs
        longPressTask?.cancel()
        longPressTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(thresholdMs) * 1_000_000)
            } catch {
                return  // Task 被 cancel
            }
            guard let self = self,
                  self.isKeyHeld,
                  self.pressGeneration == currentGen else { return }
            self.isLongPressing = true
            self.onLongPressStart?()
        }
    }

    private func handleKeyUp() {
        let wasLongPressing = isLongPressing

        isKeyHeld = false
        keyDownTime = nil
        cancelLongPress()

        if wasLongPressing {
            isLongPressing = false
            onLongPressEnd?()
        }
    }

    private func cancelLongPress() {
        longPressTask?.cancel()
        longPressTask = nil
    }
}
