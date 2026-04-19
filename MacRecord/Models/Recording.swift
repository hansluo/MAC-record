import Foundation
import SwiftData

/// 录音历史记录
@Model
final class Recording {
    @Attribute(.unique) var id: UUID
    var title: String
    var originalFilename: String?
    var audioPath: String?
    var fileHash: String?
    var duration: Double?
    var language: String?
    var timestampText: String?
    var plainText: String?
    var detectedLanguage: String?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \AISummary.recording)
    var summaries: [AISummary]?

    init(
        id: UUID = UUID(),
        title: String = "新录音",
        originalFilename: String? = nil,
        audioPath: String? = nil,
        fileHash: String? = nil,
        duration: Double? = nil,
        language: String? = nil,
        timestampText: String? = nil,
        plainText: String? = nil,
        detectedLanguage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.originalFilename = originalFilename
        self.audioPath = audioPath
        self.fileHash = fileHash
        self.duration = duration
        self.language = language
        self.timestampText = timestampText
        self.plainText = plainText
        self.detectedLanguage = detectedLanguage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
