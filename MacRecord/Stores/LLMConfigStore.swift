import Foundation

/// AI 模型配置存储
class LLMConfigStore: ObservableObject {
    @Published var models: [LLMModelConfig] = []
    @Published var activeModelId: String = ""
    @Published var defaultPrompt: String = ""
    @Published var asrOptimizePrompt: String = ""
    @Published var promptTemplates: [String: String] = [:]

    // MARK: - 内置默认 Prompt

    static let builtinDefaultPrompt = """
    请对以下会议/语音转录文本进行详细整理，生成一份完整的会议纪要。要求：
    1. **详细记录**：尽可能完整地保留所有讨论内容、观点、数据和细节，不要过度压缩或精简
    2. **结构化整理**：按讨论议题/时间线组织，使用清晰的标题和分段
    3. **修正识别错误**：修正明显的语音识别错误（错别字、断句），但保持原意
    4. **保留原始语义**：不要添加原文没有的内容，不要用自己的话改写发言者的表述
    5. **标注关键信息**：明确标出决策结论、行动项（TODO）、责任人和截止时间
    6. 输出格式使用 Markdown

    {text}
    """

    static let builtinASRPrompt = """
    你是语音输入纠错助手。用户通过语音输入了一段文字，ASR 引擎可能产生同音字/近音字错误、缺少标点。
    请修正为正确的书面文字。
    规则：
    1. 纠正同音字/近音字/形近字错误，从语义角度推断正确内容
    2. 添加正确的标点符号
    3. 删除明显的口头禅重复（如连续的"那个"、"就是"、"嗯"）
    4. 保持原意不变，不要扩写或添加用户没说的内容
    5. 直接输出修正后的文字，不要有任何解释
    """

    /// 迁移标记，防止每次启动重复从 whisper_env 迁移
    private var hasMigrated: Bool = false

    private let configURL: URL
    private let promptsURL: URL

    var activeModel: LLMModelConfig? {
        guard var model = models.first(where: { $0.id == activeModelId }) ?? models.first else { return nil }
        // 从 KeychainHelper 填充 API Key
        let storedKey = apiKey(for: model.id)
        if !storedKey.isEmpty {
            model.apiKey = storedKey
        }
        return model
    }

    var activeModelName: String {
        activeModel?.modelName ?? "未配置"
    }

    var activePrompt: String {
        defaultPrompt
    }

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MacRecord", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        configURL = appDir.appendingPathComponent("ai_config.json")
        promptsURL = appDir.appendingPathComponent("ai_prompts.json")

        // 内置默认值（load 会覆盖已保存的值）
        defaultPrompt = LLMConfigStore.builtinDefaultPrompt
        asrOptimizePrompt = LLMConfigStore.builtinASRPrompt

