import XCTest
import SwiftData
@testable import MacRecord

@MainActor
final class RecordingPersistenceCoordinatorTests: XCTestCase {
    func testAppliesStructuredResultWithoutViewLifecycle() throws {
        let schema = Schema([Recording.self, AISummary.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let coordinator = RecordingPersistenceCoordinator(modelContainer: container)
        let id = UUID()

        _ = try coordinator.createRecordedSession(
            sessionId: id,
            title: "测试录音",
            duration: 3,
            recordingURL: nil,
            engineId: .senseVoiceInt8
        )
        let result = UnifiedTranscriptionResult(
            text: "你好",
            language: "zh",
            segments: [.init(start: 0, end: 1, speaker: "S01", text: "你好")],
            engineId: ASRModelID.senseVoiceInt8.rawValue,
            modelVersion: "test",
            duration: 1,
            elapsed: 0.1,
            diagnostics: nil
        )
        try coordinator.apply(result, to: id)

        let recordings = try container.mainContext.fetch(FetchDescriptor<Recording>())
        XCTAssertEqual(recordings.first?.plainText, "你好")
        XCTAssertEqual(recordings.first?.transcriptionStatus, "completed")
        XCTAssertEqual(recordings.first?.diarizedSpeakerCount, 1)
        XCTAssertNotNil(recordings.first?.structuredSegmentsJSON)
    }

    func testMarksOnlyProcessingTasksAsInterruptedAfterLaunch() throws {
        let schema = Schema([Recording.self, AISummary.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let coordinator = RecordingPersistenceCoordinator(modelContainer: container)
        let processingId = UUID()
        let completedId = UUID()

        _ = try coordinator.createRecordedSession(
            sessionId: processingId,
            title: "处理中",
            duration: 1,
            recordingURL: nil,
            engineId: .qwen3ASR17BInt8
        )
        _ = try coordinator.createRecordedSession(
            sessionId: completedId,
            title: "已完成",
            duration: 1,
            recordingURL: nil,
            engineId: .senseVoiceInt8
        )
        try coordinator.apply(
            UnifiedTranscriptionResult(
                text: "完成",
                language: "zh",
                segments: [],
                engineId: ASRModelID.senseVoiceInt8.rawValue,
                modelVersion: nil,
                duration: 1,
                elapsed: nil,
                diagnostics: nil
            ),
            to: completedId
        )

        coordinator.markInterruptedTasksAfterLaunch()
        let recordings = try container.mainContext.fetch(FetchDescriptor<Recording>())
        let processing = recordings.first { $0.id == processingId }
        let completed = recordings.first { $0.id == completedId }
        XCTAssertEqual(processing?.transcriptionStatus, "failed")
        XCTAssertEqual(processing?.transcriptionError, "上次转录因应用退出而中断，可重新转录")
        XCTAssertEqual(completed?.transcriptionStatus, "completed")
        XCTAssertNil(completed?.transcriptionError)
    }
}
