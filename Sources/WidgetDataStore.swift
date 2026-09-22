import Foundation
import CoreFoundation

struct WidgetSnapshot: Codable {
    var rolling: Int
    var weekly: Int
    var monthly: Int
    var rollingReset: Date
    var weeklyReset: Date
    var monthlyReset: Date
    var costTotal: Double
    var costEntries: [String: Double] // model -> cost (today, 聚合)
    var dailyCosts: [DailyCost] = []
    var availableKeys: [ApiKeyInfo] = []
    var dailyByKey: [String: [DailyCost]] = [:]
    var costEntriesByKey: [String: [String: Double]] = [:]
    var costTotalByKey: [String: Double] = [:]
    var updatedAt: Date
    var error: String?

    enum CodingKeys: String, CodingKey {
        case rolling, weekly, monthly, rollingReset, weeklyReset, monthlyReset
        case costTotal, costEntries, dailyCosts
        case availableKeys, dailyByKey, costEntriesByKey, costTotalByKey
        case updatedAt, error
    }
    init(rolling: Int, weekly: Int, monthly: Int, rollingReset: Date, weeklyReset: Date, monthlyReset: Date, costTotal: Double, costEntries: [String: Double], dailyCosts: [DailyCost] = [], availableKeys: [ApiKeyInfo] = [], dailyByKey: [String: [DailyCost]] = [:], costEntriesByKey: [String: [String: Double]] = [:], costTotalByKey: [String: Double] = [:], updatedAt: Date, error: String? = nil) {
        self.rolling = rolling; self.weekly = weekly; self.monthly = monthly
        self.rollingReset = rollingReset; self.weeklyReset = weeklyReset; self.monthlyReset = monthlyReset
        self.costTotal = costTotal; self.costEntries = costEntries; self.dailyCosts = dailyCosts
        self.availableKeys = availableKeys; self.dailyByKey = dailyByKey; self.costEntriesByKey = costEntriesByKey; self.costTotalByKey = costTotalByKey
        self.updatedAt = updatedAt; self.error = error
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rolling = try c.decode(Int.self, forKey: .rolling)
        weekly = try c.decode(Int.self, forKey: .weekly)
        monthly = try c.decode(Int.self, forKey: .monthly)
        rollingReset = try c.decode(Date.self, forKey: .rollingReset)
        weeklyReset = try c.decode(Date.self, forKey: .weeklyReset)
        monthlyReset = try c.decode(Date.self, forKey: .monthlyReset)
        costTotal = try c.decode(Double.self, forKey: .costTotal)
        costEntries = try c.decode([String: Double].self, forKey: .costEntries)
        dailyCosts = try c.decodeIfPresent([DailyCost].self, forKey: .dailyCosts) ?? []
        availableKeys = try c.decodeIfPresent([ApiKeyInfo].self, forKey: .availableKeys) ?? []
        dailyByKey = try c.decodeIfPresent([String: [DailyCost]].self, forKey: .dailyByKey) ?? [:]
        costEntriesByKey = try c.decodeIfPresent([String: [String: Double]].self, forKey: .costEntriesByKey) ?? [:]
        costTotalByKey = try c.decodeIfPresent([String: Double].self, forKey: .costTotalByKey) ?? [:]
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
    func filteredDaily(for keyId: String?) -> [DailyCost] {
        guard let k = keyId, !k.isEmpty else { return dailyCosts }
        return dailyByKey[k] ?? []
    }
    func filteredCostEntries(for keyId: String?) -> [String: Double] {
        guard let k = keyId, !k.isEmpty else { return costEntries }
        return costEntriesByKey[k] ?? [:]
    }
    func filteredCostTotal(for keyId: String?) -> Double {
        guard let k = keyId, !k.isEmpty else { return costTotal }
        return costTotalByKey[k] ?? 0
    }
}

/// 读快照的结果：带「从哪个通道读到的」和「读不到时卡在哪」，供小组件空态文案与主 App 自检共用。
struct WidgetSnapshotLoad {
    let snapshot: WidgetSnapshot?
    let source: String
    let groupContainerPath: String?
    let groupFileExists: Bool
    let widgetChannelPath: String?
    let widgetChannelWritable: Bool
    var groupAvailable: Bool { groupContainerPath != nil }
}

/// 历史回填的运行状态：界面用它决定要不要显示进度条、要不要每 5 秒把快照重读回界面。
enum BackfillProgress {
    static let suiteName = "2DC432GLL2.com.steve233.opencodego"
    static func isRunning() -> Bool {
        let d = UserDefaults(suiteName: suiteName)
        guard d?.bool(forKey: "historyBackfillRunning") == true else { return false }
        // 标记超过 15 分钟没更新 = 上次是被杀掉留下的陈旧标记，别让界面一直显示"补齐中"
        if let at = d?.object(forKey: "historyBackfillRunningAt") as? Date,
           Date().timeIntervalSince(at) > 900 { return false }
        return true
    }
}

enum WidgetDataStore {
    static let suiteName = "2DC432GLL2.com.steve233.opencodego"
    static let snapshotKey = "widget_snapshot"
    static let widgetBundleID = "com.steve233.opencodego.widget"
    static let widgetSubdir = "OpenCodeGoWidget"
    static let fileName = "widget_snapshot.json"

