import SwiftUI

/// 播放控件 — 精致的波形 + 播放按钮
struct PlaybackControls: View {
    let recording: Recording
    @StateObject private var player = AudioPlayerService()

    var body: some View {
        VStack(spacing: 10) {
            // 静态波形 + 播放进度（支持点击/拖拽跳转）
            StaticWaveformView(
                levels: waveformData,
                progress: player.duration > 0 ? player.currentTime / player.duration : 0,
                onSeek: hasAudio ? { progress in
                    player.seek(to: progress * player.duration)
                } : nil
            )
            .frame(height: 64)

            // 控制行
            HStack(spacing: 16) {
                // 后退 15s
                Button {
                    player.seekRelative(-15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!hasAudio)

                // 播放/暂停
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(!hasAudio)

                // 前进 15s
                Button {
                    player.seekRelative(15)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!hasAudio)

                Spacer()

                // 时间
                Text("\(fmtTime(player.currentTime)) / \(fmtTime(player.duration))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear { loadAudio() }
        .onChange(of: recording.id) { _, _ in loadAudio() }
        .onDisappear { player.stop() }
    }

    private var hasAudio: Bool {
        recording.audioPath != nil
    }

    private var waveformData: [Float] {
        guard let dur = recording.duration, dur > 0 else {
            return Array(repeating: Float(0.05), count: 100)
        }
        // 生成基于时长的伪随机波形（后续可替换为真实波形数据）
        let count = min(300, max(80, Int(dur * 3)))
        var rng = RandomNumberGenerator16807(seed: UInt64(recording.id.hashValue & 0x7FFFFFFF))
        return (0..<count).map { _ in
            Float.random(in: 0.08...0.55, using: &rng)
        }
    }

    private func loadAudio() {
        guard let audioPath = recording.audioPath else { return }
        let url = AudioFileManager.shared.fullURL(for: audioPath)
        player.load(url: url)
    }

    private func fmtTime(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t/3600, (t%3600)/60, t%60)
            : String(format: "%d:%02d", t/60, t%60)
    }
}

/// 确定性伪随机（同一录音每次波形一致）
struct RandomNumberGenerator16807: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = max(seed, 1) }
    mutating func next() -> UInt64 {
        state = (state &* 16807) % 2147483647
        return state
    }
}

/// 静态波形视图 — 带播放进度，支持点击/拖拽跳转
struct StaticWaveformView: View {
    let levels: [Float]
    var progress: Double = 0
    var onSeek: ((Double) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let count = levels.count
                guard count > 0 else { return }

                let barWidth: CGFloat = 2.5
                let gap: CGFloat = 1.5
                let maxBars = Int(size.width / (barWidth + gap))
                let display = count > maxBars ? Array(levels.prefix(maxBars)) : levels
                let midY = size.height / 2
                let progressX = size.width * CGFloat(progress)

                for (i, level) in display.enumerated() {
                    let x = CGFloat(i) * (barWidth + gap)
                    let normalized = min(max(CGFloat(level), 0.04), 1.0)
                    let barH = max(2, normalized * size.height * 0.9)

                    let rect = CGRect(
                        x: x,
                        y: midY - barH / 2,
                        width: barWidth,
                        height: barH
                    )

                    let played = x < progressX
                    let color: Color = played
                        ? .accentColor
                        : .secondary.opacity(0.25)

                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(color)
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = max(0, min(1, value.location.x / geo.size.width))
                        onSeek?(p)
                    }
                    .onEnded { value in
                        let p = max(0, min(1, value.location.x / geo.size.width))
                        onSeek?(p)
                    }
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
    }
}
