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

    /// 存储音频文件（复制到 app 目录），返回相对路径
    func storeAudioFile(from sourceURL: URL, hash: String) -> String? {
        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let filename = "\(hash).\(ext)"
        let destURL = audioStorageDir.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: destURL.path) {
            return filename
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            return filename
        } catch {
            print("存储音频文件失败: \(error)")
            return nil
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
}
