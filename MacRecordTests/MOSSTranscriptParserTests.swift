import XCTest
@testable import MacRecord

final class MOSSTranscriptParserTests: XCTestCase {
    func testParsesSpeakerAttributedTimestampedTranscript() throws {
        let text = "[0.48][S01]欢迎大家[1.66][1.70][S02]项目开始[3.25]"

        let segments = MOSSTranscriptParser.parse(text)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 0.48, accuracy: 0.001)
        XCTAssertEqual(segments[0].end, 1.66, accuracy: 0.001)
        XCTAssertEqual(segments[0].speaker, "S01")
        XCTAssertEqual(segments[0].text, "欢迎大家")
        XCTAssertEqual(segments[1].speaker, "S02")
    }

    func testSkipsInvalidReverseTimestampSegment() throws {
        let segments = MOSSTranscriptParser.parse("[3.0][S01]无效[2.0][3.1][S02]有效[4.0]")

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "有效")
    }
}
