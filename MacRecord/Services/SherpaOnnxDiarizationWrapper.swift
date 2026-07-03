import Foundation

// MARK: - Speaker Diarization Result

/// 说话人分离的一个语音段
struct DiarizationSegment {
    let start: Float      // 开始时间（秒）
    let end: Float        // 结束时间（秒）
    let speaker: Int32    // 说话人编号（从 0 开始）
}

/// 说话人分离完整结果
struct DiarizationResult {
    let segments: [DiarizationSegment]
    let numSpeakers: Int32
}

// MARK: - Diarization Wrapper

/// sherpa-onnx 离线说话人分离 Swift 封装
class SherpaOnnxDiarizationWrapper {
    private let diarizer: OpaquePointer

    /// 进度回调：(已处理块数, 总块数) -> 是否继续(0=继续, 1=中止)
    typealias ProgressCallback = (Int32, Int32) -> Int32

    /// 创建说话人分离器
    /// - Parameters:
    ///   - segmentationModelPath: pyannote segmentation 模型路径
    ///   - embeddingModelPath: speaker embedding 模型路径
    ///   - numSpeakers: 已知说话人数量（0 = 自动检测）
    ///   - threshold: 聚类阈值（numSpeakers=0 时使用，默认 0.5）
    ///   - numThreads: 推理线程数
    init?(
        segmentationModelPath: String,
        embeddingModelPath: String,
        numSpeakers: Int32 = 0,
        threshold: Float = 0.5,
        numThreads: Int32 = 4
    ) {
        var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
        memset(&config, 0, MemoryLayout<SherpaOnnxOfflineSpeakerDiarizationConfig>.size)

        let ptr: OpaquePointer? = segmentationModelPath.withCString { segPath in
            embeddingModelPath.withCString { embPath in
                "cpu".withCString { provider in
                    config.segmentation.pyannote.model = segPath
                    config.segmentation.num_threads = numThreads
                    config.segmentation.debug = 0
                    config.segmentation.provider = provider

                    config.embedding.model = embPath
                    config.embedding.num_threads = numThreads
                    config.embedding.debug = 0
                    config.embedding.provider = provider

                    config.clustering.num_clusters = numSpeakers
                    config.clustering.threshold = threshold

                    config.min_duration_on = 0.3   // 最短语音段 0.3s
                    config.min_duration_off = 0.5  // 最短静音段 0.5s

                    return SherpaOnnxCreateOfflineSpeakerDiarization(&config)
                }
            }
        }

        guard let validPtr = ptr else {
            print("[Diarization] 创建失败")
            return nil
        }
        self.diarizer = validPtr
        let sr = SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(validPtr)
        print("[Diarization] 创建成功，要求采样率: \(sr)")
    }

    deinit {
        SherpaOnnxDestroyOfflineSpeakerDiarization(diarizer)
        print("[Diarization] 已销毁")
    }

    /// 获取要求的采样率
    var sampleRate: Int32 {
        SherpaOnnxOfflineSpeakerDiarizationGetSampleRate(diarizer)
    }

    /// 执行说话人分离（带进度回调）
    func process(
        samples: [Float],
        onProgress: ProgressCallback? = nil
    ) -> DiarizationResult {
        let result: OpaquePointer?

        if let progressCB = onProgress {
            // 用 context 传递闭包
            var callback = progressCB
            result = withUnsafeMutablePointer(to: &callback) { cbPtr in
                samples.withUnsafeBufferPointer { samplesPtr in
                    SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(
                        diarizer,
                        samplesPtr.baseAddress,
                        Int32(samples.count),
                        { numProcessed, numTotal, arg -> Int32 in
                            guard let arg = arg else { return 0 }
                            let cb = arg.assumingMemoryBound(
                                to: ((Int32, Int32) -> Int32).self
                            )
                            return cb.pointee(numProcessed, numTotal)
                        },
                        cbPtr
                    )
                }
            }
        } else {
            result = samples.withUnsafeBufferPointer { samplesPtr in
                SherpaOnnxOfflineSpeakerDiarizationProcess(
                    diarizer,
                    samplesPtr.baseAddress,
                    Int32(samples.count)
                )
            }
        }

        guard let validResult = result else {
            print("[Diarization] 处理返回 nil")
            return DiarizationResult(segments: [], numSpeakers: 0)
        }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(validResult) }

        let numSpeakers = SherpaOnnxOfflineSpeakerDiarizationResultGetNumSpeakers(validResult)
        let numSegments = SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(validResult)

        guard numSegments > 0,
              let cSegments = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(validResult) else {
            return DiarizationResult(segments: [], numSpeakers: numSpeakers)
        }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(cSegments) }

        var segments: [DiarizationSegment] = []
        segments.reserveCapacity(Int(numSegments))

        for i in 0..<Int(numSegments) {
            let seg = cSegments[i]
            segments.append(DiarizationSegment(
                start: seg.start,
                end: seg.end,
                speaker: seg.speaker
            ))
        }

        print("[Diarization] 完成: \(numSpeakers)个说话人, \(numSegments)个语音段")
        return DiarizationResult(segments: segments, numSpeakers: numSpeakers)
    }
}
