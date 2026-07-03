import SwiftUI
import SwiftData

/// 录音详情视图 — 精致的 macOS 原生风格
struct DetailView: View {
    @Bindable var recording: Recording
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext

    @State private var activeTab: DetailTab = .asr
    @State private var isGeneratingSummary = false
    @State private var generatingSummaryRecordingId: UUID?  // 正在生成纪要的录音 ID
    @State private var isRenaming = false
    @State private var editTitle = ""
    @State private var isDiarizing = false
    @State private var isRetranscribing = false
    @State private var expectedSpeakers: Int = 0  // 0=自动检测
    @State private var diarizationProgress: Float = 0  // 0~1 进度
    @State private var diarizingRecordingId: UUID?      // 正在 diarize 的录音 ID
    /// 用于强制刷新纪要区域
    @State private var summaryRefreshID = UUID()
    /// 纪要生成错误信息（非空时显示 Alert）
    @State private var summaryError: String?
    /// 纪要生成进度描述
    @State private var summaryProgress: String = ""

    enum DetailTab: String, CaseIterable {
        case asr = "ASR 原文"
        case summary = "AI 纪要"
    }

    var body: some View {
        VStack(spacing: 0) {
            // 播放区域
            playbackSection
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Divider()
                .padding(.horizontal, 16)

            // 标题 + Tab 栏
            headerSection
                .padding(.horizontal, 24)
                .padding(.top, 12)

            // 内容区
            contentSection
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("纪要生成失败", isPresented: Binding(
            get: { summaryError != nil },
            set: { if !$0 { summaryError = nil } }
        )) {
            Button("确定") { summaryError = nil }
        } message: {
            Text(summaryError ?? "")
        }
    }

    // MARK: - Playback Section

    @ViewBuilder
    private var playbackSection: some View {
        VStack(spacing: 12) {
            // 波形
            PlaybackControls(recording: recording)
        }
    }

    // MARK: - Header (Title + Tabs)

    @ViewBuilder
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 标题行
            HStack(alignment: .center) {
                if isRenaming {
                    TextField("录音名称", text: $editTitle)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                        .onSubmit { commitRename() }
                        .onExitCommand { isRenaming = false }
                } else {
                    Text(recording.title)
                        .font(.title3.weight(.semibold))
                        .onTapGesture(count: 2) {
                            editTitle = recording.title
                            isRenaming = true
                        }
                }

                Button {
                    editTitle = recording.title
                    isRenaming = true
                } label: {
                    Image(systemName: "pencil.line")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)

                Spacer()

                // 元信息
                VStack(alignment: .trailing, spacing: 2) {
                    Text(recording.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if let lang = recording.detectedLanguage {
                        Text(lang)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.08))
                            .cornerRadius(4)
                            .foregroundStyle(.blue)
                    }
                }
            }

