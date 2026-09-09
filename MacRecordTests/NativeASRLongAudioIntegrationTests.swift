import Foundation
import XCTest
@testable import MacRecord

final class NativeASRLongAudioIntegrationTests: XCTestCase {
    func testChunkedQwenTranscriptionWhenFixtureIsConfigured() async throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["MACRECORD_ASR_FIXTURE"] else {
            throw XCTSkip("未配置长音频集成测试样本")
        }
        guard ModelRegistry.isModelDownloaded(.qwen3ASR17BInt8) else {
            throw XCTSkip("未安装 Qwen3-ASR 1.7B")
        }

        let service = NativeASRService()
        _ = try await service.initialize(modelId: .qwen3ASR17BInt8)
        let collector = ProgressCollector()
        let result = try await service.transcribeFile(
            audioPath: fixturePath,
            language: "auto"
        ) { progress in
            collector.append(progress)
        }

        XCTAssertFalse(result.plainText.isEmpty)
        XCTAssertGreaterThan(result.duration ?? 0, 10)
        XCTAssertTrue(collector.values.contains { $0.phase == .recognizing })
        XCTAssertGreaterThan(collector.values.map(\.fraction).max() ?? 0, 0.5)
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [TranscriptionProgress] = []

    var values: [TranscriptionProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ progress: TranscriptionProgress) {
        lock.lock()
        storedValues.append(progress)
        lock.unlock()
    }
}
