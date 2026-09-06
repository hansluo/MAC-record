import XCTest
@testable import MacRecord

final class ASRModelRegistryTests: XCTestCase {
    func testMOSSCapabilitiesAreFileOnlyAndStructured() throws {
        let info = ModelRegistry.model(for: .mossTranscribeDiarize09B)

        XCTAssertFalse(info.capabilities.supportsRealtime)
        XCTAssertTrue(info.capabilities.supportsFileTranscription)
        XCTAssertTrue(info.capabilities.supportsSpeakerLabels)
        XCTAssertTrue(info.capabilities.supportsTimestamps)
    }
}
