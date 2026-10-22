import Foundation
import AppKit
import WidgetKit
import os

/// 后台用量刷新调度（2026-10-16 新增）。
///
/// 为什么要有它：以前 5 分钟那轮刷新挂在**主窗口视图**上
/// （`DashboardView` 的 `Timer.publish(every: 300)`）。窗口一关，视图销毁、循环就停了 ——
/// 快照再也不会更新，只有重启电脑（App 自启、窗口默认打开）才恢复。
/// 用户看到的就是"必须重启电脑，小组件才刷新"。
///
/// 现在循环住在 App 级单例里（和 `ProxyWatchdog` 同一个模式），跟窗口生死无关：
///   * 启动后先跑一轮（快照超过 3 分钟就刷，避免开 App 看到旧数据）；
///   * 之后每 5 分钟一轮；
///   * 系统唤醒时补一轮（睡眠期间定时器不走）。
///
/// 它只管"什么时候刷"，具体怎么刷全在 `WidgetSnapshotRefresher.fetch`，
/// 界面那套手动刷新走的是同一个入口，不存在两份逻辑。
@MainActor
final class UsageScheduler: ObservableObject {
    static let shared = UsageScheduler()

    /// 刷新间隔（秒）。3 分钟是"开 App 立刻要新数据"的阈值，5 分钟是常规节奏。
    static let interval: TimeInterval = 300
    static let staleAfter: TimeInterval = 180

    private let logger = Logger(subsystem: "com.steve233.opencodego", category: "UsageScheduler")

    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var lastError: String?

    private var timer: Timer?
    private var started = false
    private var running = false

    func start() {
        guard !started else { return }
        started = true
        WidgetDataStore.migrateKeyDirectoryCacheIfNeeded()
        // 用户可能在旧版里留下了“st_ 存进了 authCookie / 没存 workspace”的半截登录态；
        // 启动时先规整一次，避免费用图要用户手动重填。
        migrateCredentialShapeIfNeeded()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.refreshIfStale(reason: "唤醒") }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.refresh(reason: "定时")
            }
        }
        timer?.tolerance = 30
        Task { @MainActor in
            guard let self = UsageScheduler.shared as UsageScheduler? else { return }
            await self.refreshIfStale(reason: "启动")
        }
    }

    private func migrateCredentialShapeIfNeeded() {
        let d = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
        let auth = d?.string(forKey: "authCookie") ?? ""
        let session = d?.string(forKey: "consoleSession") ?? ""
        if session.isEmpty, auth.hasPrefix("st_") {
            d?.set(auth, forKey: "consoleSession")
            d?.removeObject(forKey: "authCookie")
            d?.synchronize()
        }
    }

    /// 快照够新就不打接口（App 重启后立刻点开时用）。
    func refreshIfStale(reason: String) async {
        let fresh = WidgetDataStore.load().map { Date().timeIntervalSince($0.updatedAt) < Self.staleAfter } ?? false
        if fresh {
            logger.info("刷新检查（\(reason, privacy: .public)）：快照还新，跳过")
            return
        }
        logger.info("刷新检查（\(reason, privacy: .public)）：快照已过期，开始刷新")
        await refresh(reason: reason)
    }

    /// 拉一次并落盘 + 通知小组件。失败保留旧快照（绝不用空数据覆盖）。
    func refresh(reason: String) async {
        guard !running else {
            logger.info("刷新（\(reason, privacy: .public)）：上一轮还在跑，这次跳过")
            return
        }
        running = true
        defer { running = false }
        WidgetDataStore.migrateKeyDirectoryCacheIfNeeded()
        // 登录态先同步过来（新控制台 API 缺了会 401）；WebKit 没有超时，给它 8 秒硬顶
        _ = await withTaskGroup(of: Bool?.self) { group -> Bool in
            group.addTask {
                let result = await CookieSync.syncAllCookies()
                return result.authChanged || result.sessionChanged
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
        do {
            // 登录会话可能刚更新、工作区仍为空；刷新前用会话自动补一次，避免“登录了但费用图不动”。
            await autofillWorkspaceIfPossible()
            let snap = try await WidgetSnapshotRefresher.fetch(forceKeys: true)
            WidgetDataStore.save(snap)
            lastRefreshAt = Date()
            lastError = nil
            logger.info("刷新（\(reason, privacy: .public)）成功：今日 \(snap.costTotal, privacy: .public) USD，天数 \(snap.dailyCosts.count, privacy: .public)")
            // 等一拍让扩展容器可见，然后通知小组件（双发规避限频）
            try? await Task.sleep(nanoseconds: 200_000_000)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
            WidgetCenter.shared.reloadAllTimelines()
            try? await Task.sleep(nanoseconds: 300_000_000)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
            // 后台补历史明细；补完再通知一次（不阻塞刷新）
            Task {
                if await CostCrawler.shared.backfillHistoryIfNeeded() {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastError = msg
            logger.error("刷新（\(reason, privacy: .public)）失败：\(msg, privacy: .public)（保留旧快照）")
        }
    }

    private func autofillWorkspaceIfPossible() async {
        let d = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
        let ws = d?.string(forKey: "workspaceID") ?? ""
        guard ws.isEmpty else { return }
        let auth = d?.string(forKey: "authCookie") ?? ""
        let session = d?.string(forKey: "consoleSession") ?? ""
        guard !auth.isEmpty || !session.isEmpty else { return }
        if let ids = try? await OpenCodeKeyFetcher.fetchWorkspaceIDs(authCookie: auth, consoleSession: session),
           let first = ids.first {
            d?.set(first, forKey: "workspaceID")
            d?.synchronize()
            logger.info("自动补齐工作区：\(first)")
        }
    }
}
