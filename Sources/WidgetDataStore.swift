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
        let manager = NetworkManager()
        let usage = try await manager.fetchUsage()
        // 账期模式：按月重置日对齐并跨月合并，避免月中开套餐被自然月切断
        let alignment = BillingCycle.loadAlignment()
        let cost: (total: Double, entries: [CostEntry], daily: [DailyCost], dailyByKey: [String: [DailyCost]])
        if alignment == .billing {
            if let bc = await CostCrawler.shared.fetchBillingCycleCosts(workspaceID: UserDefaults(suiteName: BillingCycle.suiteName)?.string(forKey: "workspaceID") ?? "", authCookie: UserDefaults(suiteName: BillingCycle.suiteName)?.string(forKey: "authCookie") ?? "", monthlyReset: usage.monthly.resetsAt) {
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
                cost = await manager.fetchCostToday()
            }
        } else {
            // 自然月视图直接从账期缓存派生，不再单拉单月，避免切回账期时数据被截断
            if let cached = WidgetDataStore.load(), !cached.dailyCosts.isEmpty,
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
                    cost = await manager.fetchCostToday()
                }
            } else {
                cost = await manager.fetchCostToday()
            }
        }
        let costPerKey = await manager.fetchCostTodayPerKey()
        var entries: [String: Double] = [:]
        for entry in cost.entries where entry.cost > 0 {
            entries[entry.model] = entry.cost
        }
        // availableKeys 从 CostCrawler 的缓存或本次拉取中获得，与官网同步
        let keys = await CostCrawler.shared.cachedOrFetchedKeys()
        var byKeyEntries: [String: [String: Double]] = [:]
        var byKeyTotal: [String: Double] = [:]
        for (k, v) in costPerKey {
            var m: [String: Double] = [:]
            var tot: Double = 0
            for e in v where e.cost > 0 { m[e.model] = e.cost; tot += e.cost }
            byKeyEntries[k] = m
            byKeyTotal[k] = tot
        }
        // dailyByKey 从 CostCrawler 的 MonthlyCost 中获得
        let dailyByKey = cost.dailyByKey

        return WidgetSnapshot(
            rolling: usage.rolling.percent,
            weekly: usage.weekly.percent,
            monthly: usage.monthly.percent,
            rollingReset: usage.rolling.resetsAt,
            weeklyReset: usage.weekly.resetsAt,
            monthlyReset: usage.monthly.resetsAt,
            costTotal: cost.total,
            costEntries: entries,
            dailyCosts: cost.daily,
            availableKeys: keys,
            dailyByKey: dailyByKey,
            costEntriesByKey: byKeyEntries,
            costTotalByKey: byKeyTotal,
            updatedAt: Date(),
            error: nil
        )
    }
}
