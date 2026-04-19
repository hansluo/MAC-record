import SwiftUI

/// 菜单栏下拉视图 — 语音输入状态 + 控制
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 状态显示
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Divider()

            // 语音输入开关
            Toggle(isOn: Binding(
                get: { appState.voiceInputService.configStore.isEnabled },
                set: { newValue in
                    appState.voiceInputService.configStore.isEnabled = newValue
                    appState.voiceInputService.configStore.save()
                    appState.voiceInputService.reloadConfig()
                }
            )) {
                Label("语音输入", systemImage: "mic.badge.plus")
            }
            .padding(.horizontal, 12)

            // 热键提示
            HStack {
                Image(systemName: "command")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("长按 \(appState.voiceInputService.configStore.hotkeyType.displayName) 说话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)

            // 辅助功能权限状态
            if !AccessibilityHelper.isAccessibilityGranted {
                Divider()
                Button {
                    AccessibilityHelper.checkAndRequestAccessibility()
                } label: {
                    Label("授权辅助功能权限", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
            }

            // 上次注入的文字
            if !appState.voiceInputService.lastInjectedText.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("上次输入")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(appState.voiceInputService.lastInjectedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
            }

            // 错误信息
            if let error = appState.voiceInputService.errorMessage {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }

            Divider()

            // 设置入口
            SettingsLink {
                Label("设置…", systemImage: "gear")
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)

            // 退出
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("退出 Mac-Record", systemImage: "power")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(width: 260)
    }

    private var statusColor: Color {
        switch appState.voiceInputService.state {
        case .idle: return appState.voiceInputService.configStore.isEnabled ? .green : .gray
        case .recording: return .red
        case .correcting: return .blue
        case .injecting: return .purple
        }
    }

    private var statusText: String {
        switch appState.voiceInputService.state {
        case .idle: return appState.voiceInputService.configStore.isEnabled ? "就绪" : "已关闭"
        case .recording: return "录音中…"
        case .correcting: return "优化中…"
        case .injecting: return "注入中…"
        }
    }
}
