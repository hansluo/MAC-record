import AppKit
import ApplicationServices

/// 辅助功能权限检测和引导工具
struct AccessibilityHelper {

    /// 检查辅助功能权限是否已授权
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// 检查权限，如未授权则弹出系统引导对话框
    /// - Returns: 当前是否已授权
    @discardableResult
    static func checkAndRequestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 打开系统设置的辅助功能面板
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
