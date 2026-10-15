import Foundation

/// 官方用量记录的**行级解析（唯一真源）**——2026-09-23 Phase 1 从 ConsoleUsageAPI 抽出。
///
/// 「一条记录算哪一天、算哪个模型、算哪个 Key」这件事只在这里定义一次：
///   * 金额字段是**微美分**字符串（100,000,000 微美分 = 1 美元）；
///   * `createdAt`（ISO8601 带毫秒）→ 归日**必须**走 `ChartFormatters.day`（北京时间 0 点）；
///   * 一行同时算进「按模型」和「按 Key」两份拆分，两者天然相加相等。
///
/// 2026-09-26：上游撤掉 `usage/rows`（404），明细换成 `/logs` 页用的 `request-logs`。
/// 它一条记录带 `serviceAPIKeyID / model / cost(美元) / startedAt(ms)` —— 由 `rowFromLog()` 转成
/// **和以前完全一样的行格式**，所以上面的归日/拆分规则一行都不用改。
///
/// 这里不许 import SwiftUI / 不许碰网络：离线回归测试（Tests/UsagePipelineTests.swift）只编译
/// 数据层这几个文件，所以任何"顺手引个 UI/网络类型"都会让护栏失效。
enum UsageRows {
    static func microCents(_ value: Any?) -> Double {
        if let s = value as? String { return Double(s) ?? 0 }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return 0
    }

