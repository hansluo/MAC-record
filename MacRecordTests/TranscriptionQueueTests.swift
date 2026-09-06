import XCTest
@testable import MacRecord

final class TranscriptionQueueTests: XCTestCase {
    actor Recorder {
        var events: [String] = []
        func append(_ event: String) { events.append(event) }
    }

    func testSerializesOperations() async throws {
        let queue = TranscriptionQueue()
        let recorder = Recorder()

        async let first: String = queue.enqueue {
            await recorder.append("first-start")
            try await Task.sleep(for: .milliseconds(50))
            await recorder.append("first-end")
            return "first"
        }
        try await Task.sleep(for: .milliseconds(5))
        async let second: String = queue.enqueue {
            await recorder.append("second-start")
            await recorder.append("second-end")
            return "second"
        }

        _ = try await (first, second)
        let events = await recorder.events
        XCTAssertEqual(events, ["first-start", "first-end", "second-start", "second-end"])
    }
}