            // Tab 栏 + 操作按钮
            HStack(spacing: 0) {
                // Tab 按钮
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { activeTab = tab }
                    } label: {
                        Text(tab.rawValue)
                            .font(.subheadline.weight(activeTab == tab ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(
                                activeTab == tab
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear
                            )
                            .foregroundStyle(activeTab == tab ? .primary : .secondary)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // 重新转录（有音频文件时始终可用）
                if recording.audioPath != nil, activeTab == .asr {
                    Button {
                        retranscribe()
                    } label: {
                        Label(isRetranscribing ? "转录中…" : "重新转录", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRetranscribing || isDiarizing || !appState.isModelReady)

                    // 区分说话人
                    Menu {
                        Button("自动检测人数") {
                            expectedSpeakers = 0
                            performDiarization()
                        }
                        Divider()
                        ForEach(2...8, id: \.self) { n in
                            Button("\(n) 人") {
                                expectedSpeakers = n
                                performDiarization()
                            }
                        }
                    } label: {
                        Label(
                            isDiarizing ? "识别中…" : (recording.diarizedText != nil ? "重新区分" : "区分说话人"),
                            systemImage: "person.2.wave.2"
                        )
                        .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: isDiarizing ? 90 : (recording.diarizedText != nil ? 85 : 100))
                    .disabled(isDiarizing || isRetranscribing || !appState.isModelReady)
                }

                // 复制
                Button {
                    copyCurrentText()
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch activeTab {
                case .asr:
                    asrPanel
                case .summary:
                    summaryPanel
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    @ViewBuilder
    private var asrPanel: some View {
        let text = recording.plainText ?? ""
        if text.isEmpty && recording.diarizedText == nil {
            VStack(spacing: 16) {
                Image(systemName: "text.badge.xmark")
                    .font(.system(size: 32))
                    .foregroundStyle(.quaternary)
                Text("该录音暂无转录文本")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)

                if recording.audioPath != nil {
                    Button {
                        retranscribe()
                    } label: {
                        Label(isRetranscribing ? "转录中…" : "补转录", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isRetranscribing)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        } else if let diarized = recording.diarizedText, !diarized.isEmpty {
            // 带说话人标签的文本
            VStack(alignment: .leading, spacing: 4) {
                if let count = recording.diarizedSpeakerCount, count > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill")
                            .font(.caption2)
                        Text("检测到 \(count) 位说话人")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
                }

                DiarizedTextView(text: diarized)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .font(.body)
                .lineSpacing(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        // Diarization 进度（仅当前录音正在处理时显示）
        if isDiarizing && diarizingRecordingId == recording.id {
            VStack(spacing: 6) {
                ProgressView(value: Double(diarizationProgress), total: 1.0)
                    .progressViewStyle(.linear)
                HStack(spacing: 4) {
                    Text("正在区分说话人… \(Int(diarizationProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var summaryPanel: some View {
        let isSummaryInProgress = isGeneratingSummary && generatingSummaryRecordingId == recording.id
        VStack(alignment: .leading, spacing: 16) {
            // 生成按钮
            HStack {
                Button {
                    generateSummary()
                } label: {
                    HStack(spacing: 6) {
                        if isSummaryInProgress {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isSummaryInProgress ? "生成中…" : "生成 AI 纪要")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSummaryInProgress || ((recording.plainText ?? "").isEmpty && (recording.diarizedText ?? "").isEmpty))

                if appState.llmConfigStore.models.isEmpty {
                    Text("请先在设置中配置 AI 模型")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if isSummaryInProgress, !summaryProgress.isEmpty {
                    Text(summaryProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 最新纪要（只显示最新一份）
            if let summaries = recording.summaries,
               let latest = summaries.sorted(by: { $0.createdAt > $1.createdAt }).first {
                SummaryCard(summary: latest)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(summaryRefreshID)
    }

    // MARK: - Actions

    private func commitRename() {
        let trimmed = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            recording.title = trimmed
            recording.updatedAt = Date()
        }
        isRenaming = false
    }

    private func copyCurrentText() {
        var text = ""
        switch activeTab {
        case .asr:
            // 优先复制带说话人标签的文本
            if let diarized = recording.diarizedText, !diarized.isEmpty {
                text = diarized
            } else {
                text = recording.plainText ?? ""
            }
        case .summary:
            text = recording.summaries?.sorted(by: { $0.createdAt > $1.createdAt }).first?.summary ?? ""
        }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func generateSummary() {
        // 优先使用带说话人标签的文本
        let text: String
        if let diarized = recording.diarizedText, !diarized.isEmpty {
            text = diarized
        } else if let plain = recording.plainText, !plain.isEmpty {
            text = plain
        } else {
            return
        }
        isGeneratingSummary = true
        generatingSummaryRecordingId = recording.id
        summaryProgress = "准备中…"
        let targetRecording = recording
        let configStore = appState.llmConfigStore
        Task {
            defer {
                Task { @MainActor in
                    self.isGeneratingSummary = false
                    self.generatingSummaryRecordingId = nil
                    self.summaryProgress = ""
                }
            }
            do {
                let generator = SummaryGenerator(configStore: configStore)
                generator.onProgress = { current, total, desc in
                    Task { @MainActor in
                        self.summaryProgress = desc
                    }
                }
                let summaryText = try await generator.generateSummary(text: text)
                await MainActor.run {
                    // 删除旧纪要，只保留最新一份
                    if let oldSummaries = targetRecording.summaries {
                        for old in oldSummaries {
                            modelContext.delete(old)
                        }
                    }
                    let summary = AISummary(
                        prompt: configStore.activePrompt,
                        summary: summaryText,
                        modelName: configStore.activeModelName,
                        createdAt: Date()
                    )
                    summary.recording = targetRecording
                    modelContext.insert(summary)
                    // 强制刷新纪要区域
                    summaryRefreshID = UUID()
                }
            } catch {
                print("纪要生成失败: \(error)")
                await MainActor.run {
                    self.summaryError = error.localizedDescription
                }
            }
        }
    }

    private func retranscribe() {
        guard let audioPath = recording.audioPath else { return }
        isRetranscribing = true
        let fullPath = AudioFileManager.shared.fullPath(for: audioPath)
        let targetRecording = recording

        Task {
            defer {
                Task { @MainActor in self.isRetranscribing = false }
            }
            do {
                if let service = appState.nativeASRService {
                    let result = try await service.transcribeFile(
                        audioPath: fullPath,
                        language: "auto"
                    )
                    await MainActor.run {
                        targetRecording.plainText = result.plainText
                        targetRecording.detectedLanguage = result.detectedLanguage
                        targetRecording.updatedAt = Date()
                    }
                }
            } catch {
                print("补转录失败: \(error)")
            }
        }
    }

    private func performDiarization() {
        guard let audioPath = recording.audioPath else { return }
        isDiarizing = true
        diarizationProgress = 0
        diarizingRecordingId = recording.id
        let fullPath = AudioFileManager.shared.fullPath(for: audioPath)
        let targetRecording = recording
        let speakers = Int32(expectedSpeakers)

        Task {
            defer {
                Task { @MainActor in
                    self.isDiarizing = false
                    self.diarizationProgress = 0
                    self.diarizingRecordingId = nil
                }
            }
            do {
                if let service = appState.nativeASRService {
                    let result = try await service.diarize(
                        audioPath: fullPath,
                        numSpeakers: speakers,
                        onProgress: { progress in
                            Task { @MainActor in
                                self.diarizationProgress = progress
                            }
                        }
                    )
                    await MainActor.run {
                        targetRecording.diarizedText = result.text
                        targetRecording.diarizedSpeakerCount = Int(result.numSpeakers)
                        targetRecording.updatedAt = Date()
                    }
                }
            } catch {
                print("说话人分离失败: \(error)")
            }
        }
    }
}

// MARK: - Diarized Text View

/// 带说话人标签的文本展示组件
struct DiarizedTextView: View {
    let text: String

    // 说话人颜色
    private static let speakerColors: [Color] = [
        .blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if let parsed = parseSpeakerLine(line) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(parsed.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(colorForSpeaker(parsed.speakerIndex))
                            .frame(width: 60, alignment: .trailing)
                        Text(parsed.content)
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(line)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .padding(.leading, 68)
                }
            }
        }
    }

    private var lines: [String] {
        text.components(separatedBy: "\n")
    }

    private struct ParsedLine {
        let label: String
        let speakerIndex: Int
        let content: String
    }

    private func parseSpeakerLine(_ line: String) -> ParsedLine? {
        // 匹配 "说话人N: 内容"
        let prefix = "说话人"
        guard line.hasPrefix(prefix) else { return nil }

        // 找到 ": " 分隔符
        guard let colonRange = line.range(of: ": ") else { return nil }

        let label = String(line[line.startIndex..<colonRange.lowerBound])
        let content = String(line[colonRange.upperBound...])

        // 从 label 提取数字（"说话人1" → 1）
        let numStr = label.dropFirst(prefix.count)
        let idx = Int(numStr) ?? 1

        return ParsedLine(label: label, speakerIndex: idx - 1, content: content)
    }

    private func colorForSpeaker(_ index: Int) -> Color {
        Self.speakerColors[index % Self.speakerColors.count]
    }
}

// MARK: - Summary Card

struct SummaryCard: View {
    let summary: AISummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AI 纪要", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                Spacer()
                if let model = summary.modelName {
                    Text(model)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.08))
                        .cornerRadius(4)
                        .foregroundStyle(.blue)
                }
                Text(summary.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            MarkdownView(text: summary.summary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator.opacity(0.3), lineWidth: 0.5)
        )
        .textSelection(.enabled)
    }
}
