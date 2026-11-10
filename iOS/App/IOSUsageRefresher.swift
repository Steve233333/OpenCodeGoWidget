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
            // 只提示，不立刻抹 Keychain：一次 WAF/网络抖动返回 401 不该把有效会话删掉。
            // 用户在横幅里点「重试」；确实过期再走重新登录。
            throw IOSUsageRefreshError.loginRequired
        } catch {
            throw error
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
    @Published private(set) var widgetSharingError: String?

    init() {
        reloadFromStorage()
    }

    func refresh() async {
#if DEBUG
        if IOSDemoMode.isEnabled { return }
#endif
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
            loginExpired = true
            error = IOSUsageRefreshError.loginRequired.localizedDescription
            reloadFromStorage()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            reloadFromStorage()
        }
    }

    func refreshIfStale(maxAge: TimeInterval = 300) async {
        guard IOSPreferences.autoRefreshEnabled else { return }
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
        widgetSharingError = WidgetDataStore.isAppGroupAvailable
            ? nil
            : "小组件共享容器不可用：当前签名没有保留 App Group，请用新版 IPA 重新签名并同时签主 App 与小组件扩展。"
    }

    func reloadWidget() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    func clearLocalData() {
        IOSSessionStore.clearAllLocalData()
        snapshot = nil
        keyDirectory = nil
        quotas = GoQuotaRegistry.cachedSync()
        quotaUpdatedAt = GoQuotaRegistry.cachedDate()
        error = nil
        loginExpired = false
        widgetSharingError = nil
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

#if DEBUG
    /// 仅 Debug 构建：给模拟器截图用的确定性数据，不影响 Release 和真实缓存。
    func loadDemoData() {
        let calendar = BillingCycle.calendar
        let formatter = ChartFormatters.day
        let today = calendar.startOfDay(for: Date())
        let weights: [(String, Double)] = [
            ("deepseek-v4.1-flash", 0.52),
            ("glm-5.3", 0.21),
            ("kimi-k3", 0.14),
            ("qwen3.8-max", 0.08),
            ("minimax-m3", 0.05),
        ]

        var daily: [DailyCost] = []
        for index in 0..<30 {
            guard let date = calendar.date(byAdding: .day, value: index - 29, to: today) else {
                continue
            }
            let dayTotal = 0.7 + 1.1 * abs(sin(Double(index) * 0.7)) + Double(index % 7) * 0.12
            var entries: [String: Double] = [:]
            for (model, weight) in weights {
                entries[model] = dayTotal * weight
            }
            daily.append(DailyCost(date: formatter.string(from: date), entries: entries))
        }

        let last = daily.last
        let todayTotal = last?.total ?? 0
        let keys = [
            ApiKeyInfo(id: "key_primary", displayName: "个人 - 主 Key"),
            ApiKeyInfo(id: "key_ci", displayName: "个人 - CI"),
        ]

        snapshot = WidgetSnapshot(
            rolling: 8,
            weekly: 13,
            monthly: 74,
            rollingReset: Date().addingTimeInterval(2 * 3_600 + 24 * 60),
            weeklyReset: Date().addingTimeInterval(5 * 86_400),
            monthlyReset: Date().addingTimeInterval(15 * 86_400),
            costTotal: todayTotal,
            costEntries: last?.entries ?? [:],
            dailyCosts: daily,
            availableKeys: keys,
            updatedAt: Date()
        )
        keyDirectory = KeyDirectoryState(
            status: .live,
            keys: keys,
            checkedAt: Date(),
            sessionFingerprint: "demo",
            detail: nil
        )
        quotas = GoQuotaRegistry.fallbackQuotas + [
            GoQuota(slug: "union-alpha", displayName: "Union Alpha Free", h5: nil, weekly: nil, monthly: nil),
        ]
        quotaUpdatedAt = Date()
        loading = false
        error = nil
        loginExpired = false
        widgetSharingError = nil
        backfillRunning = false
    }
#endif
}
