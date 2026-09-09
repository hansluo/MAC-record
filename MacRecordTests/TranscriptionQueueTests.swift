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

    func testCancelsQueuedOperationWithoutWaitingForRunningOperation() async throws {
        let queue = TranscriptionQueue()
        let first = Task {
            try await queue.enqueue {
                try await Task.sleep(for: .seconds(1))
                return "first"
            }
        }
        try await Task.sleep(for: .milliseconds(30))

        let started = ContinuousClock.now
        let second = Task {
            try await queue.enqueue {
                XCTFail("已取消的排队任务不应执行")
                return "second"
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        second.cancel()

        do {
            _ = try await second.value
            XCTFail("排队任务应抛出取消错误")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(300))
        first.cancel()
        _ = try? await first.value
    }
}
