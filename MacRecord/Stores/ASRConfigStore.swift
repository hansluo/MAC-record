import Foundation

/// 标签颜色
enum TagColor {
    case orange, blue, purple, green
}

/// ASR 配置存储 — 基于模型 ID 的选择机制
class ASRConfigStore: ObservableObject {
    @Published var selectedModelId: ASRModelID = .senseVoiceInt8
    @Published var mossHotwords: [String] = []

    var mossHotwordsText: String {
        get { mossHotwords.joined(separator: ", ") }
        set {
            mossHotwords = newValue
                .split(whereSeparator: { $0 == "," || $0 == "，" || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    private let configURL: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let appDir = appSupport.appendingPathComponent("MacRecord", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        configURL = appDir.appendingPathComponent("asr_config.json")
        load()
    }

    /// 当前选中的模型信息
    var selectedModel: ASRModelInfo {
        ModelRegistry.model(for: selectedModelId)
    }

    func save() {
        let data = ASRConfigData(
            selectedModelId: selectedModelId.rawValue,
            mossHotwords: mossHotwords
        )
        if let jsonData = try? JSONEncoder().encode(data) {
            try? jsonData.write(to: configURL)
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(ASRConfigData.self, from: data) else { return }
        if let modelId = ASRModelID(rawValue: config.selectedModelId) {
            selectedModelId = modelId
        }
        mossHotwords = config.mossHotwords ?? []
    }
}

private struct ASRConfigData: Codable {
    var selectedModelId: String
    var mossHotwords: [String]?
}
