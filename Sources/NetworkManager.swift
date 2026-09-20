import Foundation
import os

enum NetworkError: Error, LocalizedError {
    case notConfigured, authExpired, requestFailed, parseError
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "未配置 ZEN_API_KEY，请在设置中粘贴"
        case .authExpired: return "鉴权过期，请更新 API Key"
        case .requestFailed: return "请求失败"
        case .parseError: return "解析失败"
        }
    }
}

final class NetworkManager: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.steve233.opencodego", category: "Network")
    private let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    // Cost endpoint is not officially documented; we try to infer from HTML if available, else fallback to usage only
    // The screenshot's cost-per-model is rendered from the same backend; currently only /v1/usage is stable with Bearer

    func fetchUsage() async throws -> UsageStats {
        // 2026-09-20：优先用**控制台官方口径**（官网页面就是拿它算百分比的）。
        // 网关 /zen/go/v1/usage 是另一套计数且**向下取整** —— 实测官网 5.72% 显示 6%，
        // 网关只给 5%，用户一眼看出"月用量不准"。控制台给的是 used/limit 原始微美分，四舍五入即可。
        if let official = await fetchConsoleGoStatus() {
            logger.info("usage via console go/status: \(official.rolling.percent)/\(official.weekly.percent)/\(official.monthly.percent)")
            return official
        }
        guard let key = KeychainStore.resolvedKey(), !key.isEmpty else {
            logger.error("ZEN_API_KEY not configured")
            throw NetworkError.notConfigured
        }
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        logger.info("Fetching usage")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            logger.error("usage status \(code)")
            if code == 401 || code == 403 { throw NetworkError.authExpired }
            throw NetworkError.requestFailed
        }
        do {
            let decoded = try Self.decoder.decode(UsageResponse.self, from: data)
            return decoded.usage
        } catch {
            logger.error("decode failed \(error.localizedDescription)")
            throw NetworkError.parseError
        }
    }

    /// 控制台的 Go 订阅状态：`GET https://opencode.ai/console/api/go/status`
    /// 返回 access.meters.{fiveHour,week,month} 各自的 usedMicroCents / limitMicroCents。
    /// 官网那三个百分比就是 used/limit 四舍五入（实测 5.72% → 官网 6%）。
    func fetchConsoleGoStatus() async -> UsageStats? {
        let d = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
        let auth = d?.string(forKey: "authCookie") ?? ""
        let session = d?.string(forKey: "consoleSession") ?? ""
        let ws = d?.string(forKey: "workspaceID") ?? ""
        guard !ws.isEmpty, !session.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://opencode.ai/console/api/go/status")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("oc_locale=zh; auth=\(auth); __Host-console_session=\(session)", forHTTPHeaderField: "Cookie")
        req.setValue(ws, forHTTPHeaderField: "x-org-id")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://opencode.ai/console/\(ws)/go", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access"] as? [String: Any],
              let meters = access["meters"] as? [String: Any] else { return nil }

        func num(_ v: Any?) -> Double {
            if let s = v as? String { return Double(s) ?? 0 }
            if let n = v as? NSNumber { return n.doubleValue }
            return 0
        }
        func percent(_ key: String) -> Int? {
            guard let m = meters[key] as? [String: Any] else { return nil }
            let limit = num(m["limitMicroCents"])
            guard limit > 0 else { return nil }
            return Int((num(m["usedMicroCents"]) / limit * 100).rounded())   // 官网口径就是四舍五入
        }
        // 接口给的是带毫秒的 ISO（"2026-10-19T02:02:53.000Z"）——默认 ISO8601DateFormatter
        // 解析不了小数秒，会 nil 掉，然后悄悄退化成"现在 ±N 小时"的兜底值（用户实拍：套餐生效
        // 显示成"今天 20:27 — 下月今天 20:27"）。两个格式都试一遍。
        func iso(_ raw: Any?) -> Date? {
            guard let s = raw as? String, !s.isEmpty else { return nil }
            let frac = ISO8601DateFormatter()
            frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = frac.date(from: s) { return d }
            return ISO8601DateFormatter().date(from: s)
        }
        func reset(_ key: String) -> Date? {
            guard let m = meters[key] as? [String: Any] else { return nil }
            return iso(m["resetsAt"])
        }
        guard let h5 = percent("fiveHour"), let wk = percent("week"), let mo = percent("month") else { return nil }
        // 月度的 resetsAt 接口不给，用订阅周期结束时间（官网就是显示成续费倒计时）
        let monthReset = iso(access["endsAt"]) ?? Date().addingTimeInterval(30 * 86400)
        return UsageStats(
            rolling: UsageItem(status: "ok", percent: h5,
                               resetsAt: reset("fiveHour") ?? Date().addingTimeInterval(5 * 3600)),
            weekly: UsageItem(status: "ok", percent: wk,
                              resetsAt: reset("week") ?? Date().addingTimeInterval(7 * 86400)),
            monthly: UsageItem(status: "ok", percent: mo, resetsAt: monthReset))
    }

    func fetchCostToday() async -> (total: Double, entries: [CostEntry], daily: [DailyCost], dailyByKey: [String: [DailyCost]]) {
        if let mc = await CostCrawler.shared.fetchMonthlyCosts() {
            let today = mc.todayEntries
            let total = today.values.reduce(0, +)
            let entries = today.map { CostEntry(model: $0.key, cost: $0.value, percent: total > 0 ? $0.value / total * 100 : 0) }.sorted { $0.cost > $1.cost }
            return (total, entries, mc.daily, mc.dailyByKey)
        }
        return (0, [], [], [:])
    }

    func fetchCostTodayPerKey() async -> [String: [CostEntry]] {
        guard let mc = await CostCrawler.shared.fetchMonthlyCosts() else { return [:] }
        var result: [String: [CostEntry]] = [:]
        // 今日按 Asia/Shanghai 判定
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = tz
        let todayStr = fmt.string(from: Date())
        for (keyId, arr) in mc.dailyByKey {
            guard let dc = arr.first(where: { $0.date == todayStr }) else { result[keyId] = []; continue }
            let tot = dc.entries.values.reduce(0,+)
            let ents = dc.entries.map { CostEntry(model: $0.key, cost: $0.value, percent: tot > 0 ? $0.value/tot*100 : 0) }.sorted{ $0.cost > $1.cost }
            result[keyId] = ents
        }
        return result
    }

    // Legacy wrapper for callers not yet migrated
    func fetchCostTodayLegacy() async -> (total: Double, entries: [CostEntry]) {
        let r = await fetchCostToday()
        return (r.total, r.entries)
    }

    private func tryCostJSON(url: URL, key: String) async -> (total: Double, entries: [CostEntry])? {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // Try to extract daily cost arrays; shapes vary, so we look for any array with model+cost
        return extractCost(from: json)
    }

    private func fetchHTML(urlString: String, key: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return html
    }

    private func parseCostFromHTML(_ html: String) -> (total: Double, entries: [CostEntry])? {
        // Look for Next.js data blobs: usagePercent or cost-related patterns
        // The cost chart is hydrated from an API; we search for any JSON with "cost" and model names
        // If not found, return nil to keep widget stable
        // Placeholder: actual HTML parsing needs live sample; return nil to keep widget stable
        _ = html
        return nil
    }

    private func extractCost(from json: [String: Any]) -> (total: Double, entries: [CostEntry])? {
        // Walk any nested dict/arrays to find model -> cost
        var found: [(String, Double)] = []
        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                for (k, v) in dict {
                    if k.contains("-go") || k.contains("deepseek") || k.contains("glm") {
                        if let d = v as? Double { found.append((k, d)) }
                        else if let i = v as? Int { found.append((k, Double(i))) }
                    }
                    walk(v)
                }
            } else if let arr = obj as? [Any] {
                for e in arr { walk(e) }
            }
        }
        walk(json)
        guard !found.isEmpty else { return nil }
        let total = found.reduce(0) { $0 + $1.1 }
        let entries = found.map { CostEntry(model: $0.0, cost: $0.1, percent: total > 0 ? $0.1/total*100 : 0) }.sorted { $0.cost > $1.cost }
        return (total, entries)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let f = SharedFormatters.shared
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = f.withFractionalSeconds.date(from: s) { return date }
            if let date = f.standard.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date \(s)")
        }
        return d
    }()
}

private final class SharedFormatters: @unchecked Sendable {
    static let shared = SharedFormatters()
    let withFractionalSeconds = ISO8601DateFormatter()
    let standard = ISO8601DateFormatter()
    private init() {
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
}
