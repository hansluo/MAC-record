import Foundation

// MARK: - Offline Recognizer Config

/// 通用离线识别器配置，支持 SenseVoice 和 Qwen3-ASR
enum SherpaOnnxModelConfig {
    case senseVoice(SenseVoiceConfig)
    case qwen3ASR(Qwen3ASRConfig)

    struct SenseVoiceConfig {
        var modelPath: String
        var tokensPath: String
        var language: String = "auto"
        var useITN: Bool = true
    }

    struct Qwen3ASRConfig {
        var convFrontendPath: String
        var encoderPath: String
        var decoderPath: String
        var tokenizerPath: String
    }
}

/// 通用识别器配置参数
struct SherpaOnnxRecognizerConfig {
    var modelConfig: SherpaOnnxModelConfig
    var numThreads: Int32 = 4
    var sampleRate: Int32 = 16000
    var featureDim: Int32 = 80
    var decodingMethod: String = "greedy_search"
    var provider: String = "cpu"
    var debug: Int32 = 0
}

// MARK: - Offline Recognizer

/// sherpa-onnx 离线语音识别器的 Swift 封装（支持多模型族）
class SherpaOnnxOfflineRecognizerWrapper {
    private let recognizer: OpaquePointer

    /// 使用统一配置创建（推荐）
    init?(config: SherpaOnnxRecognizerConfig) {
        var cConfig = SherpaOnnxOfflineRecognizerConfig()
        memset(&cConfig, 0, MemoryLayout<SherpaOnnxOfflineRecognizerConfig>.size)

        cConfig.feat_config.sample_rate = config.sampleRate
        cConfig.feat_config.feature_dim = config.featureDim

        let ptr: OpaquePointer?

        switch config.modelConfig {
        case .senseVoice(let sv):
            ptr = Self.createSenseVoice(
                cConfig: &cConfig, svConfig: sv, config: config
            )
        case .qwen3ASR(let qwen):
            ptr = Self.createQwen3ASR(
                cConfig: &cConfig, qwenConfig: qwen, config: config
            )
        }

        guard let validPtr = ptr else {
            print("[SherpaOnnx] 创建 OfflineRecognizer 失败")
            return nil
        }
        self.recognizer = validPtr
        print("[SherpaOnnx] OfflineRecognizer 创建成功")
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
        print("[SherpaOnnx] OfflineRecognizer 已销毁")
    }

    // MARK: - 创建方法

    private static func createSenseVoice(
        cConfig: inout SherpaOnnxOfflineRecognizerConfig,
        svConfig: SherpaOnnxModelConfig.SenseVoiceConfig,
        config: SherpaOnnxRecognizerConfig
    ) -> OpaquePointer? {
        svConfig.modelPath.withCString { modelPath in
            svConfig.tokensPath.withCString { tokensPath in
                svConfig.language.withCString { language in
                    config.decodingMethod.withCString { decodingMethod in
                        config.provider.withCString { provider in
                            cConfig.model_config.sense_voice.model = modelPath
                            cConfig.model_config.sense_voice.language = language
                            cConfig.model_config.sense_voice.use_itn = svConfig.useITN ? 1 : 0
                            cConfig.model_config.tokens = tokensPath
                            cConfig.model_config.num_threads = config.numThreads
                            cConfig.model_config.debug = config.debug
                            cConfig.model_config.provider = provider
                            cConfig.decoding_method = decodingMethod
                            return SherpaOnnxCreateOfflineRecognizer(&cConfig)
                        }
                    }
                }
            }
        }
    }

    private static func createQwen3ASR(
        cConfig: inout SherpaOnnxOfflineRecognizerConfig,
        qwenConfig: SherpaOnnxModelConfig.Qwen3ASRConfig,
        config: SherpaOnnxRecognizerConfig
    ) -> OpaquePointer? {
        qwenConfig.convFrontendPath.withCString { convFrontend in
            qwenConfig.encoderPath.withCString { encoder in
                qwenConfig.decoderPath.withCString { decoder in
                    qwenConfig.tokenizerPath.withCString { tokenizer in
                        config.decodingMethod.withCString { decodingMethod in
                            config.provider.withCString { provider in
                                cConfig.model_config.qwen3_asr.conv_frontend = convFrontend
                                cConfig.model_config.qwen3_asr.encoder = encoder
                                cConfig.model_config.qwen3_asr.decoder = decoder
                                cConfig.model_config.qwen3_asr.tokenizer = tokenizer
                                cConfig.model_config.qwen3_asr.max_total_len = 4096
                                cConfig.model_config.qwen3_asr.max_new_tokens = 1024
                                cConfig.model_config.qwen3_asr.temperature = 0.0
                                cConfig.model_config.qwen3_asr.top_p = 1.0
                                cConfig.model_config.qwen3_asr.seed = 0
                                cConfig.model_config.num_threads = config.numThreads
                                cConfig.model_config.debug = config.debug
                                cConfig.model_config.provider = provider
                                cConfig.decoding_method = decodingMethod
                                return SherpaOnnxCreateOfflineRecognizer(&cConfig)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 识别

    /// 识别 PCM float 数组（整段离线识别）
    func recognize(samples: [Float], sampleRate: Int32 = 16000) -> SherpaOnnxRecognitionResult {
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            return SherpaOnnxRecognitionResult(text: "", lang: nil, emotion: nil, event: nil)
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(
                stream,
                sampleRate,
                buffer.baseAddress,
                Int32(samples.count)
            )
        }

        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let jsonCStr = SherpaOnnxGetOfflineStreamResultAsJson(stream) else {
            return SherpaOnnxRecognitionResult(text: "", lang: nil, emotion: nil, event: nil)
        }
        defer { SherpaOnnxDestroyOfflineStreamResultJson(jsonCStr) }

        let jsonStr = String(cString: jsonCStr)
        return parseResultJSON(jsonStr)
    }

    /// 从 WAV 文件识别
    func recognizeFile(path: String) -> SherpaOnnxRecognitionResult {
        guard let wave = path.withCString({ SherpaOnnxReadWave($0) }) else {
            print("[SherpaOnnx] 无法读取音频文件: \(path)")
            return SherpaOnnxRecognitionResult(text: "", lang: nil, emotion: nil, event: nil)
        }
        defer { SherpaOnnxFreeWave(wave) }

        let sampleRate = wave.pointee.sample_rate
        let numSamples = Int(wave.pointee.num_samples)
        let samples = Array(UnsafeBufferPointer(start: wave.pointee.samples, count: numSamples))

        return recognize(samples: samples, sampleRate: sampleRate)
    }

    // MARK: - JSON 解析

    private func parseResultJSON(_ json: String) -> SherpaOnnxRecognitionResult {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SherpaOnnxRecognitionResult(text: "", lang: nil, emotion: nil, event: nil)
        }

        let text = dict["text"] as? String ?? ""
        let lang = dict["lang"] as? String
        let emotion = dict["emotion"] as? String
        let event = dict["event"] as? String

        return SherpaOnnxRecognitionResult(
            text: text,
            lang: (lang?.isEmpty ?? true) ? nil : lang,
            emotion: (emotion?.isEmpty ?? true) ? nil : emotion,
            event: (event?.isEmpty ?? true) ? nil : event
        )
    }
}

// MARK: - Recognition Result

struct SherpaOnnxRecognitionResult {
    let text: String
    let lang: String?
    let emotion: String?
    let event: String?
}
