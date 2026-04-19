import AppKit
import SwiftUI
import Combine

/// 语音输入浮窗 — 使用 NSPanel 实现，悬浮于所有窗口上方且不抢焦点
/// 录音时实时显示 ASR 文字，松开后显示 LLM 优化状态和最终文字
@MainActor
class VoiceInputIndicatorWindow {

    // MARK: - 单例
    static let shared = VoiceInputIndicatorWindow()

    // MARK: - 状态模型
    private let viewModel = VoiceInputIndicatorViewModel()

    // MARK: - 窗口
    private var panel: NSPanel?

    private init() {}

    // MARK: - 公开 API

    /// 显示浮窗（进入录音状态）
    func show() {
        viewModel.state = .recording
        viewModel.text = ""
        ensurePanel()
        panel?.orderFrontRegardless()
    }

    /// 更新实时 ASR 文字（录音中调用）
    func updateLiveText(_ text: String) {
        viewModel.text = text
    }

    /// 切换到 LLM 纠错中状态
    func showCorrecting() {
        viewModel.state = .correcting
    }

    /// 显示最终文字并自动关闭
    func showResult(text: String) {
        viewModel.state = .result
        viewModel.text = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.hide()
        }
    }

    /// 显示错误并自动关闭
    func showError(message: String) {
        viewModel.state = .error
        viewModel.text = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.hide()
        }
    }

    /// 隐藏浮窗
    func hide() {
        panel?.orderOut(nil)
        viewModel.state = .hidden
    }

    // MARK: - 窗口管理

    private func ensurePanel() {
        guard panel == nil else { return }

        let contentView = VoiceInputIndicatorView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: contentView)

        let panelWidth: CGFloat = 360
        let panelHeight: CGFloat = 60

        // 屏幕底部居中（类似微信输入法）
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let originX = screenFrame.midX - panelWidth / 2
        let originY = screenFrame.minY + 80

        let panel = NSPanel(
            contentRect: NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = hostingView

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        if let container = panel.contentView {
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: container.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }

        self.panel = panel
    }
}

// MARK: - ViewModel

enum VoiceInputIndicatorState: Equatable {
    case hidden
    case recording    // 录音中，实时显示 ASR 文字
    case correcting   // LLM 优化中
    case result       // 最终文字
    case error
}

@MainActor
class VoiceInputIndicatorViewModel: ObservableObject {
    @Published var state: VoiceInputIndicatorState = .hidden
    @Published var text: String = ""
}

// MARK: - SwiftUI View

struct VoiceInputIndicatorView: View {
    @ObservedObject var viewModel: VoiceInputIndicatorViewModel

    var body: some View {
        Group {
            switch viewModel.state {
            case .hidden:
                EmptyView()
            case .recording:
                recordingContent
            case .correcting:
                statusContent(icon: "sparkles", label: "优化中…", color: .purple)
            case .result:
                resultContent
            case .error:
                statusContent(icon: "exclamationmark.triangle.fill", label: viewModel.text, color: .orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: 200, maxWidth: 360)
        .background(backgroundView)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }

    // MARK: - 录音中（实时文字）

    @ViewBuilder
    private var recordingContent: some View {
        HStack(spacing: 10) {
            // 麦克风图标 + 脉冲动画
            MicPulse()
                .frame(width: 28, height: 28)

            if viewModel.text.isEmpty {
                Text("正在聆听…")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text(viewModel.text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 4)

            Text("松开结束")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    // MARK: - 状态

    @ViewBuilder
    private func statusContent(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: true)

            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer()
        }
    }

    // MARK: - 结果

    @ViewBuilder
    private var resultContent: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.green)

            Text(viewModel.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            Spacer()
        }
    }

    // MARK: - 背景

    @ViewBuilder
    private var backgroundView: some View {
        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
    }
}

// MARK: - 麦克风脉冲图标

struct MicPulse: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.green.opacity(0.15))
                .scaleEffect(isAnimating ? 1.4 : 1.0)
                .opacity(isAnimating ? 0 : 0.5)

            Circle()
                .fill(.green.opacity(0.25))
                .frame(width: 28, height: 28)

            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }
}

// MARK: - NSVisualEffectView 桥接

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
