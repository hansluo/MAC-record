import Foundation

// MARK: - ASR 模型定义

/// ASR 模型族类型
enum ASRModelFamily: String, Codable {
    case senseVoice
    case qwen3ASR
    case appleSpeech
}

/// ASR 模型唯一标识
enum ASRModelID: String, Codable, CaseIterable, Identifiable {
    case senseVoiceInt8 = "sensevoice-int8"
    case senseVoiceFull = "sensevoice-full"
    case qwen3ASR06BInt8 = "qwen3-asr-0.6b-int8"
    case qwen3ASR17BInt8 = "qwen3-asr-1.7b-int8"

    var id: String { rawValue }
}

struct RemoteModelFile: Sendable {
    let relativePath: String
    let downloadURL: String
    let expectedSize: Int64
    let sha256: String
}

/// ASR 模型元数据
struct ASRModelInfo {
    let id: ASRModelID
    let displayName: String
    let family: ASRModelFamily
    let provider: String
    let description: String
    let languages: String
    let modelSize: String          // 显示用的大小描述
    let downloadSizeBytes: Int64   // 下载包大小（压缩后）
    let iconName: String
    let tags: [(String, TagColor)]
    let capabilities: ASRCapabilities
    let isBuiltin: Bool            // 是否内置在 App Bundle 中
    let downloadURL: String?       // 单压缩包下载地址（内置/多文件模型为 nil）
    let archiveName: String?       // 压缩包名（用于解压）
    let downloadFiles: [RemoteModelFile]

    init(
        id: ASRModelID,
        displayName: String,
        family: ASRModelFamily,
        provider: String,
        description: String,
        languages: String,
        modelSize: String,
        downloadSizeBytes: Int64,
        iconName: String,
        tags: [(String, TagColor)],
        capabilities: ASRCapabilities,
        isBuiltin: Bool,
        downloadURL: String?,
        archiveName: String?,
        downloadFiles: [RemoteModelFile] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.family = family
        self.provider = provider
        self.description = description
        self.languages = languages
        self.modelSize = modelSize
        self.downloadSizeBytes = downloadSizeBytes
        self.iconName = iconName
        self.tags = tags
        self.capabilities = capabilities
        self.isBuiltin = isBuiltin
        self.downloadURL = downloadURL
        self.archiveName = archiveName
        self.downloadFiles = downloadFiles
    }
}

// MARK: - 模型注册表

