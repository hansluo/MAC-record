import Foundation

struct ASRCapabilities: Equatable {
    let supportsRealtime: Bool
    let supportsFileTranscription: Bool
    let supportsSpeakerLabels: Bool
    let supportsTimestamps: Bool
    let supportsHotwords: Bool

    static let native = ASRCapabilities(
        supportsRealtime: true,
        supportsFileTranscription: true,
        supportsSpeakerLabels: false,
        supportsTimestamps: false,
        supportsHotwords: false
    )

}

struct TranscriptionSegment: Codable, Equatable, Identifiable {
    var id: String { "\(start)-\(end)-\(speaker ?? "")-\(text)" }
    let start: Double
    let end: Double
    let speaker: String?
    let text: String
}

struct TranscriptionProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case queued
        case reading
        case recognizing
        case saving
        case cancelling
    }

    let phase: Phase
    let fraction: Double
    let message: String
    let completedSegments: Int
}

struct UnifiedTranscriptionResult: Codable, Equatable {
    let text: String
    let language: String?
    let segments: [TranscriptionSegment]
    let engineId: String
    let modelVersion: String?
    let duration: Double?
    let elapsed: Double?
    let diagnostics: String?

    var speakerCount: Int {
        Set(segments.compactMap(\.speaker)).count
    }

    var speakerText: String? {
        guard segments.contains(where: { $0.speaker != nil }) else { return nil }
        return segments.map { segment in
            let rawLabel = segment.speaker ?? "S00"
            let number = rawLabel.drop(while: { !$0.isNumber })
            let label = number.isEmpty ? rawLabel : "说话人\(Int(number) ?? 0)"
            return "\(label): \(segment.text)"
        }.joined(separator: "\n")
    }

    var segmentsJSON: String? {
        guard !segments.isEmpty,
              let data = try? JSONEncoder().encode(segments) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

protocol FileASRBackend: Sendable {
    var modelId: ASRModelID { get }
    var capabilities: ASRCapabilities { get }
    func transcribeFile(
        at url: URL,
        hotwords: [String],
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> UnifiedTranscriptionResult
    func cancel() async
}
