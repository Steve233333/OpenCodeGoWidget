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

    func markExpired(_ detail: String = "控制台登录已失效，请重新登录") {
        IOSSessionStore.clearCredentials()
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
            markExpired()
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
