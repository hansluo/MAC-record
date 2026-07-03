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

    var id: String { rawValue }
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
    let isBuiltin: Bool            // 是否内置在 App Bundle 中
    let downloadURL: String?       // 下载地址（内置模型为 nil）
    let archiveName: String?       // 压缩包名（用于解压）
}

// MARK: - 模型注册表

struct ModelRegistry {
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
            isBuiltin: false,
            downloadURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2025-03-25.tar.bz2",
            archiveName: "sherpa-onnx-qwen3-asr-0.6B-int8-2025-03-25"
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
        if info.isBuiltin { return true }

        let modelDir = modelDirectory(for: id)
        switch info.family {
        case .senseVoice:
            return FileManager.default.fileExists(
                atPath: modelDir.appendingPathComponent("model.onnx").path
            )
        case .qwen3ASR:
            return FileManager.default.fileExists(
                atPath: modelDir.appendingPathComponent("decoder.int8.onnx").path
            )
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

        guard FileManager.default.fileExists(atPath: decoder) else { return nil }

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
