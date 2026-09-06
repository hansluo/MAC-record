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

    static let moss = ASRCapabilities(
        supportsRealtime: false,
        supportsFileTranscription: true,
        supportsSpeakerLabels: true,
        supportsTimestamps: true,
        supportsHotwords: true
    )
}

struct TranscriptionSegment: Codable, Equatable, Identifiable {
    var id: String { "\(start)-\(end)-\(speaker ?? "")-\(text)" }
    let start: Double
    let end: Double
    let speaker: String?
    let text: String
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
        hotwords: [String]
    ) async throws -> UnifiedTranscriptionResult
    func cancel() async
}

struct MOSSTranscriptParser {
    static func parse(_ text: String) -> [TranscriptionSegment] {
        let pattern = #"\[([0-9]+(?:\.[0-9]*)?|\.[0-9]+)\]\s*\[(S[0-9]+)\](.*?)\[([0-9]+(?:\.[0-9]*)?|\.[0-9]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges == 5,
                  let startRange = Range(match.range(at: 1), in: text),
                  let speakerRange = Range(match.range(at: 2), in: text),
                  let contentRange = Range(match.range(at: 3), in: text),
                  let endRange = Range(match.range(at: 4), in: text),
                  let start = Double(text[startRange]),
                  let end = Double(text[endRange]),
                  end >= start else { return nil }

            let content = text[contentRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            return TranscriptionSegment(
                start: start,
                end: end,
                speaker: String(text[speakerRange]),
                text: content
            )
        }
    }
}
