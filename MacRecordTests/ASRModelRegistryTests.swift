import XCTest
@testable import MacRecord

final class ASRModelRegistryTests: XCTestCase {
    func testRegisteredModelIDsAreUnique() {
        let ids = ModelRegistry.allModels.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testRegistryCoversEveryModelID() {
        XCTAssertEqual(
            Set(ModelRegistry.allModels.map(\.id)),
            Set(ASRModelID.allCases)
        )
    }

    func testQwen17ModelUsesPinnedVerifiedFiles() {
        let model = ModelRegistry.model(for: .qwen3ASR17BInt8)
        XCTAssertEqual(model.family, .qwen3ASR)
        XCTAssertEqual(model.downloadFiles.count, 6)
        XCTAssertEqual(
            model.downloadFiles.reduce(Int64(0)) { $0 + $1.expectedSize },
            model.downloadSizeBytes
        )
        XCTAssertTrue(model.downloadFiles.allSatisfy { $0.downloadURL.hasPrefix("https://") })
        XCTAssertTrue(model.downloadFiles.allSatisfy { $0.sha256.count == 64 })
    }

    func testNativeModelsSupportRealtimeAndFileTranscription() {
        for modelId in ASRModelID.allCases {
            let info = ModelRegistry.model(for: modelId)
            XCTAssertTrue(info.capabilities.supportsFileTranscription)
            XCTAssertTrue(info.capabilities.supportsRealtime)
        }
    }
}
