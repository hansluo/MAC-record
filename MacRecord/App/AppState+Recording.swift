import Foundation
import AVFoundation

/// AppState 录音功能扩展
extension AppState {
    var audioRecorder: AudioRecorder? { _lazyRecorder }

    private var _lazyRecorder: AudioRecorder {
        if let existing = _recorder { return existing }
        let rec = AudioRecorder()
        _recorder = rec
        return rec
    }

    func startRecordingSession() async {
        guard isModelReady, isIdle else { return }

        let sessionId = UUID()
        recordingStartTime = Date()

        let source = audioSource

        if source == .systemAudio {
            if let service = nativeASRService {
                Task.detached {
                    await service.realtimeStart(sessionId: sessionId.uuidString, language: "auto")
                }
            }

            let sysRecorder = SystemAudioRecorder()
            self.systemAudioRecorder = sysRecorder
            sysRecorder.onAudioBuffer = { [weak self] buffer in
                guard let self = self else { return }
                Task { await self.routeBufferToASR(buffer: buffer, sessionId: sessionId) }
            }

            do {
                try await sysRecorder.startRecording()
                recordingMode = .normalRecording(sessionId: sessionId, paused: false)
            } catch {
                print("[SystemAudio] 启动失败: \(error)")
                sysRecorder.errorMessage = error.localizedDescription
                systemAudioRecorder = nil
                recordingMode = .idle
                modelStatus = "❌ Self 记录启动失败: \(error.localizedDescription)"
            }

        } else {
            if let service = nativeASRService {
                Task.detached {
                    await service.realtimeStart(sessionId: sessionId.uuidString, language: "auto")
                }
            }

            guard let recorder = _lazyRecorder as AudioRecorder? else { return }
            recorder.onRawAudioBuffer = nil
            recorder.onAudioBuffer = { [weak self] buffer in
                guard let self = self else { return }
                Task { await self.routeBufferToASR(buffer: buffer, sessionId: sessionId) }
            }

            do {
                try recorder.startRecording()
                recordingMode = .normalRecording(sessionId: sessionId, paused: false)
            } catch {
                print("[Recorder] 启动失败: \(error)")
                recordingMode = .idle
            }
        }
    }

    func togglePauseRecording() async {
        if audioSource == .systemAudio {
            return
        }
        guard let recorder = audioRecorder,
              case .normalRecording(let sid, let paused) = recordingMode else { return }
        if paused {
            recorder.resumeRecording()
            recordingMode = .normalRecording(sessionId: sid, paused: false)
        } else {
            recorder.pauseRecording()
            recordingMode = .normalRecording(sessionId: sid, paused: true)
        }
    }

    func stopRecordingSession() async {
        guard case .normalRecording(let sessionId, _) = recordingMode else { return }

        let source = audioSource
        var recordingURL: URL?
        var duration: TimeInterval = 0

        if source == .systemAudio {
            if let sysRecorder = systemAudioRecorder {
                recordingURL = await sysRecorder.stopRecording()
                duration = sysRecorder.elapsedTime
                sysRecorder.onAudioBuffer = nil
            }
            systemAudioRecorder = nil
        } else {
            if let recorder = audioRecorder {
                recordingURL = recorder.stopRecording()
                duration = recorder.elapsedTime
                recorder.onAudioBuffer = nil
                recorder.onRawAudioBuffer = nil
            }
        }

        recordingMode = .idle

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        let prefix = source == .systemAudio ? "系统录音" : "录音"
        let autoTitle = "\(prefix) \(formatter.string(from: recordingStartTime ?? Date()))"

        let sid = sessionId.uuidString

        NotificationCenter.default.post(
            name: .recordingCompleted,
            object: nil,
            userInfo: [
                "sessionId": sessionId,
                "title": autoTitle,
                "plainText": "",
                "timestampText": "",
                "detectedLanguage": "",
                "duration": duration,
                "recordingURL": recordingURL as Any,
            ]
        )

        // 后台 finalize
        let service = nativeASRService
        Task.detached {
            guard let service = service else { return }
            do {
                let result = try await service.realtimeStop(sessionId: sid)
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .recordingTextReady,
                        object: nil,
                        userInfo: [
                            "sessionId": sessionId,
                            "plainText": result.plainText,
                            "timestampText": "",
                            "detectedLanguage": result.detectedLanguage ?? "",
                        ]
                    )
                }
            } catch {
                print("[NativeASR] finalize 失败: \(error)")
            }
        }
    }

    private func routeBufferToASR(buffer: AVAudioPCMBuffer, sessionId: UUID) async {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)

        if let service = nativeASRService {
            let samples = Array(UnsafeBufferPointer(start: channelData, count: count))
            _ = await service.realtimeFeed(sessionId: sessionId.uuidString, samples: samples)
        }
    }
}

extension Notification.Name {
    static let recordingCompleted = Notification.Name("recordingCompleted")
    static let recordingTextReady = Notification.Name("recordingTextReady")
}
