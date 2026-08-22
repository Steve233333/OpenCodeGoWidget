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
        return load() ?? loadFromEnvFile()
    }
}