struct ModelRegistry {
    private static let qwen3ASR17BRevision = "69eb686fd94a4a865bb5340a3d6ac0d7f1fec0d5"
    private static let qwen3ASR17BBaseURL = "https://huggingface.co/thieunv/sherpa-onnx-qwen3-asr-1.7B-int8/resolve/\(qwen3ASR17BRevision)"
    private static let qwen3ASR17BFiles: [RemoteModelFile] = [
        RemoteModelFile(relativePath: "conv_frontend.onnx", downloadURL: "\(qwen3ASR17BBaseURL)/conv_frontend.onnx", expectedSize: 48_080_441, sha256: "3cb27a9fe94d95c938e476f2012b21aba2ec0bfceef33b0e58acd208946bafdd"),
        RemoteModelFile(relativePath: "encoder.int8.onnx", downloadURL: "\(qwen3ASR17BBaseURL)/encoder.int8.onnx", expectedSize: 314_222_162, sha256: "a5deedae034ece715de8ed204378d8c77f889af3a60c2566581135e84cced7cd"),
        RemoteModelFile(relativePath: "decoder.int8.onnx", downloadURL: "\(qwen3ASR17BBaseURL)/decoder.int8.onnx", expectedSize: 2_037_458_645, sha256: "c43c853fa6e97d08365cb8a5502b360b595cd43c00dc60e4d8ca7cc18cad460b"),
        RemoteModelFile(relativePath: "tokenizer/merges.txt", downloadURL: "\(qwen3ASR17BBaseURL)/tokenizer/merges.txt", expectedSize: 1_671_853, sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
        RemoteModelFile(relativePath: "tokenizer/tokenizer_config.json", downloadURL: "\(qwen3ASR17BBaseURL)/tokenizer/tokenizer_config.json", expectedSize: 12_487, sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
        RemoteModelFile(relativePath: "tokenizer/vocab.json", downloadURL: "\(qwen3ASR17BBaseURL)/tokenizer/vocab.json", expectedSize: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ]

    /// 所有已注册模型
    static let allModels: [ASRModelInfo] = [
        ASRModelInfo(
            id: .senseVoiceInt8,
            displayName: "SenseVoice INT8",
            family: .senseVoice,
            provider: "Alibaba",
            description: "SenseVoice 量化版本，体积小、速度快，适合日常使用",
            languages: "中文, 英文, 日文, 韩文, 粤语",
            modelSize: "239.5 MB",
            downloadSizeBytes: 0,
            iconName: "brain.head.profile",
            tags: [("Alibaba", .orange), ("原生", .green), ("INT8", .blue)],
            capabilities: .native,
            isBuiltin: true,
            downloadURL: nil,
            archiveName: nil
        ),
        ASRModelInfo(
            id: .senseVoiceFull,
            displayName: "SenseVoice",
            family: .senseVoice,
            provider: "Alibaba",
            description: "SenseVoice 全精度版本，识别精度更高，支持情感检测",
            languages: "中文, 英文, 日文, 韩文, 粤语",
            modelSize: "937.9 MB",
            downloadSizeBytes: 937_900_000,
            iconName: "waveform.badge.magnifyingglass",
            tags: [("Alibaba", .orange), ("原生", .green), ("全精度", .purple)],
            capabilities: .native,
            isBuiltin: false,
            downloadURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2",
            archiveName: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
        ),
        ASRModelInfo(
            id: .qwen3ASR06BInt8,
            displayName: "Qwen3-ASR 0.6B INT8",
            family: .qwen3ASR,
            provider: "Alibaba Qwen",
            description: "Qwen3 语音识别模型，支持 30+ 语言和 23 种中国方言",
            languages: "30+ 语言, 23 种中文方言",
            modelSize: "987.7 MB",
            downloadSizeBytes: 987_700_000,
            iconName: "globe",
            tags: [("Qwen", .orange), ("原生", .green), ("INT8", .blue)],
            capabilities: .native,
            isBuiltin: false,
            downloadURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2025-03-25.tar.bz2",
            archiveName: "sherpa-onnx-qwen3-asr-0.6B-int8-2025-03-25"
        ),
        ASRModelInfo(
            id: .qwen3ASR17BInt8,
            displayName: "Qwen3-ASR 1.7B INT8",
            family: .qwen3ASR,
            provider: "Alibaba Qwen",
            description: "更高精度的 Qwen3 语音识别模型，适合中文、方言和复杂会议录音",
            languages: "30+ 语言, 22 种中文方言/口音",
            modelSize: "2.24 GB",
            downloadSizeBytes: 2_404_222_421,
            iconName: "waveform.badge.magnifyingglass",
            tags: [("Qwen", .orange), ("高精度", .purple), ("INT8", .blue)],
            capabilities: .native,
            isBuiltin: false,
            downloadURL: nil,
            archiveName: nil,
            downloadFiles: qwen3ASR17BFiles
        ),
    ]

    /// 根据 ID 查找模型信息
    static func model(for id: ASRModelID) -> ASRModelInfo {
        allModels.first { $0.id == id }!
    }

    /// 模型本地存储根目录
    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("MacRecord/models", isDirectory: true)
    }

    /// 获取模型的本地目录路径
    static func modelDirectory(for id: ASRModelID) -> URL {
        modelsDirectory.appendingPathComponent(id.rawValue, isDirectory: true)
    }

    /// 检查模型是否已下载（对内置模型始终返回 true）
    static func isModelDownloaded(_ id: ASRModelID) -> Bool {
        let info = model(for: id)
        if info.isBuiltin {
            return modelPaths(for: id) != nil
        }
        return validateModelFiles(for: id, in: modelDirectory(for: id))
    }

    static func validateModelFiles(for id: ASRModelID, in modelDir: URL) -> Bool {
        switch model(for: id).family {
        case .senseVoice:
            return FileManager.default.fileExists(
                atPath: modelDir.appendingPathComponent("model.onnx").path
            )
        case .qwen3ASR:
            let requiredPaths = [
                modelDir.appendingPathComponent("conv_frontend.onnx"),
                modelDir.appendingPathComponent("encoder.int8.onnx"),
                modelDir.appendingPathComponent("decoder.int8.onnx"),
                modelDir.appendingPathComponent("tokenizer", isDirectory: true),
            ]
            return requiredPaths.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        case .appleSpeech:
            return true
        }
    }

    /// 获取模型文件路径（用于加载）
    static func modelPaths(for id: ASRModelID) -> ModelPaths? {
        let info = model(for: id)

        switch info.family {
        case .senseVoice:
            return senseVoicePaths(for: id, isInt8: id == .senseVoiceInt8)
        case .qwen3ASR:
            return qwen3ASRPaths(for: id)
        case .appleSpeech:
            return nil
        }
    }

    // MARK: - SenseVoice 路径

    private static func senseVoicePaths(for id: ASRModelID, isInt8: Bool) -> ModelPaths? {
        let modelFileName = isInt8 ? "model.int8.onnx" : "model.onnx"

        if isInt8 {
            // 内置模型：从 Bundle 或开发路径查找
            if let bundlePath = Bundle.main.resourceURL {
                let bundleModel = bundlePath.appendingPathComponent("sensevoice-model")
                if FileManager.default.fileExists(
                    atPath: bundleModel.appendingPathComponent(modelFileName).path
                ) {
                    return .senseVoice(
                        modelPath: bundleModel.appendingPathComponent(modelFileName).path,
                        tokensPath: bundleModel.appendingPathComponent("tokens.txt").path
                    )
                }
                // 直接在 Bundle 根
                if FileManager.default.fileExists(
                    atPath: bundlePath.appendingPathComponent(modelFileName).path
                ) {
                    return .senseVoice(
                        modelPath: bundlePath.appendingPathComponent(modelFileName).path,
                        tokensPath: bundlePath.appendingPathComponent("tokens.txt").path
                    )
                }
            }
            // 开发路径
            let devDir = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Desktop/Mac-Record/MacRecord/Resources/sensevoice-model")
            if FileManager.default.fileExists(
                atPath: devDir.appendingPathComponent(modelFileName).path
            ) {
                return .senseVoice(
                    modelPath: devDir.appendingPathComponent(modelFileName).path,
                    tokensPath: devDir.appendingPathComponent("tokens.txt").path
                )
            }
            return nil
        } else {
            // 下载的全精度模型
            let modelDir = modelDirectory(for: id)
            let modelPath = modelDir.appendingPathComponent(modelFileName).path
            let tokensPath = modelDir.appendingPathComponent("tokens.txt").path
            guard FileManager.default.fileExists(atPath: modelPath) else { return nil }
            return .senseVoice(modelPath: modelPath, tokensPath: tokensPath)
        }
    }

    // MARK: - Qwen3-ASR 路径

    private static func qwen3ASRPaths(for id: ASRModelID) -> ModelPaths? {
        let modelDir = modelDirectory(for: id)
        let convFrontend = modelDir.appendingPathComponent("conv_frontend.onnx").path
        let encoder = modelDir.appendingPathComponent("encoder.int8.onnx").path
        let decoder = modelDir.appendingPathComponent("decoder.int8.onnx").path
        let tokenizer = modelDir.appendingPathComponent("tokenizer").path

        guard validateModelFiles(for: id, in: modelDir) else { return nil }

        return .qwen3ASR(
            convFrontendPath: convFrontend,
            encoderPath: encoder,
            decoderPath: decoder,
            tokenizerPath: tokenizer
        )
    }
}

// MARK: - 模型文件路径

enum ModelPaths {
    case senseVoice(modelPath: String, tokensPath: String)
    case qwen3ASR(convFrontendPath: String, encoderPath: String, decoderPath: String, tokenizerPath: String)
}
