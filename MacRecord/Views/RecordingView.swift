import SwiftUI

/// 录音中视图 — Apple 语音备忘录风格
struct RecordingView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = RecordingViewModel()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // 标题 + 计时
            VStack(spacing: 8) {
                Text("新录音")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(viewModel.formattedDuration)
                    .font(.system(size: 48, weight: .light, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.8))
                    .contentTransition(.numericText())

                // 录音状态
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.isPaused ? .orange : .red)
                        .frame(width: 8, height: 8)
                        .opacity(appState.isPaused ? 1 : blinkOpacity)
                    Text(appState.isPaused ? "已暂停" : "录音中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 实时波形
            LiveWaveformView(levels: viewModel.audioLevels)
                .frame(height: 100)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)

            Divider()
                .padding(.horizontal)

            // ASR 实时文本
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("ASR 实时转写", systemImage: "text.word.spacing")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        copyText()
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.liveText.isEmpty)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)

                ScrollView {
                    ScrollViewReader { proxy in
                        Text(viewModel.liveText.isEmpty ? "等待语音输入…" : viewModel.liveText)
                            .font(.body)
                            .foregroundStyle(viewModel.liveText.isEmpty ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                            .textSelection(.enabled)
                            .id("bottom")
                            .onChange(of: viewModel.liveText) { _, _ in
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            }
                    }
                }
            }

            Spacer()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { viewModel.bind(appState: appState) }
        .onDisappear { viewModel.unbind() }
    }

    @State private var blinkOpacity: Double = 1.0

    private func copyText() {
        guard !viewModel.liveText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.liveText, forType: .string)
    }
}

// MARK: - RecordingViewModel

@MainActor
class RecordingViewModel: ObservableObject {
    @Published var liveText: String = ""
    @Published var audioLevels: [Float] = []
    @Published var elapsedMs: Int = 0

    private var appState: AppState?
    private var pollingTask: Task<Void, Never>?

    var formattedDuration: String {
        let totalSeconds = elapsedMs / 1000
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        let tenths = (elapsedMs % 1000) / 100
        return String(format: "%02d:%02d.%d", mins, secs, tenths)
    }

    func bind(appState: AppState) {
        self.appState = appState
        // 清零所有状态，防止新录音显示旧文本
        liveText = ""
        audioLevels = []
        elapsedMs = 0
        startPolling()
    }

    func unbind() {
        pollingTask?.cancel()
        pollingTask = nil
        liveText = ""
        audioLevels = []
        elapsedMs = 0
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, let appState = self.appState else { break }

                // 时间 + 电平
                if appState.audioSource == .systemAudio {
                    if let sysRec = appState.systemAudioRecorder {
                        self.elapsedMs = Int(sysRec.elapsedTime * 1000)
                        self.audioLevels = sysRec.recentLevels
                    }
                } else if let recorder = appState.audioRecorder {
                    self.elapsedMs = Int(recorder.elapsedTime * 1000)
                    self.audioLevels = recorder.recentLevels
                }

                // ASR 文本
                let engine = appState.asrConfigStore.selectedEngine
                if engine == .senseVoiceNative {
                    if let service = appState.nativeASRService,
                       let sessionId = appState.currentSessionId {
                        let snapshot = await service.getRealtimeSnapshot(sessionId: sessionId.uuidString)
                        if !snapshot.plainText.isEmpty {
                            self.liveText = snapshot.plainText
                        }
                    }
                } else if engine == .senseVoice {
                    if let bridge = appState.asrBridge,
                       let sessionId = appState.currentSessionId {
                        if let snapshot = try? await bridge.getRealtimeSnapshot(sessionId: sessionId.uuidString) {
                            self.liveText = snapshot.plainText
                        }
                    }
                }

                let interval: Duration = engine == .senseVoiceNative ? .milliseconds(300) : .seconds(1)
                try? await Task.sleep(for: interval)
            }
        }
    }
}

// MARK: - LiveWaveformView

/// 实时波形视图 — 更饱满的风格
struct LiveWaveformView: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let totalWidth = size.width
                let barWidth: CGFloat = 3
                let gap: CGFloat = 2
                let maxBars = Int(totalWidth / (barWidth + gap))
                let displayLevels: [Float]

                if levels.count > maxBars {
                    displayLevels = Array(levels.suffix(maxBars))
                } else {
                    displayLevels = levels
                }

                let midY = size.height / 2
                let startX = totalWidth - CGFloat(displayLevels.count) * (barWidth + gap)

                for (i, level) in displayLevels.enumerated() {
                    let normalizedLevel = min(max(CGFloat(level) * 8, 0.03), 1.0)
                    let barHeight = max(3, normalizedLevel * size.height * 0.85)
                    let x = startX + CGFloat(i) * (barWidth + gap)

                    let rect = CGRect(
                        x: x,
                        y: midY - barHeight / 2,
                        width: barWidth,
                        height: barHeight
                    )

                    let intensity = min(normalizedLevel * 1.5, 1.0)
                    let color = Color.blue.opacity(0.3 + Double(intensity) * 0.7)

                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(color)
                    )
                }

                // 中线
                let lineRect = CGRect(x: 0, y: midY - 0.5, width: totalWidth, height: 1)
                context.fill(Path(lineRect), with: .color(.blue.opacity(0.1)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.blue.opacity(0.03))
        )
    }
}
