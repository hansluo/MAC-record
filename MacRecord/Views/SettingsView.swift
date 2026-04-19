import SwiftUI

/// 设置视图 — 四个 Tab：ASR 模型 / AI 模型 / Prompt / 语音输入
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            ASRModelTab()
                .environmentObject(appState)
                .tabItem { Label("模型", systemImage: "waveform.badge.magnifyingglass") }

            LLMModelTab()
                .environmentObject(appState)
                .tabItem { Label("AI 模型", systemImage: "cpu") }

            PromptTab()
                .environmentObject(appState)
                .tabItem { Label("Prompt", systemImage: "text.bubble") }

            VoiceInputSettingsTab()
                .environmentObject(appState)
                .tabItem { Label("语音输入", systemImage: "mic.badge.plus") }
        }
        .frame(width: 640, height: 680)
    }
}

// MARK: - ASR 模型 Tab（Flow 风格）

struct ASRModelTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("模型")
                    .font(.title2.weight(.semibold))
                    .padding(.bottom, 4)

                ForEach(ASREngineType.allCases) { engine in
                    ASRModelCard(
                        engine: engine,
                        isSelected: appState.asrConfigStore.selectedEngine == engine,
                        isDownloaded: isDownloaded(engine),
                        onSelect: {
                            Task { await appState.switchASREngine(to: engine) }
                        },
                        onDownload: {
                            // TODO: 实际下载逻辑
                        }
                    )
                }
            }
            .padding(24)
        }
    }

    private func isDownloaded(_ engine: ASREngineType) -> Bool {
        switch engine {
        case .senseVoice: return appState.asrConfigStore.senseVoiceDownloaded
        case .senseVoiceNative: return true
        }
    }
}

/// ASR 模型卡片 — Flow 风格
struct ASRModelCard: View {
    let engine: ASREngineType
    let isSelected: Bool
    let isDownloaded: Bool
    let onSelect: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // 图标
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(iconBackground)
                    .frame(width: 52, height: 52)
                Image(systemName: engine.iconName)
                    .font(.title2)
                    .foregroundStyle(.white)
            }

            // 信息
            VStack(alignment: .leading, spacing: 4) {
                Text(engine.displayName)
                    .font(.headline)

                Text(engine.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    ForEach(engine.tags, id: \.0) { tag in
                        TagBadge(text: tag.0, color: tag.1)
                    }
                    Text("📦 \(engine.modelSize)")
                        .font(.caption2)
                        .foregroundStyle(.pink)
                }
            }

            Spacer()

            // 操作按钮
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            } else if isDownloaded {
                Button("选择") {
                    onSelect()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button {
                    onDownload()
                } label: {
                    Label("下载", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color(nsColor: .separatorColor).opacity(0.3), lineWidth: isSelected ? 2 : 1)
        )
    }

    private var iconBackground: Color {
        switch engine {
        case .senseVoice: return .blue
        case .senseVoiceNative: return .green
        }
    }
}

/// 标签 Badge
struct TagBadge: View {
    let text: String
    let color: TagColor

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bgColor.opacity(0.12))
            .foregroundStyle(bgColor)
            .cornerRadius(4)
    }

    private var bgColor: Color {
        switch color {
        case .orange: return .orange
        case .blue: return .blue
        case .purple: return .purple
        case .green: return .green
        }
    }
}

// MARK: - LLM 模型 Tab

