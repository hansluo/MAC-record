import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreAudio

/// 系统音频捕获器
/// 首选 ScreenCaptureKit，失败时回退到提示用户安装 BlackHole 虚拟音频
@MainActor
class SystemAudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var recentLevels: [Float] = []
    @Published var errorMessage: String?

    private var stream: SCStream?
    private var streamOutput: SystemAudioStreamOutput?
    private var timer: Timer?
    private var startTime: Date?
    private var audioFile: AVAudioFile?

    nonisolated(unsafe) var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var recordingURL: URL?

    // MARK: - 录音控制

    func startRecording() async throws {
        errorMessage = nil

        // 一次性获取 SCShareableContent（同时做权限检查 + 获取内容）
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            let errMsg = error.localizedDescription
            print("[SystemAudio] 权限检查失败: \(errMsg)")

            // 区分错误类型，提供针对性引导
            if errMsg.contains("denied") || errMsg.contains("permission") || errMsg.contains("not authorized") {
                errorMessage = "Self 记录需要「录屏与系统录音」权限。\n\n" +
                    "请按以下步骤操作：\n" +
                    "1. 打开「系统设置 → 隐私与安全性 → 录屏与系统录音」\n" +
                    "2. 找到 Mac-Record 并开启开关\n" +
                    "3. 如已开启但仍不生效，请关闭后重新开启\n" +
                    "4. 完全退出 Mac-Record 后重新打开"
            } else {
                errorMessage = "Self 记录启动失败: \(errMsg)\n\n" +
                    "请确认已在「系统设置 → 隐私与安全性 → 录屏与系统录音」中授权 Mac-Record。"
            }

            // 自动打开系统偏好设置的隐私页面
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }

            throw SystemAudioError.permissionDenied(errorMessage!)
        }

        // 权限通过，直接使用已获取的 content 启动捕获
        try await startWithScreenCaptureKit(content: content)
    }

    /// DRM 保护应用的 bundle ID 列表（这些应用会黑屏，但音频仍能录到）
    private let drmProtectedApps = [
        "com.apple.tv",          // Apple TV+
        "com.apple.Music",       // Apple Music
        "com.netflix.Netflix",   // Netflix
        "com.spotify.client",    // Spotify
        "com.disney.disneyplus", // Disney+
        "com.primevideo.app",    // Prime Video
    ]

    /// 是否检测到有 DRM 保护应用在运行（用于 UI 提示）
    @Published var hasDRMApp = false
    /// DRM 提示信息
    @Published var drmWarning: String?

    private func startWithScreenCaptureKit(content: SCShareableContent) async throws {
        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplay
        }

        // 检测是否有 DRM 保护的应用在运行，给用户提示
        let runningDRMApps = content.applications.filter { app in
            drmProtectedApps.contains(app.bundleIdentifier)
        }
        if !runningDRMApps.isEmpty {
            let names = runningDRMApps.map { $0.applicationName }.joined(separator: "、")
            await MainActor.run {
                self.hasDRMApp = true
                self.drmWarning = "检测到 \(names) 正在运行。这些应用有 DRM 版权保护，画面会黑屏，但声音仍会被正常录制。"
            }
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // 把视频帧率降到最低（每100秒才捕获一帧），尽量不触发视频通道
        config.minimumFrameInterval = CMTime(value: 100, timescale: 1)
        // 最小分辨率
        config.width = 2
        config.height = 2
        config.sampleRate = 16000
        config.channelCount = 1

        let url = AudioFileManager.shared.createTempRecordingURL()
        self.recordingURL = url

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw SystemAudioError.formatError
        }

        let outputFile = try AVAudioFile(
            forWriting: url,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.audioFile = outputFile

        let output = SystemAudioStreamOutput { [weak self] buffer in
            guard let self = self else { return }
            try? outputFile.write(from: buffer)

            if let channelData = buffer.floatChannelData?[0] {
                let count = Int(buffer.frameLength)
                var rms: Float = 0
                for i in 0..<count { rms += channelData[i] * channelData[i] }
                rms = sqrt(rms / Float(max(count, 1)))
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.recentLevels.append(rms)
                    if self.recentLevels.count > 150 {
                        self.recentLevels.removeFirst(self.recentLevels.count - 150)
                    }
                }
            }

            self.onAudioBuffer?(buffer)
        }
        self.streamOutput = output

        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await newStream.startCapture()

        self.stream = newStream
        self.isRecording = true
        self.startTime = Date()
        self.recentLevels = []

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.startTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    func stopRecording() async -> URL? {
        timer?.invalidate()
        timer = nil
        if let stream = stream { try? await stream.stopCapture() }
        stream = nil
        streamOutput = nil
        audioFile = nil
        isRecording = false
        return recordingURL
    }

    // MARK: - 休眠暂停/唤醒恢复

    /// 记录休眠前的 elapsed 以便恢复后继续计时
    private var pausedElapsedTime: TimeInterval = 0

    /// 休眠前暂停：停止 SCStream（休眠后会失效），保留 audioFile 和 recordingURL
    func pauseForSleep() async {
        timer?.invalidate()
        timer = nil
        pausedElapsedTime = elapsedTime
        if let stream = stream { try? await stream.stopCapture() }
        stream = nil
        streamOutput = nil
        print("[SystemAudio] 因休眠暂停，已停止 SCStream")
    }

    /// 唤醒后恢复：重新创建 SCStream 继续录音
    func resumeFromSleep() async {
        guard recordingURL != nil else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { return }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.minimumFrameInterval = CMTime(value: 100, timescale: 1)
            config.width = 2
            config.height = 2
            config.sampleRate = 16000
            config.channelCount = 1

            let output = SystemAudioStreamOutput { [weak self] buffer in
                guard let self = self else { return }
                try? self.audioFile?.write(from: buffer)

                if let channelData = buffer.floatChannelData?[0] {
                    let count = Int(buffer.frameLength)
                    var rms: Float = 0
                    for i in 0..<count { rms += channelData[i] * channelData[i] }
                    rms = sqrt(rms / Float(max(count, 1)))
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        self.recentLevels.append(rms)
                        if self.recentLevels.count > 150 {
                            self.recentLevels.removeFirst(self.recentLevels.count - 150)
                        }
                    }
                }

                self.onAudioBuffer?(buffer)
            }
            self.streamOutput = output

            let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
            try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await newStream.startCapture()

            self.stream = newStream
            let resumeStart = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.elapsedTime = self.pausedElapsedTime + Date().timeIntervalSince(resumeStart)
                }
            }
            print("[SystemAudio] 从休眠恢复，SCStream 已重建")
        } catch {
            print("[SystemAudio] 唤醒恢复失败: \(error)")
        }
    }
}

