import XCTest
@testable import MacRecord

final class ProcessRunnerTests: XCTestCase {
    func testDrainsLargeStderrWithoutDeadlock() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import sys; sys.stderr.write('x' * 200000)"],
            timeout: 10,
            outputLimit: 4096
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardError.count, 4096)
    }

    @MainActor
    func testProcessWaitDoesNotBlockMainActor() async throws {
        var heartbeatObserved = false
        let heartbeat = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            heartbeatObserved = true
        }

        _ = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-c", "import time; time.sleep(0.2)"],
            timeout: 5
        )
        XCTAssertTrue(heartbeatObserved, "子进程等待期间 MainActor 应已处理 heartbeat")
        await heartbeat.value
    }
}
