import Foundation
import Security

struct IOSStoredSession: Codable, Equatable {
    var consoleSession: String
    var authCookie: String?
    var workspaceID: String
    var savedAt: Date
}

enum IOSSessionStore {
    private static let service = "com.steve233.opencodego.ios.console"
    private static let account = "console-session"
    private static let defaults = UserDefaults(suiteName: PlatformConfig.appGroupID)

    static func load() -> IOSStoredSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = try? JSONDecoder().decode(IOSStoredSession.self, from: data),
              !value.consoleSession.isEmpty else {
            return nil
        }
        return value
    }

    static func save(_ session: IOSStoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "无法把登录凭据写入 iOS Keychain"]
            )
        }
        applyToAppGroup(session)
    }

    static func applyToAppGroup(_ session: IOSStoredSession) {
        let oldWorkspace = defaults?.string(forKey: "workspaceID") ?? ""
        defaults?.set(session.workspaceID, forKey: "workspaceID")
        // App 自己仍只读 Keychain。小组件扩展没法读 App 的 Keychain，
        // 所以这里镜像一份到 App Group，仅用于小组件自己刷新额度。
        // App Group 只有主 App 和它的小组件能读。
        defaults?.set(session.consoleSession, forKey: "widgetConsoleSession")
        if let authCookie = session.authCookie, !authCookie.isEmpty {
            defaults?.set(authCookie, forKey: "widgetAuthCookie")
        } else {
            defaults?.removeObject(forKey: "widgetAuthCookie")
        }
        // 清理旧版本写过的非命名空间副本。
        defaults?.removeObject(forKey: "consoleSession")
        defaults?.removeObject(forKey: "authCookie")
        let oldState = KeyDirectoryStore.load(defaults: defaults)
        let currentFingerprint = KeyDirectoryStore.currentFingerprint(defaults: defaults)
        let changed = oldWorkspace != session.workspaceID
            || oldState == nil
            || oldState?.sessionFingerprint != currentFingerprint
            || oldState?.status == .loginRequired
        if changed {
            KeyDirectoryStore.clearRejectedSession(defaults: defaults)
            KeyDirectoryStore.invalidate(
                reason: "iOS 账号已登录，等待验证 Key",
                defaults: defaults
            )
        }
        defaults?.synchronize()
    }

    static func clearCredentials() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        for key in [
            "consoleSession", "authCookie", "widgetConsoleSession", "widgetAuthCookie",
            "workspaceID", "availableKeys",
            KeyDirectoryStore.rejectedSessionFingerprintKey, "selectedCostKeyId",
        ] {
            defaults?.removeObject(forKey: key)
        }
        KeyDirectoryStore.save(
            KeyDirectoryState(
                status: .loginRequired,
                keys: [],
                checkedAt: Date(),
                sessionFingerprint: KeyDirectoryStore.currentFingerprint(defaults: defaults),
                detail: "请重新登录 OpenCode"
            ),
            defaults: defaults
        )
        if var snapshot = WidgetDataStore.load() {
            snapshot.availableKeys = []
            snapshot.error = "登录已失效，请打开 App 重新登录"
            _ = WidgetDataStore.save(snapshot)
        }
        defaults?.synchronize()
    }

    static func clearAllLocalData() {
        clearCredentials()
        _ = WidgetDataStore.wipeUsageCache()
        for key in [
            "go_model_ids", "go_model_ids_date", "zen_model_ids", "zen_model_ids_date",
            "go_quotas_json_v3", "go_quotas_date_v3", "cachedAccountID",
        ] {
            defaults?.removeObject(forKey: key)
        }
        defaults?.synchronize()
    }

    static func hasCredentials() -> Bool {
        guard let session = load() else { return false }
        applyToAppGroup(session)
        return true
    }

    static func verifyAppGroupRoundTrip() -> Bool {
        let key = "ios_app_group_probe"
        let value = UUID().uuidString
        defaults?.set(value, forKey: key)
        defaults?.synchronize()
        let readBack = defaults?.string(forKey: key)
        defaults?.removeObject(forKey: key)
        return readBack == value
    }
}
