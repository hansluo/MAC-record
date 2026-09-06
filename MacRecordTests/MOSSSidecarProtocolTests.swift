import XCTest
@testable import MacRecord

final class MOSSSidecarProtocolTests: XCTestCase {
    func testBundledSidecarReturnsVersionedJSONForUnknownCommand() throws {
        guard let script = MOSSRuntimeEnvironment.sidecarScriptURL else {
            return XCTFail("Missing bundled MOSS sidecar")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        input.fileHandleForWriting.write(Data("{\"protocolVersion\":1,\"requestId\":\"test\",\"command\":\"unknown\"}\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["protocolVersion"] as? Int, 1)
        XCTAssertEqual(object["type"] as? String, "error")
        XCTAssertEqual(object["requestId"] as? String, "test")
    }
}
