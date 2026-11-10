import Foundation
import Combine
import WidgetKit

@MainActor
final class ConsoleAccountModel: ObservableObject {
    enum Phase: Equatable {
        case checking
        case loggedOut
        case loggingIn
        case loggedIn
        case expired
        case error(String)
    }

    @Published private(set) var phase: Phase = .checking
    @Published private(set) var workspaceID: String = ""
    @Published private(set) var session: IOSStoredSession?
    @Published private(set) var message: String?

    var isLoggedIn: Bool {
        if case .loggedIn = phase { return true }
        return false
    }

    func bootstrap() async {
        guard let stored = IOSSessionStore.load() else {
            phase = .loggedOut
            return
        }
        IOSSessionStore.applyToAppGroup(stored)
        session = stored
        workspaceID = stored.workspaceID
        phase = .checking
        await validate(stored, allowOfflineFallback: true)
    }

    func receiveLogin(sessionValue: String, authCookie: String?, workspaceHint: String?) async {
        guard !sessionValue.isEmpty else { return }
        phase = .loggingIn
        let stored = IOSStoredSession(
            consoleSession: sessionValue,
            authCookie: authCookie?.isEmpty == true ? nil : authCookie,
            workspaceID: workspaceHint ?? workspaceID,
            savedAt: Date()
        )
        session = stored
        do {
            try IOSSessionStore.save(stored)
            WidgetCenter.shared.reloadAllTimelines()
            await validate(stored, allowOfflineFallback: false)
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func markExpired(_ detail: String = "控制台登录可能已失效，请重试或重新登录") {
        // 不在这里删 Keychain：单次 401 可能只是网络/WAF 抖动。
        // 保留会话，用户重试或下次启动还能自愈；真正过期时重新登录会覆盖它。
        session = nil
        workspaceID = ""
        message = detail
        phase = .expired
        WidgetCenter.shared.reloadAllTimelines()
    }

    func signOut() {
        IOSSessionStore.clearCredentials()
        session = nil
        workspaceID = ""
        message = nil
        phase = .loggedOut
        WidgetCenter.shared.reloadAllTimelines()
    }

    func clearAllLocalData() {
        IOSSessionStore.clearAllLocalData()
        session = nil
        workspaceID = ""
        message = "本地用量数据和登录信息已清除"
        phase = .loggedOut
    }

#if DEBUG
    /// 仅 Debug 构建：模拟器截图时的账号外壳，不写 Keychain。
    func loadDemoAccount() {
        let demo = IOSStoredSession(
            consoleSession: "demo",
            authCookie: nil,
            workspaceID: "wrk_demo_9f3c2a",
            savedAt: Date()
        )
        session = demo
        workspaceID = demo.workspaceID
        message = nil
        phase = .loggedIn
    }
#endif

    /// 组织接口 401/403 不等于会话失效（可能是地区/WAF/权限）。
    /// 用用量接口复核：它 401 才真的掉登录，其他失败保留旧会话。
    private func recoverOrExpire(_ stored: IOSStoredSession, code: Int) async {
        guard !stored.workspaceID.isEmpty else {
            markExpired()
            return
        }
        do {
            _ = try await NetworkManager().fetchUsage()
            workspaceID = stored.workspaceID
            message = "工作区校验暂时失败（HTTP \(code)），仍使用上次会话"
            phase = .loggedIn
        } catch NetworkError.authExpired {
            markExpired()
        } catch {
            workspaceID = stored.workspaceID
            message = "当前无法验证登录，显示上次同步数据"
            phase = .loggedIn
        }
    }

    private func validate(_ stored: IOSStoredSession, allowOfflineFallback: Bool) async {
        do {
            let ids = try await OpenCodeKeyFetcher.fetchWorkspaceIDs(
                authCookie: stored.authCookie ?? "",
                consoleSession: stored.consoleSession
            )
            guard let workspace = ids.first else {
                throw OpenCodeKeyFetcher.FetchError.badResponse(401)
            }
            let updated = IOSStoredSession(
                consoleSession: stored.consoleSession,
                authCookie: stored.authCookie,
                workspaceID: workspace,
                savedAt: stored.savedAt
            )
            try IOSSessionStore.save(updated)
            session = updated
            workspaceID = workspace
            message = nil
            phase = .loggedIn
        } catch OpenCodeKeyFetcher.FetchError.badResponse(let code) where code == 401 || code == 403 {
            await recoverOrExpire(stored, code: code)
        } catch {
            if allowOfflineFallback, !stored.workspaceID.isEmpty {
                workspaceID = stored.workspaceID
                message = "当前无法验证登录，显示上次同步数据"
                phase = .loggedIn
            } else {
                phase = .error(
                    (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                )
            }
        }
    }
}
