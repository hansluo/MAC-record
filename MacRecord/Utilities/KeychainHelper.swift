import Foundation
import Security

/// API Key 安全存储工具。新数据写入 macOS Keychain，并自动迁移旧版 XOR 文件。
enum KeychainHelper {
    private static let service = "com.hansluo.mac-record"

    static func save(key: String, value: String) {
        let valueData = value.data(using: .utf8)!
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData] = valueData
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            print("[Keychain] 保存失败: \(status)")
            return
        }
        deleteLegacyValue(key: key)
    }

    static func load(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }

        // 一次性迁移旧版 Application Support XOR 文件。
        if let legacy = loadLegacyValue(key: key) {
            save(key: key, value: legacy)
            return legacy
        }
        return nil
    }

    static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        SecItemDelete(query as CFDictionary)
        deleteLegacyValue(key: key)
    }

    private static var legacyStorageDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacRecord/.secrets", isDirectory: true)
    }

    private static func legacyURL(for key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        return legacyStorageDirectory.appendingPathComponent("\(safe).key")
    }

    private static let legacyXORKey: [UInt8] = [0x4D, 0x52, 0x65, 0x63, 0x6F, 0x72, 0x64]

    private static func loadLegacyValue(key: String) -> String? {
        guard let data = try? Data(contentsOf: legacyURL(for: key)) else { return nil }
        var decoded = Data(count: data.count)
        for index in 0..<data.count {
            decoded[index] = data[index] ^ legacyXORKey[index % legacyXORKey.count]
        }
        return String(data: decoded, encoding: .utf8)
    }

    private static func deleteLegacyValue(key: String) {
        try? FileManager.default.removeItem(at: legacyURL(for: key))
    }
}