        load()
    }

    // MARK: - CRUD

    func addModel(_ model: LLMModelConfig) {
        // API Key 单独存储到 KeychainHelper，不写入 JSON
        if !model.apiKey.isEmpty {
            KeychainHelper.save(key: "llm_\(model.id)", value: model.apiKey)
        }
        var stored = model
        stored.apiKey = "" // JSON 中不存 key
        models.removeAll(where: { $0.id == stored.id })
        models.append(stored)
        if activeModelId.isEmpty || models.count == 1 {
            activeModelId = stored.id
        }
        save()
    }

    func removeModel(id: String) {
        KeychainHelper.delete(key: "llm_\(id)")
        models.removeAll(where: { $0.id == id })
        if activeModelId == id {
            activeModelId = models.first?.id ?? ""
        }
        save()
    }

    func setActiveModel(id: String) {
        if models.contains(where: { $0.id == id }) {
            activeModelId = id
            save()
        }
    }

    /// 获取模型的 API Key（从 KeychainHelper 读取）
    func apiKey(for modelId: String) -> String {
        KeychainHelper.load(key: "llm_\(modelId)") ?? ""
    }

    // MARK: - Persistence

    private let saveQueue = DispatchQueue(label: "com.macrecord.llmconfig.save", qos: .utility)

    func save() {
        let data = ConfigData(
            models: models,
            activeModelId: activeModelId,
            defaultPrompt: defaultPrompt,
            asrOptimizePrompt: asrOptimizePrompt,
            hasMigrated: hasMigrated
        )
        let prompts = promptTemplates
        let configPath = configURL
        let promptsPath = promptsURL

        saveQueue.async {
            if let jsonData = try? JSONEncoder().encode(data) {
                try? jsonData.write(to: configPath)
            }
            if let promptData = try? JSONEncoder().encode(prompts) {
                try? promptData.write(to: promptsPath)
            }
        }
    }

    func load() {
        if let rawData = try? Data(contentsOf: configURL) {
            if let config = try? JSONDecoder().decode(ConfigData.self, from: rawData) {
                self.models = config.models
                self.activeModelId = config.activeModelId
                self.defaultPrompt = config.defaultPrompt
                self.asrOptimizePrompt = config.asrOptimizePrompt
                self.hasMigrated = config.hasMigrated
            }
        }
        // 如果为空且未迁移过，尝试从旧配置迁移
        if models.isEmpty && !hasMigrated {
            migrateFromWhisperEnv()
        }
        // Prompts
        if let data = try? Data(contentsOf: promptsURL),
           let prompts = try? JSONDecoder().decode([String: String].self, from: data) {
            self.promptTemplates = prompts
        }
        if promptTemplates.isEmpty {
            migratePromptsFromWhisperEnv()
        }
    }

    // MARK: - 从旧项目迁移

    private func migrateFromWhisperEnv() {
        let oldConfigPath = NSHomeDirectory() + "/Desktop/whisper_env/ai_config.json"
        guard FileManager.default.fileExists(atPath: oldConfigPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: oldConfigPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            hasMigrated = true
            save()
            return
        }

        if let validatedModels = json["validated_models"] as? [[String: Any]] {
            for m in validatedModels {
                let config = LLMModelConfig(
                    id: m["id"] as? String ?? UUID().uuidString,
                    label: m["label"] as? String ?? "",
                    apiURL: m["api_url"] as? String ?? "",
                    apiKey: m["api_key"] as? String ?? "",
                    modelName: m["model_name"] as? String ?? "",
                    kind: m["kind"] as? String ?? "remote"
                )
                addModel(config)
            }
        }

        if let activeId = json["active_model_id"] as? String {
            activeModelId = activeId
        }
        if let prompt = json["default_prompt"] as? String {
            defaultPrompt = prompt
        }
        if let asrPrompt = json["asr_optimize_prompt"] as? String {
            asrOptimizePrompt = asrPrompt
        }
        hasMigrated = true
        save()
    }

    private func migratePromptsFromWhisperEnv() {
        let oldPath = NSHomeDirectory() + "/Desktop/whisper_env/ai_prompts.json"
        guard FileManager.default.fileExists(atPath: oldPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: oldPath)),
              let prompts = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        self.promptTemplates = prompts
        save()
    }
}

/// 模型配置数据
struct LLMModelConfig: Codable, Identifiable, Equatable {
    var id: String
    var label: String
    var apiURL: String
    var apiKey: String
    var modelName: String
    var kind: String  // "local" | "remote"
    /// 模型 context window 大小（token 数），0 表示未设置
    var contextWindow: Int

    init(id: String = UUID().uuidString, label: String = "", apiURL: String = "", apiKey: String = "",
         modelName: String = "", kind: String = "remote", contextWindow: Int = 0) {
        self.id = id
        self.label = label
        self.apiURL = apiURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.kind = kind
        self.contextWindow = contextWindow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        apiURL = try container.decode(String.self, forKey: .apiURL)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        modelName = try container.decode(String.self, forKey: .modelName)
        kind = try container.decode(String.self, forKey: .kind)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? 0
    }
}

/// 持久化数据结构
private struct ConfigData: Codable {
    var models: [LLMModelConfig]
    var activeModelId: String
    var defaultPrompt: String
    var asrOptimizePrompt: String
    var hasMigrated: Bool

    init(models: [LLMModelConfig], activeModelId: String, defaultPrompt: String, asrOptimizePrompt: String, hasMigrated: Bool = false) {
        self.models = models
        self.activeModelId = activeModelId
        self.defaultPrompt = defaultPrompt
        self.asrOptimizePrompt = asrOptimizePrompt
        self.hasMigrated = hasMigrated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decode([LLMModelConfig].self, forKey: .models)
        activeModelId = try container.decode(String.self, forKey: .activeModelId)
        defaultPrompt = try container.decode(String.self, forKey: .defaultPrompt)
        asrOptimizePrompt = try container.decode(String.self, forKey: .asrOptimizePrompt)
        hasMigrated = try container.decodeIfPresent(Bool.self, forKey: .hasMigrated) ?? false
    }
}
