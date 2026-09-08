import Foundation
import AVFoundation

extension AppState {
    var audioRecorder: AudioRecorder? { _lazyRecorder }

    private var _lazyRecorder: AudioRecorder {
        if let existing = _recorder { return existing }
        let recorder = AudioRecorder()
        _recorder = recorder
        return recorder
    }

    func startRecordingSession() async {
        guard canStartRecording else { return }

        let sessionId = UUID()
        stopRequestedWhileStarting = false
        recordingMode = .starting(sessionId: sessionId)
        let source = audioSource
        let capabilities = selectedASRModel.capabilities
        var pump: RealtimeAudioPump?

        do {
            if capabilities.supportsRealtime {
                guard let service = nativeASRService else { throw NativeASRError.notReady }
                try await service.realtimeStart(sessionId: sessionId.uuidString, language: "auto")
                pump = RealtimeAudioPump(service: service, sessionId: sessionId.uuidString)
                realtimeAudioPump = pump
            }

            if source == .systemAudio {
                let recorder = SystemAudioRecorder()
                systemAudioRecorder = recorder
                recorder.onAudioBuffer = { buffer in
                    guard let channelData = buffer.floatChannelData?[0], let pump else { return }
                    pump.enqueue(Array(UnsafeBufferPointer(
                        start: channelData,
                        count: Int(buffer.frameLength)
                    )))
                }
                try await recorder.startRecording()
            } else {
                let recorder = _lazyRecorder
                recorder.onRawAudioBuffer = nil
                recorder.onAudioBuffer = { buffer in
                    guard let channelData = buffer.floatChannelData?[0], let pump else { return }
                    pump.enqueue(Array(UnsafeBufferPointer(
                        start: channelData,
                        count: Int(buffer.frameLength)
                    )))
                }
                try recorder.startRecording()
            }

            recordingStartTime = Date()
            recordingMode = .normalRecording(sessionId: sessionId, paused: false)
            transcriptionStatus = capabilities.supportsRealtime
                ? "正在实时转录"
                : "录音结束后使用当前引擎转录"
            if stopRequestedWhileStarting {
                stopRequestedWhileStarting = false
                await stopRecordingSession()
            }
        } catch {
            if let pump { await pump.finish() }
            realtimeAudioPump = nil
            if capabilities.supportsRealtime, let service = nativeASRService {
                await service.realtimeCancel(sessionId: sessionId.uuidString)
            }
            systemAudioRecorder = nil
            recordingMode = .idle
            transcriptionStatus = nil
            modelStatus = "❌ 录音启动失败: \(error.localizedDescription)"
        }
    }

    func togglePauseRecording() async {
        guard audioSource == .microphone,
              let recorder = audioRecorder,
              case .normalRecording(let sessionId, let paused) = recordingMode else { return }
        if paused {
            recorder.resumeRecording()
            recordingMode = .normalRecording(sessionId: sessionId, paused: false)
        } else {
            recorder.pauseRecording()
            recordingMode = .normalRecording(sessionId: sessionId, paused: true)
        }
    }

    func stopRecordingSession() async {
        if case .starting = recordingMode {
            stopRequestedWhileStarting = true
            return
        }
        guard case .normalRecording(let sessionId, _) = recordingMode else { return }
        recordingMode = .stopping(sessionId: sessionId)

        let source = audioSource
        let selectedModelId = asrConfigStore.selectedModelId
        var recordingURL: URL?
        var duration: TimeInterval = 0

        if source == .systemAudio {
            if let recorder = systemAudioRecorder {
                recorder.onAudioBuffer = nil
                recordingURL = await recorder.stopRecording()
                duration = recorder.elapsedTime
            }
            systemAudioRecorder = nil
        } else if let recorder = audioRecorder {
            recorder.onAudioBuffer = nil
            recorder.onRawAudioBuffer = nil
            recordingURL = recorder.stopRecording()
            duration = recorder.elapsedTime
        }

        if let pump = realtimeAudioPump {
            await pump.finish()
            if pump.droppedBufferCount > 0 {
                print("[ASR] 有界队列丢弃了 \(pump.droppedBufferCount) 个过期 buffer")
            }
        }
        realtimeAudioPump = nil

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        let prefix = source == .systemAudio ? "系统录音" : "录音"
        let title = "\(prefix) \(formatter.string(from: recordingStartTime ?? Date()))"

        var persistedRecordingId: UUID?
        do {
            let recordingId = try persistenceCoordinator.createRecordedSession(
                sessionId: sessionId,
                title: title,
                duration: duration,
                recordingURL: recordingURL,
                engineId: selectedModelId
            )
            persistedRecordingId = recordingId
            selectedRecordingId = recordingId
            let supportsRealtime = ModelRegistry.model(for: selectedModelId).capabilities.supportsRealtime
            if supportsRealtime {
                transcriptionStatus = "正在完成转录"
                defer {
                    recordingMode = .idle
                    transcriptionStatus = nil
                }
                guard let service = nativeASRService else { throw NativeASRError.notReady }
                let nativeResult = try await service.realtimeStop(sessionId: sessionId.uuidString)
                let result = UnifiedTranscriptionResult(
                    text: nativeResult.plainText,
                    language: nativeResult.detectedLanguage,
                    segments: [],
                    engineId: selectedModelId.rawValue,
                    modelVersion: nil,
                    duration: nativeResult.duration,
                    elapsed: nil,
                    diagnostics: nativeResult.emotion
                )
                try persistenceCoordinator.apply(result, to: recordingId)
            } else {
                recordingMode = .idle
                transcriptionStatus = "转录队列处理中"
                let generation = beginTranscription(for: recordingId)
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer {
                        self.finishTranscription(generation, for: recordingId)
                        self.unregisterTranscriptionTask(
                            generation: generation,
                            recordingId: recordingId
                        )
                    }
                    do {
                        let audioURL = try self.persistenceCoordinator.audioURL(for: recordingId)
                        let result = try await self.transcriptionQueue.enqueue {
                            try await self.transcribeFile(at: audioURL)
                        }
                        guard self.isCurrentTranscription(generation, for: recordingId) else { return }
                        try self.persistenceCoordinator.apply(result, to: recordingId)
                    } catch {
                        guard self.isCurrentTranscription(generation, for: recordingId) else { return }
                        self.persistenceCoordinator.markFailed(error, recordingId: recordingId)
                        self.modelStatus = "❌ 转录失败: \(error.localizedDescription)"
                    }
                }
                registerTranscriptionTask(
                    task,
                    generation: generation,
                    recordingId: recordingId
                )
            }
        } catch {
            if let persistedRecordingId {
                persistenceCoordinator.markFailed(error, recordingId: persistedRecordingId)
            }
            recordingMode = .idle
            transcriptionStatus = nil
            modelStatus = "❌ 保存或完成录音失败: \(error.localizedDescription)"
            if selectedASRModel.capabilities.supportsRealtime, let service = nativeASRService {
                await service.realtimeCancel(sessionId: sessionId.uuidString)
            }
        }
    }
}
