import AVFoundation
import XCTest
@testable import MacRecord

final class AudioFileChunkReaderTests: XCTestCase {
    func testStreamingResamplePreservesExpectedDurationAcrossChunks() throws {
        let sourceRate = 48_000.0
        let duration = 3.2
        let frameCount = AVAudioFrameCount(sourceRate * duration)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceRate,
            channels: 2,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else {
            return XCTFail("无法创建测试音频缓冲区")
        }
        buffer.frameLength = frameCount
        for channelIndex in 0..<Int(format.channelCount) {
            guard let channel = buffer.floatChannelData?[channelIndex] else {
                return XCTFail("无法访问测试声道")
            }
            for frame in 0..<Int(frameCount) {
                channel[frame] = sin(2 * .pi * 440 * Float(frame) / Float(sourceRate))
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRecord-ChunkReader-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var file: AVAudioFile? = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file?.write(from: buffer)
        file = nil

        var totalOutputSamples = 0
        var callbackCount = 0
        var previousProcessedSeconds = 0.0
        try AudioFileChunkReader.read(
            url: url,
            targetSampleRate: 16_000,
            chunkDuration: 0.25
        ) { samples, processedSeconds, totalDuration in
            XCTAssertFalse(samples.isEmpty)
            XCTAssertGreaterThanOrEqual(processedSeconds, previousProcessedSeconds)
            XCTAssertEqual(totalDuration, duration, accuracy: 0.01)
            previousProcessedSeconds = processedSeconds
            totalOutputSamples += samples.count
            callbackCount += 1
        }

        XCTAssertGreaterThan(callbackCount, 2)
        XCTAssertEqual(
            totalOutputSamples,
            Int(duration * 16_000),
            accuracy: 256
        )
    }
}
