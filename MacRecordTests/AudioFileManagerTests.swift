import XCTest
@testable import MacRecord

final class AudioFileManagerTests: XCTestCase {
    func testImportCopiesSourceWithoutDeletingIt() throws {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let source = sourceDirectory.appendingPathComponent("meeting.wav")
        try Data("audio".utf8).write(to: source)
        let hash = UUID().uuidString

        let storedPath = try AudioFileManager.shared.importAudioFile(from: source, hash: hash)
        defer { AudioFileManager.shared.deleteAudioFile(relativePath: storedPath) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioFileManager.shared.fullPath(for: storedPath)))
    }
}
