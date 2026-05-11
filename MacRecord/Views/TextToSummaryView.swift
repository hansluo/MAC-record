import SwiftUI
import SwiftData

/// 文本直接生成纪要视图 — 无需录音文件，粘贴文本即可生成 AI 纪要
struct TextToSummaryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var titleText = ""
    @State private var isGenerating = false
    @State private var progress = ""
    @State private var errorMessage: String?
    @State private var generatedSummary: String?

    /// 完成回调：传回新创建的 Recording ID
    var onComplete: ((UUID) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 700, minHeight: 550)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("生成失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("确定") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("文本转纪要")
                    .font(.title3.weight(.semibold))
                Text("粘贴会议文字记录、聊天记录或任意文本，直接生成 AI 纪要")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if generatedSummary != nil {
                Button("保存并关闭") {
                    saveAndClose()
                }
                .buttonStyle(.borderedProminent)
            }
            Button("关闭") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let summary = generatedSummary {
            resultView(summary: summary)
        } else {
            inputView
        }
    }

    @ViewBuilder
    private var inputView: some View {
        VStack(spacing: 16) {
            // 标题输入
            HStack {
                Text("标题")
                    .font(.subheadline.weight(.medium))
                    .frame(width: 40, alignment: .leading)
                TextField("例如：产品周会 2026-05-11", text: $titleText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // 文本输入区
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("文本内容")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(inputText.count) 字")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button {
                        if let clipboardText = NSPasteboard.general.string(forType: .string) {
                            inputText = clipboardText
                        }
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 20)

                TextEditor(text: $inputText)
                    .font(.body)
                    .lineSpacing(4)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .padding(.horizontal, 20)
                    .overlay(alignment: .center) {
                        if inputText.isEmpty {
                            Text("在此粘贴或输入会议文字记录、聊天记录、转录文本…\n支持任意长度文本，系统会自动分段处理")
                                .font(.body)
                                .foregroundStyle(.quaternary)
                                .multilineTextAlignment(.center)
                                .allowsHitTesting(false)
                        }
                    }
            }

            // 生成按钮
            HStack {
                Spacer()
                if isGenerating {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    generate()
                } label: {
                    HStack(spacing: 6) {
                        if isGenerating {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(isGenerating ? "生成中…" : "生成纪要")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.llmConfigStore.models.isEmpty)

                if appState.llmConfigStore.models.isEmpty {
                    Text("请先在设置中配置 AI 模型")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private func resultView(summary: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI 纪要", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                Spacer()
                if let model = appState.llmConfigStore.activeModel {
                    Text(model.modelName)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.08))
                        .cornerRadius(4)
                        .foregroundStyle(.blue)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(summary, forType: .string)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    generatedSummary = nil
                } label: {
                    Label("重新生成", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ScrollView {
                MarkdownView(text: summary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Actions

    private func generate() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isGenerating = true
        progress = "准备中…"
        let configStore = appState.llmConfigStore

        Task {
            defer {
                Task { @MainActor in
                    isGenerating = false
                    progress = ""
                }
            }
            do {
                let generator = SummaryGenerator(configStore: configStore)
                generator.onProgress = { current, total, desc in
                    Task { @MainActor in
                        progress = desc
                    }
                }
                let result = try await generator.generateSummary(text: text)
                await MainActor.run {
                    generatedSummary = result
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func saveAndClose() {
        guard let summary = generatedSummary else { return }
        let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 创建一个 Recording（无音频文件，只有文本+纪要）
        let recording = Recording(
            title: title.isEmpty ? "文本纪要 \(Self.dateString())" : title,
            plainText: inputText.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: Date(),
            updatedAt: Date()
        )
        modelContext.insert(recording)

        let aiSummary = AISummary(
            prompt: appState.llmConfigStore.activePrompt,
            summary: summary,
            modelName: appState.llmConfigStore.activeModelName,
            createdAt: Date()
        )
        aiSummary.recording = recording
        modelContext.insert(aiSummary)

        onComplete?(recording.id)
        dismiss()
    }

    private static func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }
}