    /// 主通道：App Group 容器（需要 entitlement 生效；沙盒小组件唯一的正规入口）
    static var groupContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
    }
    static var fileURL: URL? { groupContainerURL?.appendingPathComponent(fileName) }
    static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    /// 备用通道（本机视角）：小组件自己的沙盒容器。
    /// 沙盒进程读「自己的容器」永远允许，跟 App Group entitlement 无关；
    /// 非沙盒的主 App 用真实 home 拼同一条路径写进去（见 widgetHostFileURL）。
    static var widgetOwnFileURL: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil, create: false) else { return nil }
        return base.appendingPathComponent(widgetSubdir, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// 备用通道（宿主机视角）：主 App 往小组件容器里写的那份。
    /// 只在容器已经由系统创建过（小组件至少跑过一次）时才返回路径，绝不自己乱建 Containers 目录。
    static var widgetHostFileURL: URL? {
        let containerData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(widgetBundleID, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
        guard FileManager.default.fileExists(atPath: containerData.path) else { return nil }
        return containerData
            .appendingPathComponent("Library/Application Support/\(widgetSubdir)", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// 所有能写的通道都写一遍：任意一条通，小组件就还有救。
    /// 返回是否至少成功写出一条通道（失败不再静默——调用方可据此报警）。
    @discardableResult
    static func save(_ snap: WidgetSnapshot) -> Bool {
        guard let data = try? JSONEncoder().encode(snap) else { return false }
        var wrote = false
        for url in [fileURL, widgetHostFileURL, widgetOwnFileURL].compactMap({ $0 }) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                wrote = true
            } catch {
                // 单条通道失败不影响其它通道（沙盒里写宿主机路径必然失败，属正常）
            }
        }
        // UserDefaults 双写（兼容旧版 + 调试）
        if let d = defaults {
            d.set(data, forKey: snapshotKey)
            d.synchronize()
            CFPreferencesAppSynchronize(suiteName as CFString)
            wrote = true
        }
        return wrote
    }

    static func load() -> WidgetSnapshot? { loadDetailed().snapshot }

    /// 2026-09-20：换账号（或手动清缓存）时把本机这份用量数据**整个抹掉** ——
    /// 快照三条通道 + 回填标记；cookies / Key 不动。
    /// 背景：刷新是"保留旧天 + 合并新数据"的增量逻辑，换账号后不抹掉的话，
    /// 上一个账号的历史天会被原样保留，图上就是两个账号的数据串在一起。
    @discardableResult
    static func wipeUsageCache() -> Bool {
        var removed = false
        for url in [fileURL, widgetHostFileURL, widgetOwnFileURL].compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                removed = true
            }
        }
        if let d = defaults {
            for key in [snapshotKey, "historyBackfillDone", "historyBackfillCursor",
                        "historyBackfillLastCount", "historyBackfillFailedWindows",
                        "historyRepairLast", "historyBackfillRunning", "historyBackfillRunningAt"] {
                d.removeObject(forKey: key)
            }
            d.synchronize()
        }
        return removed
    }

    /// 日界口径换过一次就整体作废一次（增量合并是"保留旧天"的，不抹掉的话新口径永远追不上旧数字）。
    /// 历史：`utc`（2026-09-22 为对齐官网短暂用过）→ `local`（2026-09-23 用户拍板：北京时间 0 点刷新）。
    static let dayConventionKey = UsageMerge.CachePolicy.dayConventionKey
    static let dayConventionValue = UsageMerge.CachePolicy.dayConventionValue
    @discardableResult
    static func migrateDayConventionIfNeeded() -> Bool {
        guard let d = defaults else { return false }
        guard UsageMerge.CachePolicy.needsWipe(storedConvention: d.string(forKey: dayConventionKey)) else { return false }
        wipeUsageCache()
        d.set(dayConventionValue, forKey: dayConventionKey)
        d.synchronize()
        return true
    }

    static func loadDetailed() -> WidgetSnapshotLoad {
        let groupPath = groupContainerURL?.path
        let groupFile = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let widgetHost = widgetHostFileURL
        let widgetWritable = widgetHost.map {
            FileManager.default.isWritableFile(atPath: $0.deletingLastPathComponent().path)
                || FileManager.default.isWritableFile(atPath: FileManager.default.homeDirectoryForCurrentUser.path)
        } ?? false

        func wrap(_ snap: WidgetSnapshot, _ source: String) -> WidgetSnapshotLoad {
            WidgetSnapshotLoad(snapshot: snap, source: source, groupContainerPath: groupPath,
                               groupFileExists: groupFile, widgetChannelPath: widgetHost?.path,
                               widgetChannelWritable: widgetWritable)
        }

        // 1) App Group 文件（最新，不走 cfprefsd）
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) {
            return wrap(snap, "App Group 文件")
        }
        // 2) App Group 偏好域（旧版兼容）
        if let d = defaults, let data = d.data(forKey: snapshotKey),
           let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) {
            return wrap(snap, "App Group 偏好")
        }
        // 3) 备用通道：小组件自己的容器（沙盒里 = 自己的 Application Support；宿主机 = 主 App 写的那份）
        for (label, url) in [("小组件容器", widgetOwnFileURL), ("小组件容器(宿主)", widgetHostFileURL)] {
            if let url, let data = try? Data(contentsOf: url),
               let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) {
                return wrap(snap, label)
            }
        }
        return WidgetSnapshotLoad(snapshot: nil, source: "无", groupContainerPath: groupPath,
                                  groupFileExists: groupFile, widgetChannelPath: widgetHost?.path,
                                  widgetChannelWritable: widgetWritable)
    }

    /// 主 App 里点「小组件自检」时打印的报告：一眼看出卡在哪条通道。
    static func diagnose() -> String {
        let r = loadDetailed()
        var lines: [String] = []
        if let s = r.snapshot {
            let age = Int(Date().timeIntervalSince(s.updatedAt) / 60)
            lines.append("快照：✅ 读到（来源：\(r.source)）")
            lines.append("快照时间：\(s.updatedAt.formatted(date: .numeric, time: .standard))（\(age) 分钟前）")
        } else {
            lines.append("快照：❌ 三条通道都读不到")
        }
        if let p = r.groupContainerPath {
            lines.append("App Group 容器：✅ \(p)")
            lines.append("  · 快照文件：\(r.groupFileExists ? "存在" : "不存在")")
        } else {
            lines.append("App Group 容器：❌ 拿不到（entitlement/签名问题 → 沙盒小组件必然空白）")
        }
        if let p = r.widgetChannelPath {
            lines.append("备用通道（小组件自己的容器）：\(r.widgetChannelWritable ? "✅ 可写" : "⚠️ 不可写")")
            lines.append("  · \(p)")
        } else {
            lines.append("备用通道：⚠️ 小组件容器还没被系统创建（先把小组件加到桌面/通知中心跑一次）")
        }
        lines.append("用户偏好域：\(defaults == nil ? "❌ 不可用" : "✅ 可用")")
        lines.append("")
        lines.append("判读：容器 ❌ 或 文件 不存在 → 小组件会空白；备用通道 ✅ 的情况下重开 App 刷新一次即可自愈。")
        return lines.joined(separator: "\n")
    }
}