struct LLMModelTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var showModelForm = false
    @State private var editingModel: LLMModelConfig?
    @State private var testResult: String = ""
    @State private var isTesting = false

    @State private var formLabel = ""
    @State private var formAPIURL = ""
    @State private var formAPIKey = ""
    @State private var formModelName = ""
    @State private var formKind = "remote"
    @State private var showAPIKey = false

    // 本地模型检测
    @State private var isDetecting = false
    @State private var detectedModels: [LLMService.DetectedModel] = []
    @State private var showDetectResult = false
    @State private var detectMessage = ""
    @State private var customPort: String = ""
    @State private var customApiKey: String = ""

    static let presets: [(name: String, url: String, models: [String])] = [
        ("DeepSeek", "https://api.deepseek.com/v1/chat/completions", ["deepseek-chat", "deepseek-reasoner"]),
        ("Google Gemini", "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", ["gemini-2.5-flash", "gemini-2.0-flash", "gemini-2.5-pro"]),
        ("通义千问", "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", ["qwen-turbo", "qwen-plus", "qwen-max"]),
        ("MiniMax", "https://api.minimax.chat/v1/text/chatcompletion_v2", ["MiniMax-Text-01", "abab6.5s-chat"]),
        ("OpenAI", "https://api.openai.com/v1/chat/completions", ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已配置的 AI 模型")
                .font(.headline)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(appState.llmConfigStore.models) { model in
                        modelRow(model)
                        Divider()
                    }
                }
                .id(appState.llmConfigStore.activeModelId)
            }
            .frame(minHeight: 140)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.3))
            )

            Divider()

            if showModelForm {
                modelForm
            } else {
                HStack {
                    Button("添加模型") {
                        editingModel = nil
                        resetForm()
                        showModelForm = true
                    }
                    .buttonStyle(.borderedProminent)

                    Menu("预设服务商") {
                        ForEach(Self.presets, id: \.name) { preset in
                            Menu(preset.name) {
                                ForEach(preset.models, id: \.self) { m in
                                    Button(m) {
                                        editingModel = nil
                                        formLabel = "\u{2601}\u{FE0F} \(m)"
                                        formAPIURL = preset.url
                                        formModelName = m
                                        formKind = "remote"
                                        formAPIKey = ""
                                        showModelForm = true
                                    }
                                }
                            }
                        }
                    }

                    Button {
                        detectLocalModels()
                    } label: {
                        if isDetecting {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 2)
                            Text("检测中...")
                        } else {
                            Label("检测本地模型", systemImage: "magnifyingglass")
                        }
                    }
                    .disabled(isDetecting)
                }

                // 自定义端口输入
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("端口，如 1235", text: $customPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        TextField("API Key（可选）", text: $customApiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                        Button {
                            detectByCustomPort()
                        } label: {
                            Label("检测", systemImage: "network")
                        }
                        .disabled(customPort.isEmpty || isDetecting)
                    }
                    Text("支持 oMLX / Ollama / LM Studio 等 OpenAI 兼容服务")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // 检测结果展示
                if showDetectResult {
                    detectResultView
                }
            }

            if !testResult.isEmpty {
                Text(testResult)
                    .font(.caption)
                    .foregroundStyle(testResult.hasPrefix("✅") ? .green : .red)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func modelRow(_ model: LLMModelConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.label.isEmpty ? model.modelName : model.label)
                        .fontWeight(.medium)
                    if model.kind == "local" {
                        Text("本地")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
                Text(model.apiURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()

            Button {
                startEditing(model)
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            if appState.llmConfigStore.activeModelId == model.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Button {
                    appState.llmConfigStore.setActiveModel(id: model.id)
                } label: {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.borderless)
            }

            Button(role: .destructive) {
                appState.llmConfigStore.removeModel(id: model.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var modelForm: some View {
        GroupBox(editingModel != nil ? "编辑模型" : "添加新模型") {
            VStack(alignment: .leading, spacing: 8) {
                formRow("标签:", TextField("例如: ☁️ deepseek-chat", text: $formLabel))
                formRow("API URL:", TextField("https://...", text: $formAPIURL))
                formRow("API Key:", HStack {
                    if showAPIKey {
                        TextField("sk-...", text: $formAPIKey)
                    } else {
                        SecureField("sk-...", text: $formAPIKey)
                    }
                    Button {
                        showAPIKey.toggle()
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                })
                formRow("模型名:", TextField("deepseek-chat", text: $formModelName))
                HStack {
                    Text("类型:").frame(width: 70, alignment: .trailing)
                    Picker("", selection: $formKind) {
                        Text("远程").tag("remote")
                        Text("本地").tag("local")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
                HStack(spacing: 8) {
                    Button("测试连接") { testConnection() }
                        .disabled(isTesting || formAPIURL.isEmpty || formModelName.isEmpty)
                    Button(editingModel != nil ? "保存修改" : "保存") { saveModel() }
                        .buttonStyle(.borderedProminent)
                        .disabled(formAPIURL.isEmpty || formModelName.isEmpty)
                    Button("取消") { showModelForm = false; resetForm() }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func formRow<V: View>(_ label: String, _ field: V) -> some View {
        HStack { Text(label).frame(width: 70, alignment: .trailing); field }
    }

    private func startEditing(_ model: LLMModelConfig) {
        editingModel = model
        formLabel = model.label
        formAPIURL = model.apiURL
        formAPIKey = appState.llmConfigStore.apiKey(for: model.id)
        formModelName = model.modelName
        formKind = model.kind
        testResult = ""
        showModelForm = true
        showAPIKey = true
    }

    private func testConnection() {
        isTesting = true; testResult = ""
        Task {
            let r = await LLMService().testConnection(apiURL: formAPIURL, apiKey: formAPIKey, modelName: formModelName)
            testResult = r.message; isTesting = false
        }
    }

    private func saveModel() {
        let id = editingModel?.id ?? "\(formKind)_\(formModelName.replacingOccurrences(of: "/", with: "_"))"
        let normalizedURL = LLMService.normalizeAPIURL(formAPIURL)
        let m = LLMModelConfig(id: id, label: formLabel.isEmpty ? formModelName : formLabel, apiURL: normalizedURL, apiKey: formAPIKey, modelName: formModelName, kind: formKind)
        appState.llmConfigStore.addModel(m)
        showModelForm = false; resetForm()
    }

    private func resetForm() {
        formLabel = ""; formAPIURL = ""; formAPIKey = ""; formModelName = ""; formKind = "remote"; testResult = ""; editingModel = nil
    }

    // MARK: - 本地模型检测

    @ViewBuilder
    private var detectResultView: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(detectMessage)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button {
                        showDetectResult = false
                        detectedModels = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

                if !detectedModels.isEmpty {
                    ForEach(detectedModels) { model in
                        HStack(spacing: 8) {
                            Image(systemName: model.provider.contains("Ollama") ? "hare" : model.provider.contains("oMLX") ? "apple.logo" : "desktopcomputer")
                                .foregroundStyle(model.provider.contains("Ollama") ? .purple : model.provider.contains("oMLX") ? .green : .blue)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.name)
                                    .font(.caption.weight(.medium))
                                HStack(spacing: 4) {
                                    Text(model.provider)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if !model.size.isEmpty {
                                        Text("(\(model.size))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Spacer()

                            // 检查是否已添加
                            if appState.llmConfigStore.models.contains(where: { $0.modelName == model.name && $0.apiURL == model.apiURL }) {
                                Text("已添加")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            } else {
                                Button("添加") {
                                    addDetectedModel(model)
                                }
                                .controlSize(.small)
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 2)
                        if model.id != detectedModels.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    private func detectLocalModels() {
        isDetecting = true
        showDetectResult = false
        detectedModels = []
        detectMessage = ""
        let port = Int(customPort)

        Task {
            let models = await LLMService().detectLocalModels(customPort: port)
            await MainActor.run {
                detectedModels = models
                isDetecting = false
                showDetectResult = true
                if models.isEmpty {
                    detectMessage = "未检测到本地模型服务"
                } else {
                    let providers = Set(models.map(\.provider))
                    detectMessage = "检测到 \(models.count) 个本地模型（\(providers.joined(separator: " + "))）"
                }
            }
        }
    }

    private func detectByCustomPort() {
        guard let port = Int(customPort), port > 0 else { return }
        isDetecting = true
        showDetectResult = false
        detectedModels = []
        detectMessage = ""
        let key = customApiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            let (models, diagnostic) = await LLMService().detectByPort(port: port, apiKey: key)
            await MainActor.run {
                detectedModels = models
                isDetecting = false
                showDetectResult = true
                if models.isEmpty {
                    detectMessage = diagnostic
                } else {
                    detectMessage = "端口 \(port) 检测到 \(models.count) 个模型"
                }
            }
        }
    }

    private func addDetectedModel(_ model: LLMService.DetectedModel) {
        let id = "local_\(model.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_"))"
        let emoji: String
        if model.provider.contains("Ollama") {
            emoji = "\u{1F430}"  // 🐰
        } else if model.provider.contains("oMLX") {
            emoji = "\u{26A1}"   // ⚡
        } else {
            emoji = "\u{1F4BB}"  // 💻
        }
        let config = LLMModelConfig(
            id: id,
            label: "\(emoji) \(model.name)",
            apiURL: model.apiURL,
            apiKey: customApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            modelName: model.name,
            kind: "local"
        )
        appState.llmConfigStore.addModel(config)
    }
}

// MARK: - Prompt Tab

struct PromptTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var showResetAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 纪要 Prompt
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("默认纪要 Prompt")
                            .font(.headline)
                        Spacer()
                        Button("恢复默认") { showResetAlert = true }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("用于 AI 纪要生成。使用 {text} 占位符表示转录文本插入位置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $appState.llmConfigStore.defaultPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 280)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor))
                        )
                }

                Divider()

                // ASR 纠错 Prompt
                VStack(alignment: .leading, spacing: 8) {
                    Text("语音输入纠错 Prompt")
                        .font(.headline)

                    Text("用于语音输入的 AI 纠错。作为 system message 发送。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $appState.llmConfigStore.asrOptimizePrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor))
                        )
                }

                HStack {
                    Button("保存") {
                        appState.llmConfigStore.save()
                    }
                    .buttonStyle(.borderedProminent)

                    Text("修改后点击保存生效")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding()
        }
        .alert("恢复默认 Prompt", isPresented: $showResetAlert) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) {
                appState.llmConfigStore.defaultPrompt = LLMConfigStore.builtinDefaultPrompt
                appState.llmConfigStore.asrOptimizePrompt = LLMConfigStore.builtinASRPrompt
                appState.llmConfigStore.save()
            }
        } message: {
            Text("将纪要 Prompt 和纠错 Prompt 恢复为内置默认值，当前自定义内容将丢失。")
        }
    }
}
