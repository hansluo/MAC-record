import Combine
import SwiftData
import XCTest
@testable import MacRecord

final class ModelDownloadObservationTests: XCTestCase {
    @MainActor
    func testRefreshDoesNotRepublishUnchangedDownloadedModels() async {
        let manager = ModelDownloadManager()
        var publishCount = 0
        let cancellable = manager.$downloadedModelIds.dropFirst().sink { _ in publishCount += 1 }

        manager.refreshDownloadedModels()
        manager.refreshDownloadedModels()
        await Task.yield()

        XCTAssertEqual(publishCount, 0)
        cancellable.cancel()
    }

    @MainActor
    func testRegisteredTranscriptionTracksRecordingAndBlocksNewRecording() async throws {
        let schema = Schema([Recording.self, AISummary.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let appState = AppState(modelContainer: container)
        appState.isModelReady = true
        let recordingId = UUID()
        let generation = appState.beginTranscription(for: recordingId)
        let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }

        appState.registerTranscriptionTask(task, generation: generation, recordingId: recordingId)
        XCTAssertTrue(appState.isTranscribing(recordingId: recordingId))
        XCTAssertTrue(appState.hasActiveTranscriptions)
        XCTAssertFalse(appState.canStartRecording)
        XCTAssertTrue(appState.canTranscribeFile)

        appState.cancelTranscription(recordingId: recordingId)
        XCTAssertTrue(appState.isTranscribing(recordingId: recordingId))
        XCTAssertTrue(appState.hasActiveTranscriptions)
        XCTAssertEqual(
            appState.transcriptionProgress(for: recordingId)?.phase,
            .cancelling
        )

        appState.finishTranscription(generation, for: recordingId)
        appState.unregisterTranscriptionTask(
            generation: generation,
            recordingId: recordingId
        )
        XCTAssertFalse(appState.isTranscribing(recordingId: recordingId))
        XCTAssertFalse(appState.hasActiveTranscriptions)
        XCTAssertNil(appState.transcriptionStatus)
    }

    @MainActor
    func testNestedDownloadStateInvalidatesAppState() async throws {
        let schema = Schema([Recording.self, AISummary.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let appState = AppState(modelContainer: container)
        try await Task.sleep(for: .milliseconds(50))
        let expectation = expectation(description: "AppState forwards model download state")
        var cancellable: AnyCancellable?

        cancellable = appState.objectWillChange.sink {
            expectation.fulfill()
        }

        appState.modelDownloadManager.downloads[.qwen3ASR06BInt8] = .downloading(progress: 0.1)
        await fulfillment(of: [expectation], timeout: 1)
        cancellable?.cancel()
    }
}
