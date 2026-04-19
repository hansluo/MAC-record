import Foundation
import SwiftData

/// AI 纪要
@Model
final class AISummary {
    @Attribute(.unique) var id: UUID
    var prompt: String
    var summary: String
    var modelName: String?
    var createdAt: Date

    var recording: Recording?

    init(
        id: UUID = UUID(),
        prompt: String = "",
        summary: String = "",
        modelName: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.prompt = prompt
        self.summary = summary
        self.modelName = modelName
        self.createdAt = createdAt
    }
}
