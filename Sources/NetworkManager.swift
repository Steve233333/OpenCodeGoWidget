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