enum WidgetConstants {
    static let kind = "OpenCodeGoWidget"
}

enum WidgetSnapshotRefresher {
    static func fetch() async throws -> WidgetSnapshot {
        // 日界口径换过一次（北京→UTC），旧口径的数据整体作废，避免新旧混着显示
        WidgetDataStore.migrateDayConventionIfNeeded()
        let manager = NetworkManager()
        let usage = try await manager.fetchUsage()
        // 账期模式：按月重置日对齐并跨月合并，避免月中开套餐被自然月切断
        let alignment = BillingCycle.loadAlignment()
        let costShared = UserDefaults(suiteName: BillingCycle.suiteName)
        // 2026-09-19：两种视图都先**真抓一次**。以前自然月分支只重读缓存，
        // 用户点「刷新」等于什么都没干（历史丢了也永远补不回来）。
        let liveCycle = await CostCrawler.shared.fetchBillingCycleCosts(
            workspaceID: costShared?.string(forKey: "workspaceID") ?? "",
            authCookie: costShared?.string(forKey: "authCookie") ?? "",
            monthlyReset: usage.monthly.resetsAt)
        let cost: (total: Double, entries: [CostEntry], daily: [DailyCost], dailyByKey: [String: [DailyCost]])
        if alignment == .billing {
            if let bc = liveCycle {
                let todayEntries = bc.todayEntries
                let tot = todayEntries.values.reduce(0,+)
                let ents = todayEntries.map { CostEntry(model: $0.key, cost: $0.value, percent: tot>0 ? $0.value/tot*100:0) }.sorted{ $0.cost>$1.cost }
                cost = (tot, ents, bc.daily, bc.dailyByKey)
            } else if let cached = WidgetDataStore.load(), !cached.dailyCosts.isEmpty {
                // 账期拉取偶发失败时保旧，避免“自然月”那次单月数据把 30 天账期覆盖掉
                let fmt = ChartFormatters.day
                let todayStr = fmt.string(from: Date())
                let todayEntries: [String: Double] = {
                    if let dc = cached.dailyCosts.first(where: { $0.date == todayStr }) { return dc.entries }
                    return cached.costEntries
                }()
                let tot = todayEntries.values.reduce(0,+)
                let ents = todayEntries.map { CostEntry(model: $0.key, cost: $0.value, percent: tot>0 ? $0.value/tot*100:0) }.sorted{ $0.cost>$1.cost }
                cost = (tot, ents, cached.dailyCosts, cached.dailyByKey)
            } else {
                // 2026-09-23 Phase 1：老接口已下线，拉不到就是"没有数据"，
                // 上层会保留旧快照；不再回落去喂旧接口/HAR 的陈旧数字。
                cost = (0, [], [], [:])
            }
        } else {
            // 自然月视图：同样先用这次真抓的结果（保留整段，不裁 —— 切回账期才不会缺天），
            // 抓失败才退回缓存派生
            if let bc = liveCycle, !bc.daily.isEmpty {
                let todayEntries = bc.todayEntries
                let tot = todayEntries.values.reduce(0,+)
                let ents = todayEntries.map { CostEntry(model: $0.key, cost: $0.value, percent: tot>0 ? $0.value/tot*100:0) }.sorted{ $0.cost>$1.cost }
                cost = (tot, ents, bc.daily, bc.dailyByKey)
            } else if let cached = WidgetDataStore.load(), !cached.dailyCosts.isEmpty,
               let monthInterval = BillingCycle.calendar.dateInterval(of: .month, for: Date()) {
                let cal = BillingCycle.calendar
                let startStr = ChartFormatters.day.string(from: monthInterval.start)
                let days = Int(monthInterval.duration/86400)
                let endDate = cal.date(byAdding: .day, value: max(0, days - 1), to: monthInterval.start) ?? Date()
                let endStr = ChartFormatters.day.string(from: endDate)
                let filtered = cached.dailyCosts.filter { $0.date >= startStr && $0.date <= endStr }
                if !filtered.isEmpty {
                    var byKey: [String: [DailyCost]] = [:]
                    for (k, arr) in cached.dailyByKey { byKey[k] = arr.filter { $0.date >= startStr && $0.date <= endStr } }
                    let todayStr = ChartFormatters.day.string(from: Date())
                    let todayEntries = filtered.first(where: { $0.date == todayStr })?.entries ?? [:]
                    let tot = todayEntries.values.reduce(0,+)
                    let ents: [CostEntry] = todayEntries.map { kv in CostEntry(model: kv.key, cost: kv.value, percent: tot>0 ? kv.value/tot*100:0) }.sorted{ $0.cost>$1.cost }
                    cost = (tot, ents, filtered, byKey)
                } else {
                    cost = (0, [], [], [:])
                }
            } else {
                cost = (0, [], [], [:])
            }
        }
        // 最后一道护栏（2026-09-23 Phase 1 收敛进 UsageMerge）：任何一条抓取路径只给
        // "每天一个总额"时，都不能把已经补好的逐模型明细 / 按 Key 明细整片冲掉。
        var dailyFinal = cost.daily
        var byKeyFinal = cost.dailyByKey
        if let cached = WidgetDataStore.load() {
            dailyFinal = UsageMerge.mergeDaily(new: dailyFinal, into: cached.dailyCosts)
            byKeyFinal = UsageMerge.mergeByKey(new: byKeyFinal, into: cached.dailyByKey)
        }
        // 2026-09-19 修「今日模型和实际用量对不上」：
        // 以前这一块单独调老接口（fetchCostTodayPerKey），新控制台上线后两边数据源不一致 ——
        // 实测同一天同一个 Key：daily（新接口 rows）$1.12 vs 老接口 $0.60，界面上就打架。
        // 现在统一从**同一份当日数据**派生：今日模型取 daily 里今天那格，按 Key 取 dailyByKey 今天那格。
        let todayStr = ChartFormatters.day.string(from: Date())
        let entries: [String: Double] = (dailyFinal.first { $0.date == todayStr }?.entries ?? [:])
            .filter { $0.value > 0 }
        var byKeyEntries: [String: [String: Double]] = [:]
        var byKeyTotal: [String: Double] = [:]
        for (key, arr) in byKeyFinal {
            guard let day = arr.first(where: { $0.date == todayStr }) else { continue }
            let m = day.entries.filter { $0.value > 0 }
            guard !m.isEmpty else { continue }
            byKeyEntries[key] = m
            byKeyTotal[key] = m.values.reduce(0, +)
        }
        // availableKeys：只用控制台密钥列表里的 Key（2026-09-19 修：以前会把"明细里出现过的 Key"
        // 也并进来，导致**已删除的 Key**以裸 id 形式出现在下拉框里 —— 用户明明只有 2 把却看到 3 个。
        // 已删除 Key 的历史用量仍保留在"所有密钥"里（和控制台一致：它算在 Legacy 服务账号名下）。
        let keys = await CostCrawler.shared.cachedOrFetchedKeys()
        // dailyByKey 从 CostCrawler 的 MonthlyCost 中获得
        let dailyByKey = byKeyFinal

        return WidgetSnapshot(
            rolling: usage.rolling.percent,
            weekly: usage.weekly.percent,
            monthly: usage.monthly.percent,
            rollingReset: usage.rolling.resetsAt,
            weeklyReset: usage.weekly.resetsAt,
            monthlyReset: usage.monthly.resetsAt,
            costTotal: cost.total,
            costEntries: entries,
            dailyCosts: dailyFinal,
            availableKeys: keys,
            dailyByKey: dailyByKey,
            costEntriesByKey: byKeyEntries,
            costTotalByKey: byKeyTotal,
            updatedAt: Date(),
            error: nil
        )
    }
}
