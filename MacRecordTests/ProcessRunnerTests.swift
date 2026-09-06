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
}
