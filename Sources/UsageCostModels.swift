import Foundation

struct ApiKeyInfo: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let displayName: String
    static let allCasesPlaceholder = ApiKeyInfo(id: "__all__", displayName: "所有密钥")
}

struct DailyCost: Codable, Equatable {
    let date: String // YYYY-MM-DD
    var entries: [String: Double]
    var total: Double { entries.values.reduce(0, +) }
}

/// 历史回填的"只允许一个在跑"闸门（actor 版，从 async 上下文里调用不会报警告）
actor BackfillGate {
    private var running = false
    func acquire() -> Bool {
        if running { return false }
        running = true
        return true
    }
    func release() { running = false }
}

struct MonthlyCost {
    let daily: [DailyCost]
    let keys: [ApiKeyInfo]
    /// keyId -> per-date aggregations (only non-zero entries)
    let dailyByKey: [String: [DailyCost]]
    var total: Double { daily.reduce(0) { $0 + $1.total } }
    var todayEntries: [String: Double] {
        todayEntries(for: Date())
    }

    /// 可注入日期，便于测试；当日无数据返回 [:]，避免回退到昨日导致“今日用量”不刷新
    func todayEntries(for date: Date) -> [String: Double] {
        // 2026-09-23：日界只认 ChartFormatters.day（北京时间 0 点）。这里以前自带一份格式化器，
        // 结果和别处的口径漂移 → 出现"今日总额已经 0 点重置、今日模型还没重置"的双口径 bug。
        let todayStr = ChartFormatters.day.string(from: date)
        if let d = daily.first(where: { $0.date == todayStr }) { return d.entries }
        return [:]
    }

    func todayEntries(for date: Date, keyId: String?) -> [String: Double] {
        guard let k = keyId, !k.isEmpty else { return todayEntries(for: date) }
        guard let arr = dailyByKey[k] else { return [:] }
        let todayStr = ChartFormatters.day.string(from: date)
        if let d = arr.first(where: { $0.date == todayStr }) { return d.entries }
        return [:]
    }

    /// 便捷：返回指定 key 的月度 daily（nil 表示全部）
    func daily(for keyId: String?) -> [DailyCost] {
        guard let k = keyId, !k.isEmpty else { return daily }
        return dailyByKey[k] ?? []
    }
}
