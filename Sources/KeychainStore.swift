import Foundation
import Security

enum KeychainStore {
    static let sharedKeyKey = "zen_api_key"
    static let service = "com.steve233.opencodego.apikey"
    static let account = "ZEN_API_KEY"

    static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego") }
    static func save(_ key: String) {
        sharedDefaults?.set(key, forKey: sharedKeyKey)
        // 浏览器登录拿到的新 Key 也要写回代理 env；否则 resolvedKey 的 env 优先会继续用旧 Key。
        updateRelayEnv(key)
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // upsert：SecItemAdd 在已有条目时返回 errSecDuplicateItem，旧实现静默失败，
        // Keychain 里仍然是上一把 Key。先删再加，保证“填新值保存=替换”。
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            // 钥匙串被锁/权限变化时保留 App Group 副本，下次 resolvedKey 仍能读到。
            sharedDefaults?.synchronize()
        }
    }

    /// 只替换/追加 `ZEN_API_KEY`，保留 env 里其它开关；文件不存在时创建。
    private static func updateRelayEnv(_ key: String) {
        guard !key.isEmpty else { return }
        let path = NSString(string: "~/.config/agent-relay/env").expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var replaced = false
        for i in lines.indices where lines[i].hasPrefix("ZEN_API_KEY=") {
            lines[i] = "ZEN_API_KEY=\(key)"
            replaced = true
        }
        if !replaced { lines.append("ZEN_API_KEY=\(key)") }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
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
            NSString(string: "~/.config/agent-relay/env").expandingTildeInPath,
            NSString(string: "~/.local/share/opencode/auth.json").expandingTildeInPath,
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
            if path.contains("auth.json"), let data = content.data(using: .utf8),
               let key = parseAuthJSON(data) {
                return key
            }
        }
        return nil
    }

    /// 新版 OpenCode 的形状是 {"opencode-go":{"type":"api","key":"..."}}。
    /// 保留旧的扁平字段兜底，方便读取早期副本或手工文件。
    static func parseAuthJSON(_ data: Data) -> String? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for provider in ["opencode-go", "zen"] {
            if let p = j[provider] as? [String: Any],
               let v = p["key"] as? String, !v.isEmpty {
                return v
            }
        }
        for k in ["zen_api_key", "apiKey", "api_key", "ZEN_API_KEY"] {
            if let v = j[k] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    static func resolvedKey() -> String? {
        // 2026-09-20：env 文件排在钥匙串**前面**。每次本地重新打包（ad-hoc 重签）都会让钥匙串
        // 里那条 apikey 的 ACL 失效 → macOS 弹授权框；用户没注意时读取会一直阻塞，
        // 表现就是"App 卡死/点了刷新没反应/窗口都画不出来"（实测两个实例都卡在 SecItemCopyMatching）。
        // 一键配置一定会写 env 文件，所以正常路径根本不需要碰钥匙串。
        let group = sharedDefaults?.string(forKey: sharedKeyKey)
        let env = loadFromEnvFile()
        // 2026-10-20：env 是安装器刚写入的“当前 Key”，App Group 只是缓存。
        // 以前 App Group 永远优先，env 换了新 Key 仍会被旧缓存盖住；现在 env 优先并回填缓存。
        // 缓存里的临时值只在 env 缺失时使用（例如刚卸载安装器/正在首次登录）。
        if let env, !env.isEmpty {
            if group != env { sharedDefaults?.set(env, forKey: sharedKeyKey) }
            return env
        }
        if let group, !group.isEmpty { return group }
        return load()
    }
}
