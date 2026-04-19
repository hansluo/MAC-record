import Foundation
import AppKit

/// 导出管理器
class ExportManager {
    static let shared = ExportManager()

    func export(recording: Recording) {
        let panel = NSSavePanel()
        panel.title = "导出录音"
        panel.nameFieldStringValue = recording.title

        // 提供格式选择
        let accessory = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 30), pullsDown: false)
        accessory.addItems(withTitles: ["ASR 文本 (.txt)", "AI 纪要 (.txt)", "音频文件", "全部 (.zip)"])
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let selectedIndex = accessory.indexOfSelectedItem

        switch selectedIndex {
        case 0: exportASRText(recording: recording, to: url)
        case 1: exportSummary(recording: recording, to: url)
        case 2: exportAudio(recording: recording, to: url)
        case 3: exportAll(recording: recording, to: url)
        default: break
        }
    }

    private func exportASRText(recording: Recording, to url: URL) {
        let text = recording.plainText ?? ""
        let finalURL = url.pathExtension.isEmpty ? url.appendingPathExtension("txt") : url
        try? text.write(to: finalURL, atomically: true, encoding: .utf8)
    }

    private func exportSummary(recording: Recording, to url: URL) {
        let text = recording.summaries?.sorted(by: { $0.createdAt > $1.createdAt }).first?.summary ?? ""
        let finalURL = url.pathExtension.isEmpty ? url.appendingPathExtension("txt") : url
        try? text.write(to: finalURL, atomically: true, encoding: .utf8)
    }

    private func exportAudio(recording: Recording, to url: URL) {
        guard let audioPath = recording.audioPath else { return }
        let fullPath = AudioFileManager.shared.fullPath(for: audioPath)
        let srcURL = URL(fileURLWithPath: fullPath)
        try? FileManager.default.copyItem(at: srcURL, to: url)
    }

    private func exportAll(recording: Recording, to url: URL) {
        // 创建临时目录打包
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // ASR 文本
        let asrText = recording.plainText ?? ""
        try? asrText.write(to: tempDir.appendingPathComponent("asr.txt"), atomically: true, encoding: .utf8)

        // AI 纪要
        if let summary = recording.summaries?.sorted(by: { $0.createdAt > $1.createdAt }).first {
            try? summary.summary.write(to: tempDir.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        }

        // 音频
        if let audioPath = recording.audioPath {
            let src = URL(fileURLWithPath: AudioFileManager.shared.fullPath(for: audioPath))
            let ext = src.pathExtension
            try? FileManager.default.copyItem(at: src, to: tempDir.appendingPathComponent("audio.\(ext)"))
        }

        // 打包 ZIP
        let zipURL = url.pathExtension == "zip" ? url : url.appendingPathExtension("zip")
        let coordinator = NSFileCoordinator()
        var error: NSError?
        coordinator.coordinate(readingItemAt: tempDir, options: .forUploading, error: &error) { zipTempURL in
            try? FileManager.default.moveItem(at: zipTempURL, to: zipURL)
        }

        // 清理
        try? FileManager.default.removeItem(at: tempDir)
    }
}