/// SCStream 音频输出处理
class SystemAudioStreamOutput: NSObject, SCStreamOutput {
    private let handler: (AVAudioPCMBuffer) -> Void

    init(handler: @escaping (AVAudioPCMBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let sampleRate = asbd.pointee.mSampleRate
        let channels = asbd.pointee.mChannelsPerFrame
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == noErr, let ptr = dataPointer, length > 0 else { return }

        let bytesPerSample = MemoryLayout<Float>.size
        let frameCount = length / (Int(channels) * bytesPerSample)
        guard frameCount > 0 else { return }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        if channels == 1, let dest = buffer.floatChannelData?[0] {
            ptr.withMemoryRebound(to: Float.self, capacity: frameCount) { src in
                dest.assign(from: src, count: frameCount)
            }
        } else if let dest = buffer.floatChannelData?[0] {
            ptr.withMemoryRebound(to: Float.self, capacity: frameCount * Int(channels)) { src in
                for i in 0..<frameCount {
                    var sum: Float = 0
                    for ch in 0..<Int(channels) { sum += src[i * Int(channels) + ch] }
                    dest[i] = sum / Float(channels)
                }
            }
        }

        handler(buffer)
    }
}

enum SystemAudioError: LocalizedError {
    case formatError
    case permissionDenied(String)
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .formatError: return "无法创建音频格式"
        case .permissionDenied(let msg): return msg
        case .noDisplay: return "未找到显示器"
        }
    }
}
