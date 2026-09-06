import Foundation

struct NativeASRBackend: FileASRBackend {
    let modelId: ASRModelID
    let service: NativeASRService

    var capabilities: ASRCapabilities { .native }

    func transcribeFile(
        at url: URL,
        hotwords: [String] = []
    ) async throws -> UnifiedTranscriptionResult {
        let result = try await service.transcribeFile(audioPath: url.path, language: "auto")
        return UnifiedTranscriptionResult(
            text: result.plainText,
            language: result.detectedLanguage,
            segments: [],
            engineId: modelId.rawValue,
            modelVersion: nil,
            duration: result.duration,
            elapsed: nil,
            diagnostics: result.emotion
        )
    }

    func cancel() async {}
}
