import Foundation

/// Silero VAD（语音活动检测）的 Swift 封装
/// 用于检测音频中的语音片段，配合 SenseVoice 实现流式识别
class SherpaOnnxVADWrapper {
    private let vad: OpaquePointer  // const SherpaOnnxVoiceActivityDetector*
    let sampleRate: Int32 = 16000
    let windowSize: Int32 = 512

    init?(modelPath: String, minSilenceDuration: Float = 0.3, maxSpeechDuration: Float = 10.0, bufferSizeInSeconds: Float = 60.0) {
        var config = SherpaOnnxVadModelConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxVadModelConfig>.size)

        let ptr: OpaquePointer? = modelPath.withCString { path in
            "cpu".withCString { provider in
                config.silero_vad.model = path
                config.silero_vad.threshold = 0.5
                config.silero_vad.min_silence_duration = minSilenceDuration
                config.silero_vad.min_speech_duration = 0.25
                config.silero_vad.max_speech_duration = maxSpeechDuration
                config.silero_vad.window_size = 512
                config.sample_rate = 16000
                config.num_threads = 1
                config.provider = provider
                config.debug = 0

                return SherpaOnnxCreateVoiceActivityDetector(&config, bufferSizeInSeconds)
            }
        }

        guard let validPtr = ptr else {
            print("[VAD] 创建 VoiceActivityDetector 失败")
            return nil
        }
        self.vad = validPtr
        print("[VAD] Silero VAD 创建成功")
    }

    deinit {
        SherpaOnnxDestroyVoiceActivityDetector(vad)
    }

    /// 喂入音频数据（必须是 512 样本的窗口）
    func acceptWaveform(samples: UnsafePointer<Float>, count: Int32) {
        SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, samples, count)
    }

    /// 是否有完成的语音片段
    var hasSegment: Bool {
        SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0
    }

    /// 当前是否在语音中
    var isSpeechDetected: Bool {
        SherpaOnnxVoiceActivityDetectorDetected(vad) != 0
    }

    /// 取出最前面的语音片段
    func popFrontSegment() -> (samples: [Float], startIndex: Int32)? {
        guard hasSegment else { return nil }
        guard let seg = SherpaOnnxVoiceActivityDetectorFront(vad) else { return nil }
        defer {
            SherpaOnnxDestroySpeechSegment(seg)
            SherpaOnnxVoiceActivityDetectorPop(vad)
        }

        let start = seg.pointee.start
        let n = Int(seg.pointee.n)
        guard n > 0, let ptr = seg.pointee.samples else { return nil }
        let samples = Array(UnsafeBufferPointer(start: ptr, count: n))
        return (samples, start)
    }

    /// 刷新尾部缓冲（录音结束时调用）
    func flush() {
        SherpaOnnxVoiceActivityDetectorFlush(vad)
    }

    /// 重置
    func reset() {
        SherpaOnnxVoiceActivityDetectorReset(vad)
    }
}
