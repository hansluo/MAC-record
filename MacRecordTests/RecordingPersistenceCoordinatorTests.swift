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
}
