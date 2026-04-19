import Foundation

/// ASR 引擎类型
enum ASREngineType: String, Codable, CaseIterable, Identifiable {
    case senseVoice = "sensevoice"
    case senseVoiceNative = "sensevoice_native"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .senseVoice: return "SenseVoice (Python)"
        case .senseVoiceNative: return "SenseVoice (原生)"
        }
    }

    var provider: String {
        switch self {
        case .senseVoice: return "Alibaba"
        case .senseVoiceNative: return "Alibaba"
        }
    }

    var description: String {
        switch self {
        case .senseVoice: return "SenseVoice 通过 Python 子进程运行（需要 Python 环境）"
        case .senseVoiceNative: return "SenseVoice 原生集成，零 Python 依赖，进程内直接运行"
        }
    }

    var languages: String {
        return "中文, 英文, 日文, 韩文, 粤语"
    }

    var modelSize: String {
        switch self {
        case .senseVoice: return "937.9 MB (Python)"
        case .senseVoiceNative: return "228 MB (int8)"
        }
    }

    var iconName: String {
        switch self {
        case .senseVoice: return "waveform.badge.magnifyingglass"
        case .senseVoiceNative: return "brain.head.profile"
        }
    }

    var tags: [(String, TagColor)] {
        switch self {
        case .senseVoice:
            return [("Alibaba", .orange), ("Python", .purple)]
        case .senseVoiceNative:
            return [("Alibaba", .orange), ("原生", .green), ("零依赖", .blue)]
        }
    }
}

enum TagColor {
    case orange, blue, purple, green
}

/// ASR 配置存储
class ASRConfigStore: ObservableObject {
    @Published var selectedEngine: ASREngineType = .senseVoiceNative
    @Published var senseVoiceDownloaded: Bool = true  // 测试期间默认已下载

    private let configURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MacRecord", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        configURL = appDir.appendingPathComponent("asr_config.json")
        load()
    }

    func save() {
        let data = ASRConfigData(
            selectedEngine: selectedEngine.rawValue,
            senseVoiceDownloaded: senseVoiceDownloaded
        )
        if let jsonData = try? JSONEncoder().encode(data) {
            try? jsonData.write(to: configURL)
        }
    }

    func load() {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(ASRConfigData.self, from: data) else { return }
        if let engine = ASREngineType(rawValue: config.selectedEngine) {
            selectedEngine = engine
        }
        senseVoiceDownloaded = config.senseVoiceDownloaded
    }
}

private struct ASRConfigData: Codable {
    var selectedEngine: String
    var senseVoiceDownloaded: Bool
}
