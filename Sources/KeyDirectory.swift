import Foundation
import CryptoKit

/// 控制台 Key 目录的可用性状态。
///
/// 2026-10-22：不能再把“请求失败”和“官网真的没有 Key”都表示成空数组。
/// 否则 401 会静默回落旧缓存，已吊销的 Key 会一直留在下拉框里。
enum KeyDirectoryStatus: String, Codable, Equatable {
    case live
    case loginRequired
    case noActiveKeys
    case temporaryFailure
}

struct KeyDirectoryState: Codable, Equatable {
    let status: KeyDirectoryStatus
    let keys: [ApiKeyInfo]
    let checkedAt: Date
    /// workspace + auth + consoleSession 的 SHA256；不保存任何原始凭据。
    let sessionFingerprint: String
    let detail: String?

    /// temporaryFailure 只有在上一轮 live 列表与当前会话一致时才会带 Key。
    var usableKeys: [ApiKeyInfo] {
        switch status {
        case .live, .temporaryFailure:
            return keys
        case .loginRequired, .noActiveKeys:
            return []
        }
    }
}

enum KeyDirectoryFetchOutcome {
    case fetched(ConsoleKeyList)
    case loginRequired(String)
    case temporaryFailure(String)
}

enum KeyDirectoryReducer {
    static func reduce(_ outcome: KeyDirectoryFetchOutcome,
                       previous: KeyDirectoryState?,
                       sessionFingerprint: String,
                       now: Date = Date()) -> KeyDirectoryState {
        switch outcome {
        case .fetched(let list):
            if list.keys.isEmpty {
                return KeyDirectoryState(
                    status: .noActiveKeys,
                    keys: [],
                    checkedAt: now,
                    sessionFingerprint: sessionFingerprint,
                    detail: "官网当前没有有效 Key"
                )
            }
            return KeyDirectoryState(
                status: .live,
                keys: list.keys,
                checkedAt: now,
                sessionFingerprint: sessionFingerprint,
                detail: list.skipped > 0 ? "已跳过 \(list.skipped) 把吊销或过期 Key" : nil
            )

        case .loginRequired(let detail):
            return KeyDirectoryState(
                status: .loginRequired,
                keys: [],
                checkedAt: now,
                sessionFingerprint: sessionFingerprint,
                detail: detail
            )

        case .temporaryFailure(let detail):
            let canReuse = previous.map {
                $0.sessionFingerprint == sessionFingerprint
                    && !$0.keys.isEmpty
                    && ($0.status == .live || $0.status == .temporaryFailure)
            } ?? false
            return KeyDirectoryState(
                status: .temporaryFailure,
                keys: canReuse ? previous?.keys ?? [] : [],
                checkedAt: now,
                sessionFingerprint: sessionFingerprint,
                detail: detail
            )
        }
    }
}

enum KeyDirectoryStore {
    static let suiteName = "2DC432GLL2.com.steve233.opencodego"
    static let stateKey = "keyDirectoryStateV2"
    static let rejectedSessionFingerprintKey = "rejectedSessionFingerprint"
    static let cacheSchemaKey = "keyDirectoryCacheSchemaVersion"
    static let cacheSchemaVersion = "2"

    static func fingerprint(workspaceID: String, auth: String, session: String) -> String {
        let material = "\(workspaceID)|\(auth)|\(session)"
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func currentFingerprint(defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) -> String {
        fingerprint(
            workspaceID: defaults?.string(forKey: "workspaceID") ?? "",
            auth: defaults?.string(forKey: "authCookie") ?? "",
            session: defaults?.string(forKey: "consoleSession") ?? ""
        )
    }

    static func load(defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) -> KeyDirectoryState? {
        guard let data = defaults?.data(forKey: stateKey) else { return nil }
        return try? JSONDecoder().decode(KeyDirectoryState.self, from: data)
    }

    static func save(_ state: KeyDirectoryState,
                     defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) {
        guard let defaults, let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
        // 旧版原始缓存不再参与下拉框；留着一个同名键只会再次绕过状态机。
        defaults.removeObject(forKey: "availableKeys")
        if state.usableKeys.isEmpty {
            defaults.removeObject(forKey: "selectedCostKeyId")
        }
        defaults.synchronize()
    }

    static func invalidate(reason: String,
                           defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) {
        let state = KeyDirectoryState(
            status: .temporaryFailure,
            keys: [],
            checkedAt: Date(),
            sessionFingerprint: currentFingerprint(defaults: defaults),
            detail: reason
        )
        save(state, defaults: defaults)
    }

    static func rejectSession(_ fingerprint: String,
                              defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) {
        guard !fingerprint.isEmpty else { return }
        defaults?.set(fingerprint, forKey: rejectedSessionFingerprintKey)
        defaults?.synchronize()
    }

    static func clearRejectedSession(defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) {
        defaults?.removeObject(forKey: rejectedSessionFingerprintKey)
        defaults?.synchronize()
    }

    static func isRejectedSession(_ fingerprint: String,
                                  defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) -> Bool {
        guard !fingerprint.isEmpty else { return false }
        return defaults?.string(forKey: rejectedSessionFingerprintKey) == fingerprint
    }

    static func selectedKeyIsAvailable(_ keyID: String?, in state: KeyDirectoryState?) -> Bool {
        guard let keyID, !keyID.isEmpty else { return true }
        return state?.usableKeys.contains { $0.id == keyID } == true
    }
}
