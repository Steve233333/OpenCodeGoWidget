import Foundation
import WidgetKit

enum IOSUsageRefreshError: Error, LocalizedError {
    case loginRequired
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .loginRequired:
            return "控制台登录已失效，请重新登录"
        case .requestFailed:
            return "用量接口暂时不可用，已保留上次数据"
        }
    }
}

enum IOSUsageRefresher {
    @discardableResult
    static func refresh() async throws -> WidgetSnapshot {
        guard let stored = IOSSessionStore.load() else {
            throw IOSUsageRefreshError.loginRequired
        }
        IOSSessionStore.applyToAppGroup(stored)
        _ = WidgetDataStore.migrateDayConventionIfNeeded()
        _ = WidgetDataStore.migrateKeyDirectoryCacheIfNeeded()

        let snapshot: WidgetSnapshot
        do {
            snapshot = try await WidgetSnapshotRefresher.fetch(forceKeys: true)
        } catch NetworkError.authExpired {
            IOSSessionStore.clearCredentials()
            throw IOSUsageRefreshError.loginRequired
        } catch {
            if KeyDirectoryStore.load()?.status == .loginRequired {
                IOSSessionStore.clearCredentials()
                throw IOSUsageRefreshError.loginRequired
            }
            throw error
        }

        if KeyDirectoryStore.load()?.status == .loginRequired {
            IOSSessionStore.clearCredentials()
            throw IOSUsageRefreshError.loginRequired
        }

        _ = WidgetDataStore.save(snapshot)
        async let models = ModelRegistry.refreshIfNeeded(force: true)
        async let zenModels = ModelRegistry.refreshZenIfNeeded(force: true)
        async let quotas = GoQuotaRegistry.refreshIfNeeded(force: true)
        _ = await (models, zenModels, quotas)
        WidgetCenter.shared.reloadAllTimelines()
        return snapshot
    }

    static func backfillIfNeeded() async -> Bool {
        guard IOSSessionStore.load() != nil else { return false }
        let changed = await CostCrawler.shared.backfillHistoryIfNeeded()
        if changed {
            WidgetCenter.shared.reloadAllTimelines()
        }
        return changed
    }
}

@MainActor
final class IOSUsageController: ObservableObject {
    @Published private(set) var snapshot: WidgetSnapshot?
    @Published private(set) var keyDirectory: KeyDirectoryState?
    @Published private(set) var quotas: [GoQuota] = GoQuotaRegistry.cachedSync()
    @Published private(set) var quotaUpdatedAt: Date? = GoQuotaRegistry.cachedDate()
    @Published private(set) var loading = false
    @Published private(set) var backfillRunning = false
    @Published private(set) var error: String?
    @Published private(set) var loginExpired = false

    init() {
        reloadFromStorage()
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        error = nil
        loginExpired = false
        defer { loading = false }

        do {
            snapshot = try await IOSUsageRefresher.refresh()
            reloadFromStorage()
            startBackfillIfNeeded()
        } catch IOSUsageRefreshError.loginRequired {
            loginExpired = true
            error = IOSUsageRefreshError.loginRequired.localizedDescription
            reloadFromStorage()
        } catch NetworkError.authExpired {
            IOSSessionStore.clearCredentials()
            loginExpired = true
            error = IOSUsageRefreshError.loginRequired.localizedDescription
            reloadFromStorage()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            reloadFromStorage()
        }
    }

    func refreshIfStale(maxAge: TimeInterval = 300) async {
        guard !loading else { return }
        if let snapshot, Date().timeIntervalSince(snapshot.updatedAt) < maxAge {
            return
        }
        await refresh()
    }

    func reloadFromStorage() {
        snapshot = WidgetDataStore.load()
        keyDirectory = KeyDirectoryStore.load()
        quotas = GoQuotaRegistry.cachedSync()
        quotaUpdatedAt = GoQuotaRegistry.cachedDate()
        backfillRunning = BackfillProgress.isRunning()
    }

    func clearLocalData() {
        IOSSessionStore.clearAllLocalData()
        snapshot = nil
        keyDirectory = nil
        quotas = GoQuotaRegistry.cachedSync()
        quotaUpdatedAt = GoQuotaRegistry.cachedDate()
        error = nil
        loginExpired = false
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func startBackfillIfNeeded() {
        guard !backfillRunning else { return }
        backfillRunning = true
        Task {
            let monitor = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let running = BackfillProgress.isRunning()
                    await MainActor.run {
                        self.reloadFromStorage()
                        self.backfillRunning = running
                    }
                    if !running { return }
                }
            }
            let changed = await IOSUsageRefresher.backfillIfNeeded()
            monitor.cancel()
            await MainActor.run {
                if changed { self.reloadFromStorage() }
                self.backfillRunning = BackfillProgress.isRunning()
            }
        }
    }
}
