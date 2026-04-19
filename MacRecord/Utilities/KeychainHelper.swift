import Foundation

/// API Key 安全存储工具
/// 使用 Application Support 目录下的加密文件存储，避免 Keychain 弹窗
enum KeychainHelper {
    private static let storageDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MacRecord/.secrets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 设置目录权限为仅当前用户可读写
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }()

    static func save(key: String, value: String) {
        let fileURL = storageDir.appendingPathComponent(safeFileName(key))
        guard let data = value.data(using: .utf8) else { return }
        // 简单 XOR 混淆（非加密级别，但避免明文）
        let obfuscated = obfuscate(data)
        try? obfuscated.write(to: fileURL)
        // 设置文件权限为仅当前用户可读写
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func load(key: String) -> String? {
        let fileURL = storageDir.appendingPathComponent(safeFileName(key))
        guard let obfuscated = try? Data(contentsOf: fileURL) else { return nil }
        let data = deobfuscate(obfuscated)
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let fileURL = storageDir.appendingPathComponent(safeFileName(key))
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Private

    private static func safeFileName(_ key: String) -> String {
        // 将 key 转为安全的文件名
        let safe = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        return "\(safe).key"
    }

    /// 简单 XOR 混淆（防止直接 cat 看到明文）
    private static let xorKey: [UInt8] = [0x4D, 0x52, 0x65, 0x63, 0x6F, 0x72, 0x64] // "MRecord"

    private static func obfuscate(_ data: Data) -> Data {
        var result = Data(count: data.count)
        for i in 0..<data.count {
            result[i] = data[i] ^ xorKey[i % xorKey.count]
        }
        return result
    }

    private static func deobfuscate(_ data: Data) -> Data {
        return obfuscate(data) // XOR 是自反的
    }
}
