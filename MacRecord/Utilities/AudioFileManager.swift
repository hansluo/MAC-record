import Foundation

/// 音频文件管理器
class AudioFileManager {
    static let shared = AudioFileManager()

    let audioStorageDir: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        audioStorageDir = appSupport.appendingPathComponent("MacRecord/audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioStorageDir, withIntermediateDirectories: true)
    }

    /// 存储音频文件（移动到 app 目录），返回相对路径
    /// 优先使用 moveItem（避免临时文件残留），失败则 fallback 到 copyItem
    func storeAudioFile(from sourceURL: URL, hash: String) -> String? {
        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let filename = "\(hash).\(ext)"
        let destURL = audioStorageDir.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: destURL.path) {
            // 目标已存在，清理源文件
            try? FileManager.default.removeItem(at: sourceURL)
            return filename
        }

        do {
            // 优先 move（原子操作，避免临时文件残留）
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
            return filename
        } catch {
            // move 可能失败（跨卷等），fallback 到 copy + 删源
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                try? FileManager.default.removeItem(at: sourceURL)
                return filename
            } catch {
                print("存储音频文件失败: \(error)")
                return nil
            }
        }
    }

    /// 获取完整路径
    func fullPath(for relativePath: String) -> String {
        return audioStorageDir.appendingPathComponent(relativePath).path
    }

    /// 获取完整 URL
    func fullURL(for relativePath: String) -> URL {
        return audioStorageDir.appendingPathComponent(relativePath)
    }

    /// 删除音频文件
    func deleteAudioFile(relativePath: String) {
        let url = audioStorageDir.appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    /// 创建临时录音文件 URL
    func createTempRecordingURL() -> URL {
        let filename = "recording_\(UUID().uuidString).wav"
        return audioStorageDir.appendingPathComponent(filename)
    }

    /// 清理孤立的临时录音文件（recording_* 前缀且不被任何持久化记录引用）
    func cleanupOrphanedTempFiles(keepHashes: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: audioStorageDir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return }

        var cleanedCount = 0
        var cleanedSize: Int64 = 0

        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("recording_") else { continue }

            // 安全检查：不要删除仍可能在写入中的文件（最近 60 秒内修改的）
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let modDate = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(modDate) < 60 {
                continue
            }

            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: file)
            cleanedCount += 1
            cleanedSize += Int64(size)
        }

        if cleanedCount > 0 {
            let mb = Double(cleanedSize) / 1_048_576.0
            print("[AudioFileManager] 清理了 \(cleanedCount) 个孤立临时文件，释放 \(String(format: "%.1f", mb)) MB")
        }
    }
}
