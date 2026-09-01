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

enum WidgetDataStore {
    static let suiteName = "2DC432GLL2.com.steve233.opencodego"
    static let snapshotKey = "widget_snapshot"
    // 文件直通：Group Container 下 Application Support/widget_snapshot.json，Widget 扩展立即可见，不走 cfprefsd
    static var fileURL: URL? {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName) else { return nil }
        return url.appendingPathComponent("widget_snapshot.json")
    }
    static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    static func save(_ snap: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        // 1) 写文件（主路径）
        if let url = fileURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        // 2) 双写 UserDefaults（兼容旧版 + 调试）
        if let d = defaults {
            d.set(data, forKey: snapshotKey)
            d.synchronize()
            CFPreferencesAppSynchronize(suiteName as CFString)
        }
    }

    static func load() -> WidgetSnapshot? {
        // 优先读文件（最新），失败回退 UserDefaults
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) {
            return snap
        }
        guard let d = defaults, let data = d.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
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
