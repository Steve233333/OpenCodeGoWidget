import Foundation
import Security

enum KeychainStore {
    static let sharedKeyKey = "zen_api_key"
    static let service = "com.steve233.opencodego.apikey"
    static let account = "ZEN_API_KEY"

    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego") }
    static func save(_ key: String) {
        sharedDefaults?.set(key, forKey: sharedKeyKey)
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    /// 删除已存 Key（Keychain + App Group 共享存储），幂等
    @discardableResult
    static func delete() -> Bool {
        sharedDefaults?.removeObject(forKey: sharedKeyKey)
        sharedDefaults?.synchronize()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8),
              !s.isEmpty else { return nil }
        return s
    }

    // Fallback: read from env file written by codex-oneclick installer
    static func loadFromEnvFile() -> String? {
        let candidates = [
            NSString(string: "~/.config/agent-vision-toolkit/env").expandingTildeInPath,
            NSString(string: "~/.config/opencode/auth.json").expandingTildeInPath
        ]
        for path in candidates {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("ZEN_API_KEY=") {
                    let v = String(t.dropFirst("ZEN_API_KEY=".count)).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !v.isEmpty { return v }
                }
            }
            // opencode auth.json is JSON with keys
            if path.contains("auth.json"), let data = content.data(using: .utf8) {
                if let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // try common shapes
                    for k in ["zen_api_key", "apiKey", "api_key", "ZEN_API_KEY"] {
                        if let v = j[k] as? String, !v.isEmpty { return v }
                    }
                }
            }
        }
        return nil
    }

    static func resolvedKey() -> String? {
        if let k = sharedDefaults?.string(forKey: sharedKeyKey), !k.isEmpty { return k }
        // 2026-09-20：env 文件排在钥匙串**前面**。每次本地重新打包（ad-hoc 重签）都会让钥匙串
        // 里那条 apikey 的 ACL 失效 → macOS 弹授权框；用户没注意时读取会一直阻塞，
        // 表现就是"App 卡死/点了刷新没反应/窗口都画不出来"（实测两个实例都卡在 SecItemCopyMatching）。
        // 一键配置一定会写 env 文件，所以正常路径根本不需要碰钥匙串。
        if let k = loadFromEnvFile(), !k.isEmpty { return k }
        return load()
    }
}
