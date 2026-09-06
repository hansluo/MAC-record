import XCTest
@testable import MacRecord

final class BundleResourceTests: XCTestCase {
    func testRequiredRuntimeResourcesAreBundled() {
        let resources = Bundle.main.resourceURL
        XCTAssertNotNil(resources)
        guard let resources else { return }

        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("model.int8.onnx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("tokens.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("silero_vad.onnx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("model.onnx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resources.appendingPathComponent("3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx").path))
        XCTAssertNotNil(MOSSRuntimeEnvironment.sidecarScriptURL)
    }
}
