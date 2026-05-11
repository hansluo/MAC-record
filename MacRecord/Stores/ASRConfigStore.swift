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

    /// Python 环境安装状态
    @Published var pythonInstallState: PythonInstallState = .idle
    @Published var pythonInstallProgress: String = ""

    enum PythonInstallState: Equatable {
        case idle
        case checking
        case installing(step: String)
        case ready
        case failed(String)
    }

    private let configURL: URL

    /// Python 虚拟环境的标准安装路径
    static let pythonEnvPath: String = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MacRecord/python_env", isDirectory: true).path
    }()

    /// 检查 Python 环境是否可用
    var isPythonEnvReady: Bool {
        let envPath = Self.pythonEnvPath
        let pythonPath = envPath + "/bin/python3"
        let serverScript = envPath + "/asr_server.py"
        return FileManager.default.fileExists(atPath: pythonPath)
            && FileManager.default.fileExists(atPath: serverScript)
    }

    /// 查找可用的系统 Python3 路径
    static func findSystemPython() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// 也检查开发环境的 whisper_env
    var pythonEnvDir: String? {
        // 优先 App Support 下的标准路径
        let standardPath = Self.pythonEnvPath
        if FileManager.default.fileExists(atPath: standardPath + "/bin/python3") {
            return standardPath
        }
        // App Bundle 内
        if let bundlePath = Bundle.main.resourcePath {
            let bundleEnv = bundlePath + "/python_env"
            if FileManager.default.fileExists(atPath: bundleEnv + "/bin/python3") {
                return bundleEnv
            }
        }
        // 开发环境
        let devPath = NSHomeDirectory() + "/Desktop/whisper_env"
        if FileManager.default.fileExists(atPath: devPath + "/bin/python3") {
            return devPath
        }
        return nil
    }

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