    /// 数字兜底（log 里的 cost / startedAt 可能是 Int / Double / String / 缺失）
    static func usd(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) ?? 0 }
        return 0
    }

    /// 一条 `request-logs` 记录 → 内部行格式（与老 `usage/rows` 同形状，喂给 `aggregate`）。
    ///
    /// 字段来源（2026-09-26 实测）：
    ///   * `startedAt`：epoch **毫秒** → ISO8601 `createdAt`
    ///   * `model`：实际服务的模型；缺失时回退 `requestedModel`（客户端请求名）
    ///   * `serviceAPIKeyID` → `serviceApiKeyId`（老字段名，aggregate 只认这个）
    ///   * `cost`：**美元**（不是微美分）→ ×1e8 四舍五入成微美分字符串
    static func rowFromLog(_ item: [String: Any]) -> [String: Any]? {
        let ms = usd(item["startedAt"])
        guard ms > 0 else { return nil }
        let model = (item["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (item["requestedModel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        guard let model else { return nil }
        let createdAt = isoFractional.string(from: Date(timeIntervalSince1970: ms / 1000))
        let micro = Int((usd(item["cost"]) * 100_000_000).rounded())
        var row: [String: Any] = [
            "createdAt": createdAt,
            "model": model,
            "costMicroCents": String(micro),
        ]
        if let key = item["serviceAPIKeyID"] as? String, !key.isEmpty { row["serviceApiKeyId"] = key }
        if let id = item["id"] as? String, !id.isEmpty { row["id"] = id }
        return row
    }

    /// 一批 log → 行（顺手丢掉映射不出来的）
    static func rowsFromLogs(_ items: [[String: Any]]) -> [[String: Any]] {
        items.compactMap { rowFromLog($0) }
    }

    /// `usage/cost-by-day?bucket=hour` 的返回 → **按北京时间归日**的每日总额。
    ///
    /// 老接口给的是 UTC 日（`"2026-09-19"`），和我们的日界（北京 0 点）差 8 小时；
    /// 小时桶（`"2026-08-28T06:00:00Z"`）能精确重分桶 —— 2026-09-26 实测 9/25 日志合计
    /// $0.278950 与重分桶后的 $0.2790 对齐。只当"没有明细那天的兜底"，金额仍以日志明细为准。
    static func dailyFromHourlyCost(_ json: Any) -> [DailyCost] {
        guard let arr = json as? [[String: Any]] else { return [] }
        var merged: [String: [String: Double]] = [:]
        for item in arr {
            guard let raw = item["date"] as? String else { continue }
            let value = microCents(item["totalCostMicroCents"]) / 100_000_000.0
            guard value > 0 else { continue }
            let day = dayString(createdAt: raw) ?? String(raw.prefix(10))
            merged[day, default: [:]][totalOnlyKey, default: 0] += value
        }
        return merged.map { DailyCost(date: $0.key, entries: $0.value) }.sorted { $0.date < $1.date }
    }

    /// "只有总额、没有明细"的天用的占位模型名（沿用旧口径，界面靠它判断是否有明细）
    static let totalOnlyKey = "(total)"

    /// `cost-by-day` 的候选查询口径（按优先级）。
    ///
    /// ① 小时桶能按北京时间精确重分桶（UTC 日差 8 小时的那个坑）；
    /// ②③ 是它在 2026-10-15 被上游改坏（**带 `bucket=hour` 必 500**，实测 5/5、
    ///     每次耗 16s）时的兜底：按天 / 默认。
    ///
    /// 放在这一层（而不是网络层）是为了让离线门禁能直接断言"兜底必须存在"——
    /// 这次事故就是首选口径一挂、整轮刷新被放弃，界面永远停在旧快照。
    static let costByDayQueries = ["range=30d&bucket=hour", "range=30d", ""]

    /// 依次尝试候选口径，返回**第一个**能解析出天数的结果；全挂返回 nil。
    ///
    /// - `attempt`: 取某个口径的原始 JSON（拿不到就给 nil，例如 HTTP 500）
    /// - `parse`:   把 JSON 解析成按天花费（解析不出来给空数组）
    ///
    /// 找到第一个可用口径就停（不会白白多打两次请求）；调用方在拿到 nil 时
    /// 应保留旧快照，而不是把界面清空。
    static func firstParsableCostByDay(
        candidates: [String],
        attempt: (String) async -> Any?,
        parse: (Any) -> [DailyCost]
    ) async -> (query: String, daily: [DailyCost])? {
        for query in candidates {
            guard let json = await attempt(query) else { continue }
            let daily = parse(json)
            if !daily.isEmpty { return (query, daily) }
        }
        return nil
    }

    /// 解析"按天"口径的 `cost-by-day`：一天一条、`date` 是纯日期、金额是微美分字符串。
    ///
    ///   [{"date":"2026-10-13","totalCostMicroCents":"438348146", ...}]
    ///
    /// 这是上游在 `bucket=hour` 被改坏后仍稳定支持的口径（`range=30d` / 无参数）。
    /// 只认这一个确定形状；别的形状交给上层的防御式搜索（`CostCrawler.parseCostByDay`）。
    /// 非正金额的天会被过滤（0 值的"空天"不需要占位）。
    static func parseCostByDayFlat(_ json: Any) -> [DailyCost] {
        guard let arr = json as? [[String: Any]],
              arr.contains(where: { $0["date"] != nil && $0["totalCostMicroCents"] != nil }) else {
            return []
        }
        var merged: [String: [String: Double]] = [:]
        for item in arr {
            guard let raw = item["date"] as? String else { continue }
            let usd = microCents(item["totalCostMicroCents"]) / 100_000_000.0
            guard usd > 0 else { continue }
            let key = (item["model"] as? String) ?? totalOnlyKey
            merged[String(raw.prefix(10)), default: [:]][key, default: 0] += usd
        }
        return merged.map { DailyCost(date: $0.key, entries: $0.value) }.sorted { $0.date < $1.date }
    }

    /// 二分窗口的中点（`request-logs/export` 一次最多 1000 条，超了要按中点切开）。
    /// 太窄（<120s）就不再切，避免病态递归。
    static func windowMidpoint(start: Date, end: Date, minSpan: TimeInterval = 120) -> Date? {
        let span = end.timeIntervalSince(start)
        guard span > minSpan else { return nil }
        return start.addingTimeInterval(span / 2)
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// `createdAt` → 本地日（北京时间）的 `yyyy-MM-dd`；解析不了返回 nil（调用方再兜底取前 10 位）
    static func dayString(createdAt: String) -> String? {
        let d = isoFractional.date(from: createdAt) ?? isoPlain.date(from: createdAt)
        return d.map { ChartFormatters.day.string(from: $0) }
    }

    /// 明细行 → (date→model→美元, keyId→date→model→美元)
    static func aggregate(_ rows: [[String: Any]]) -> ([String: [String: Double]], [String: [String: [String: Double]]]) {
        var daily: [String: [String: Double]] = [:]
        var byKey: [String: [String: [String: Double]]] = [:]
        for row in rows {
            guard let model = row["model"] as? String else { continue }
            let usd = microCents(row["costMicroCents"]) / 100_000_000.0
            guard usd > 0 else { continue }
            guard let created = row["createdAt"] as? String else { continue }
            let date = dayString(createdAt: created) ?? String(created.prefix(10))
            daily[date, default: [:]][model, default: 0] += usd
            if let key = row["serviceApiKeyId"] as? String, !key.isEmpty {
                byKey[key, default: [:]][date, default: [:]][model, default: 0] += usd
            }
        }
        return (daily, byKey)
    }
}
