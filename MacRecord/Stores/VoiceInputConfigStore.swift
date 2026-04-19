import Foundation

/// 语音输入配置存储
class VoiceInputConfigStore: ObservableObject {
    @Published var isEnabled: Bool = true
    @Published var hotkeyType: HotkeyType = .option
    @Published var longPressThresholdMs: Int = 400
    @Published var llmCorrectionEnabled: Bool = true
    @Published var shortThreshold: Int = 10

    /// 语音输入纠错使用的模型 ID（空值表示跟随全局活跃模型）
    @Published var voiceInputModelId: String = ""

    private let configURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MacRecord", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        configURL = appDir.appendingPathComponent("voice_input_config.json")
        load()
    }

    /// 解析语音输入纠错实际使用的模型（优先 voiceInputModelId，否则 fallback 全局活跃模型）
    func resolvedModel(from llmStore: LLMConfigStore) -> LLMModelConfig? {
        if !voiceInputModelId.isEmpty,
           var model = llmStore.models.first(where: { $0.id == voiceInputModelId }) {
            let key = llmStore.apiKey(for: model.id)
            if !key.isEmpty { model.apiKey = key }
            return model
        }
        return llmStore.activeModel
    }

    func save() {
        let configData = VoiceInputConfigData(
            isEnabled: isEnabled,
            hotkeyType: hotkeyType.rawValue,
            longPressThresholdMs: longPressThresholdMs,
            llmCorrectionEnabled: llmCorrectionEnabled,
            shortThreshold: shortThreshold,
            voiceInputModelId: voiceInputModelId
        )
        do {
            let jsonData = try JSONEncoder().encode(configData)
            try jsonData.write(to: configURL, options: .atomic)
            print("[VoiceInputConfig] 配置已保存: hotkeyType=\(hotkeyType.rawValue)")
        } catch {
            print("[VoiceInputConfig] ⚠️ 保存失败: \(error.localizedDescription), path=\(configURL.path)")
        }
    }

    func load() {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            print("[VoiceInputConfig] 无配置文件，使用默认值: hotkeyType=\(hotkeyType.rawValue)")
            return
        }
        do {
            let data = try Data(contentsOf: configURL)
            let config = try JSONDecoder().decode(VoiceInputConfigData.self, from: data)
            isEnabled = config.isEnabled
            if let hk = HotkeyType(rawValue: config.hotkeyType) {
                hotkeyType = hk
            }
            longPressThresholdMs = config.longPressThresholdMs
            llmCorrectionEnabled = config.llmCorrectionEnabled
            shortThreshold = config.shortThreshold
            voiceInputModelId = config.voiceInputModelId ?? ""
            print("[VoiceInputConfig] 配置已加载: hotkeyType=\(hotkeyType.rawValue)")
        } catch {
            print("[VoiceInputConfig] ⚠️ 加载失败: \(error.localizedDescription)")
        }
    }
}

private struct VoiceInputConfigData: Codable {
    var isEnabled: Bool
    var hotkeyType: String
    var longPressThresholdMs: Int
    var llmCorrectionEnabled: Bool
    var shortThreshold: Int
    var voiceInputModelId: String?
}
