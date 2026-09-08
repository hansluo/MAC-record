import Foundation
import SwiftData

@MainActor
final class RecordingPersistenceCoordinator {
    private let modelContext: ModelContext

    init(modelContainer: ModelContainer) {
        modelContext = modelContainer.mainContext
    }

    func markInterruptedTasksAfterLaunch() {
        let descriptor = FetchDescriptor<Recording>(predicate: #Predicate {
            $0.transcriptionStatus == "processing"
        })
        guard let recordings = try? modelContext.fetch(descriptor), !recordings.isEmpty else { return }
        for recording in recordings {
            recording.transcriptionStatus = "failed"
            recording.transcriptionError = "上次转录因应用退出而中断，可重新转录"
            recording.updatedAt = Date()
        }
        try? modelContext.save()
    }

    func createRecordedSession(
        sessionId: UUID,
        title: String,
        duration: TimeInterval,
        recordingURL: URL?,
        engineId: ASRModelID
    ) throws -> UUID {
        let recording = Recording(
            id: sessionId,
            title: title,
            fileHash: sessionId.uuidString,
            duration: duration,
            createdAt: Date(),
            updatedAt: Date()
        )
        recording.asrModelId = engineId.rawValue
        recording.transcriptionStatus = "processing"
        if let recordingURL {
            guard let relativePath = AudioFileManager.shared.storeAudioFile(
                from: recordingURL,
                hash: sessionId.uuidString
            ) else {
                throw RecordingPersistenceError.audioStorageFailed
            }
            recording.audioPath = relativePath
        }
        modelContext.insert(recording)
        try modelContext.save()
        return recording.id
    }

    func importAudio(sourceURL: URL, title: String, engineId: ASRModelID) throws -> UUID {
        let id = UUID()
        let storedPath = try AudioFileManager.shared.importAudioFile(from: sourceURL, hash: id.uuidString)
        let recording = Recording(
            id: id,
            title: title,
            originalFilename: sourceURL.lastPathComponent,
            audioPath: storedPath,
            fileHash: id.uuidString,
            createdAt: Date(),
            updatedAt: Date()
        )
        recording.asrModelId = engineId.rawValue
        recording.transcriptionStatus = "processing"
        modelContext.insert(recording)
        do {
            try modelContext.save()
            return id
        } catch {
            AudioFileManager.shared.deleteAudioFile(relativePath: storedPath)
            modelContext.delete(recording)
            throw error
        }
    }

    func audioURL(for recordingId: UUID) throws -> URL {
        guard let recording = try recording(for: recordingId), let path = recording.audioPath else {
            throw RecordingPersistenceError.recordingNotFound
        }
        return AudioFileManager.shared.fullURL(for: path)
    }

    func markProcessing(recordingId: UUID, engineId: ASRModelID) {
        guard let recording = try? recording(for: recordingId) else { return }
        recording.asrModelId = engineId.rawValue
        recording.transcriptionStatus = "processing"
        recording.transcriptionError = nil
        recording.updatedAt = Date()
        try? modelContext.save()
    }

    func apply(_ result: UnifiedTranscriptionResult, to recordingId: UUID) throws {
        guard let recording = try recording(for: recordingId) else {
            throw RecordingPersistenceError.recordingNotFound
        }
        recording.plainText = result.text
        recording.detectedLanguage = result.language
        recording.structuredSegmentsJSON = result.segmentsJSON
        recording.asrModelId = result.engineId
        recording.transcriptionStatus = "completed"
        recording.transcriptionError = nil
        recording.updatedAt = Date()
        if let speakerText = result.speakerText {
            recording.diarizedText = speakerText
            recording.diarizedSpeakerCount = result.speakerCount
        } else {
            recording.diarizedText = nil
            recording.diarizedSpeakerCount = nil
        }
        try modelContext.save()
    }

    func markFailed(_ error: Error, recordingId: UUID) {
        guard let recording = try? recording(for: recordingId) else { return }
        recording.transcriptionStatus = "failed"
        recording.transcriptionError = error.localizedDescription
        recording.updatedAt = Date()
        try? modelContext.save()
    }

    func markCancelled(recordingId: UUID) {
        guard let recording = try? recording(for: recordingId) else { return }
        recording.transcriptionStatus = "failed"
        recording.transcriptionError = "转录已取消，可重新转录"
        recording.updatedAt = Date()
        try? modelContext.save()
    }

    private func recording(for id: UUID) throws -> Recording? {
        var descriptor = FetchDescriptor<Recording>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

enum RecordingPersistenceError: LocalizedError {
    case audioStorageFailed
    case recordingNotFound

    var errorDescription: String? {
        switch self {
        case .audioStorageFailed: return "无法保存录音文件"
        case .recordingNotFound: return "找不到录音记录或音频文件"
        }
    }
}
