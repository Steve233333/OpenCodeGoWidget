import Foundation

struct ApiKeyInfo: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let displayName: String
    static let allCasesPlaceholder = ApiKeyInfo(id: "__all__", displayName: "所有密钥")
}

/// 控制台 `GET /console/api/service-accounts` 的解析结果：只留"现在还能用"的钥匙。
struct ConsoleKeyList: Equatable {
    let keys: [ApiKeyInfo]
    /// 被跳过的条目数（已吊销 / 非 active / 已过期）—— 用来记日志，不静默丢
    let skipped: Int
}

extension ApiKeyInfo {
    /// 解析控制台返回的密钥列表（2026-09-24）。
    ///
    /// 为什么抽成纯函数：这是"下拉框里到底有哪几把钥匙"的**唯一判定**。以前它埋在
    /// `CostCrawler.fetchConsoleKeys()` 的网络方法里，既没法离线测，也没规定过期怎么算 ——
    /// 结果就出过"新建的 Key 永远不出现"这种只能靠肉眼发现的问题。
    ///
    /// 规则：
    ///   - 跳过已吊销（`revokedAt` 非空）与非 `active` 状态
    ///   - 跳过已过期（`expiresAt` 早于 now）；日期解析不出来时按"没过期"处理（宁可多留不误删）
    ///   - 账号名去掉接口里的 `Legacy: ` 前缀；key 的 `name` 为空时用 id 兜底
    ///   - 显示名 `账号 - 名称`；保持接口顺序
    ///   - 拿不到 `items`（非 JSON / 结构变了）返回 nil，调用方沿用缓存
    static func parseConsoleKeys(_ data: Data, now: Date = Date()) -> ConsoleKeyList? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return nil }
        var out: [ApiKeyInfo] = []
        var skipped = 0
        for item in items {
            let account = item["account"] as? [String: Any]
            let accountName = ((account?["name"] as? String) ?? "")
                .replacingOccurrences(of: "Legacy: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let keys = item["keys"] as? [[String: Any]] else { continue }
            for key in keys {
                guard let id = key["id"] as? String, !id.isEmpty else { continue }
                if isUnusableKey(key, now: now) {
                    skipped += 1
                    continue
                }
                let rawName = (key["name"] as? String) ?? ""
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : rawName
                let display = accountName.isEmpty ? name : "\(accountName) - \(name)"
                out.append(ApiKeyInfo(id: id, displayName: display))
            }
        }
        return ConsoleKeyList(keys: out, skipped: skipped)
    }

    /// 这把钥匙现在还能不能用：吊销 / 非 active / 已过期 → 不能用。
    static func isUnusableKey(_ key: [String: Any], now: Date) -> Bool {
        if let revoked = key["revokedAt"] as? String, !revoked.isEmpty { return true }
        if let status = key["status"] as? String, status.lowercased() != "active" { return true }
        if let expires = key["expiresAt"] as? String, !expires.isEmpty,
           let date = parseISO8601(expires), date <= now { return true }
        return false
    }

    /// 控制台的时间是 `2026-09-23T17:03:55.000Z`（带毫秒），也兼容不带毫秒的写法。
    static func parseISO8601(_ text: String) -> Date? {
        if let d = iso8601WithFraction.date(from: text) { return d }
        return iso8601Plain.date(from: text)
    }

    private static let iso8601WithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
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
