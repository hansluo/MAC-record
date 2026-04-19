import AppKit
import ApplicationServices

/// 文本注入器 — 通过剪贴板 + 模拟 Cmd+V 将文字注入到当前聚焦的输入框
struct TextInjector {

    /// 将文本注入到当前聚焦的输入框
    /// 流程：备份剪贴板 → 写入文本 → 模拟 Cmd+V → 延迟后恢复剪贴板
    static func inject(text: String) async {
        guard !text.isEmpty else { return }
        guard AccessibilityHelper.isAccessibilityGranted else {
            print("[TextInjector] 辅助功能权限未授权，无法注入文本")
            return
        }

        // 1. 备份当前剪贴板内容
        let pasteboard = NSPasteboard.general
        let backup = backupPasteboard(pasteboard)

        // 2. 写入要注入的文本
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. 小延迟让剪贴板内容生效
        try? await Task.sleep(for: .milliseconds(50))

        // 4. 模拟 Cmd+V 粘贴
        simulatePaste()

        // 5. 延迟后恢复原剪贴板内容
        try? await Task.sleep(for: .milliseconds(200))
        restorePasteboard(pasteboard, from: backup)

        print("[TextInjector] 文本已注入: \(text.prefix(30))...")
    }

    /// 替换之前注入的文本：先选中 oldLength 个字符，再粘贴新文本
    /// 用于实时更新（录音中 ASR 文字增量更新 / LLM 优化后替换）
    static func replaceInjected(oldLength: Int, newText: String) async {
        guard !newText.isEmpty, oldLength > 0 else {
            // 没有旧文本可替换，直接注入
            await inject(text: newText)
            return
        }
        guard AccessibilityHelper.isAccessibilityGranted else { return }

        let pasteboard = NSPasteboard.general
        let backup = backupPasteboard(pasteboard)

        // 1. 选中之前注入的文本（Shift+Left × oldLength）
        simulateSelectBackward(count: oldLength)
        try? await Task.sleep(for: .milliseconds(30))

        // 2. 粘贴新文本（替换选中内容）
        pasteboard.clearContents()
        pasteboard.setString(newText, forType: .string)
        try? await Task.sleep(for: .milliseconds(30))
        simulatePaste()

        // 3. 恢复剪贴板
        try? await Task.sleep(for: .milliseconds(200))
        restorePasteboard(pasteboard, from: backup)
    }

    // MARK: - 剪贴板备份/恢复

    private struct PasteboardBackup {
        let items: [NSPasteboardItem]
        let types: [NSPasteboard.PasteboardType]
        let stringContent: String?
    }

    private static func backupPasteboard(_ pasteboard: NSPasteboard) -> PasteboardBackup {
        let stringContent = pasteboard.string(forType: .string)
        return PasteboardBackup(
            items: [],
            types: pasteboard.types ?? [],
            stringContent: stringContent
        )
    }

    private static func restorePasteboard(_ pasteboard: NSPasteboard, from backup: PasteboardBackup) {
        pasteboard.clearContents()
        if let str = backup.stringContent {
            pasteboard.setString(str, forType: .string)
        }
    }

    // MARK: - 模拟按键

    private static func simulatePaste() {
        let vKeyCode: CGKeyCode = 9
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true) else { return }
        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else { return }
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
    }

    /// 模拟 Shift+Left 选中 count 个字符（向左选中）
    private static func simulateSelectBackward(count: Int) {
        let leftArrowKeyCode: CGKeyCode = 123
        let source = CGEventSource(stateID: .hidSystemState)

        for _ in 0..<count {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: leftArrowKeyCode, keyDown: true) else { continue }
            keyDown.flags = .maskShift
            keyDown.post(tap: .cghidEventTap)

            guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: leftArrowKeyCode, keyDown: false) else { continue }
            keyUp.flags = .maskShift
            keyUp.post(tap: .cghidEventTap)
        }
    }
}
