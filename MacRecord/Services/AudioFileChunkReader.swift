import AVFoundation
import Foundation

enum AudioFileChunkReader {
    static func read(
        url: URL,
        targetSampleRate: Int32 = 16_000,
        chunkDuration: TimeInterval = 10,
        onChunk: (_ samples: [Float], _ processedSeconds: Double, _ totalDuration: Double) throws -> Void
    ) throws {
        let audioFile = try AVAudioFile(forReading: url)
        let sourceFormat = audioFile.processingFormat
        guard audioFile.length > 0, sourceFormat.sampleRate > 0 else {
            throw AudioFileChunkReaderError.emptyAudio
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw AudioFileChunkReaderError.unsupportedFormat
        }

        let totalDuration = Double(audioFile.length) / sourceFormat.sampleRate
        let sourceFramesPerChunk = AVAudioFrameCount(max(
            1,
            Int(chunkDuration * sourceFormat.sampleRate)
        ))
        let canCopyDirectly = Int32(sourceFormat.sampleRate) == targetSampleRate
            && sourceFormat.channelCount == 1
            && sourceFormat.commonFormat == .pcmFormatFloat32
            && !sourceFormat.isInterleaved
        let converter = canCopyDirectly ? nil : AVAudioConverter(from: sourceFormat, to: targetFormat)
        if !canCopyDirectly, converter == nil {
            throw AudioFileChunkReaderError.unsupportedFormat
        }

        func emitOutput(_ buffer: AVAudioPCMBuffer, processedSeconds: Double) throws {
            guard buffer.frameLength > 0 else { return }
            guard let channel = buffer.floatChannelData?[0] else {
                throw AudioFileChunkReaderError.unsupportedFormat
            }
            let samples = Array(UnsafeBufferPointer(
                start: channel,
                count: Int(buffer.frameLength)
            ))
            try Task.checkCancellation()
            try onChunk(samples, processedSeconds, totalDuration)
        }

        func convertInput(_ inputBuffer: AVAudioPCMBuffer, processedSeconds: Double) throws {
            guard let converter else {
                throw AudioFileChunkReaderError.unsupportedFormat
            }
            let ratio = Double(targetSampleRate) / sourceFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(max(
                4_096,
                Int(ceil(Double(inputBuffer.frameLength) * ratio)) + 4_096
            ))
            var providedInput = false
            var iteration = 0

            while true {
                try Task.checkCancellation()
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: outputCapacity
                ) else {
                    throw AudioFileChunkReaderError.bufferAllocationFailed
                }
                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                    if providedInput {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    providedInput = true
                    inputStatus.pointee = .haveData
                    return inputBuffer
                }
                guard status != .error, conversionError == nil else {
                    throw AudioFileChunkReaderError.conversionFailed(
                        conversionError?.localizedDescription ?? "未知转换错误"
                    )
                }
                try emitOutput(outputBuffer, processedSeconds: processedSeconds)
                if status == .inputRanDry || status == .endOfStream { break }
                iteration += 1
                guard iteration < 16 else {
                    throw AudioFileChunkReaderError.conversionFailed("转换器未完成当前音频块")
                }
            }
        }

        while audioFile.framePosition < audioFile.length {
            try Task.checkCancellation()
            let remaining = audioFile.length - audioFile.framePosition
            let requestedFrames = AVAudioFrameCount(min(Int64(sourceFramesPerChunk), remaining))
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: requestedFrames
            ) else {
                throw AudioFileChunkReaderError.bufferAllocationFailed
            }
            try audioFile.read(into: inputBuffer, frameCount: requestedFrames)
            guard inputBuffer.frameLength > 0 else { break }
            let processedSeconds = min(
                Double(audioFile.framePosition) / sourceFormat.sampleRate,
                totalDuration
            )

            if canCopyDirectly {
                try emitOutput(inputBuffer, processedSeconds: processedSeconds)
            } else {
                try convertInput(inputBuffer, processedSeconds: processedSeconds)
            }
        }

        if let converter {
            var iteration = 0
            while true {
                try Task.checkCancellation()
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: 4_096
                ) else {
                    throw AudioFileChunkReaderError.bufferAllocationFailed
                }
                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard status != .error, conversionError == nil else {
                    throw AudioFileChunkReaderError.conversionFailed(
                        conversionError?.localizedDescription ?? "未知转换错误"
                    )
                }
                try emitOutput(outputBuffer, processedSeconds: totalDuration)
                if status == .endOfStream { break }
                iteration += 1
                guard iteration < 16 else {
                    throw AudioFileChunkReaderError.conversionFailed("无法排空转换器尾部音频")
                }
            }
        }
    }
}

enum AudioFileChunkReaderError: LocalizedError {
    case emptyAudio
    case unsupportedFormat
    case bufferAllocationFailed
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyAudio: return "音频文件为空"
        case .unsupportedFormat: return "不支持该音频格式"
        case .bufferAllocationFailed: return "无法分配音频转换缓冲区"
        case .conversionFailed(let message): return "音频转换失败: \(message)"
        }
    }
}
