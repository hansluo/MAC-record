import XCTest
@testable import MacRecord

final class LLMSecurityTests: XCTestCase {
    func testAllowsHTTPSAndLoopbackHTTP() throws {
        XCTAssertNoThrow(try LLMService.validatedAPIURL("https://api.example.com/v1/chat/completions"))
        XCTAssertNoThrow(try LLMService.validatedAPIURL("http://localhost:11434/v1/chat/completions"))
        XCTAssertNoThrow(try LLMService.validatedAPIURL("http://127.0.0.1:1234/v1/chat/completions"))
    }

    func testRejectsRemotePlainHTTP() {
        XCTAssertThrowsError(try LLMService.validatedAPIURL("http://api.example.com/v1/chat/completions"))
    }
}
