import Foundation

// MARK: - Offline Recognizer Config

/// SenseVoice 离线识别器的 Swift 配置
struct SherpaOnnxOfflineRecognizerSwiftConfig {
    var senseVoiceModelPath: String = ""
    var tokensPath: String = ""
    var language: String = "auto"
    var useITN: Bool = true
    var numThreads: Int32 = 2
    var sampleRate: Int32 = 16000
    var featureDim: Int32 = 80
    var decodingMethod: String = "greedy_search"
    var provider: String = "cpu"
    var debug: Int32 = 0
}

// MARK: - Offline Recognizer

/// sherpa-onnx 离线语音识别器的 Swift 封装
/// 使用 OpaquePointer 来处理 C API 中的不透明类型
class SherpaOnnxOfflineRecognizerWrapper {
    private let recognizer: OpaquePointer  // const SherpaOnnxOfflineRecognizer*

    init?(config: SherpaOnnxOfflineRecognizerSwiftConfig) {
        var cConfig = SherpaOnnxOfflineRecognizerConfig()
        memset(&cConfig, 0, MemoryLayout<SherpaOnnxOfflineRecognizerConfig>.size)

        cConfig.feat_config.sample_rate = config.sampleRate
        cConfig.feat_config.feature_dim = config.featureDim

        // 使用嵌套 withCString 确保字符串生命周期
        let ptr: OpaquePointer? = config.senseVoiceModelPath.withCString { modelPath in
            config.tokensPath.withCString { tokensPath in
                config.language.withCString { language in
                    config.decodingMethod.withCString { decodingMethod in
                        config.provider.withCString { provider in
                            cConfig.model_config.sense_voice.model = modelPath
                            cConfig.model_config.sense_voice.language = language
                            cConfig.model_config.sense_voice.use_itn = config.useITN ? 1 : 0
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

        // 使用 JSON 方式获取结果（更可靠）
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
