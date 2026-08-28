import Foundation
import os

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
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        // 复用 ChartFormatters.day 的 Asia/Shanghai 语义，保证与 daily 解析一致
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = tz
        let todayStr = fmt.string(from: date)
        if let d = daily.first(where: { $0.date == todayStr }) { return d.entries }
        return [:]
    }

    func todayEntries(for date: Date, keyId: String?) -> [String: Double] {
        guard let k = keyId, !k.isEmpty else { return todayEntries(for: date) }
        guard let arr = dailyByKey[k] else { return [:] }
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = tz
        let todayStr = fmt.string(from: date)
        if let d = arr.first(where: { $0.date == todayStr }) { return d.entries }
        return [:]
    }

    /// 便捷：返回指定 key 的月度 daily（nil 表示全部）
    func daily(for keyId: String?) -> [DailyCost] {
        guard let k = keyId, !k.isEmpty else { return daily }
        return dailyByKey[k] ?? []
    }
}

final class CostCrawler: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.steve233.opencodego", category: "CostCrawler")
    static let shared = CostCrawler()

    func fetchMonthlyCosts(for month: Date = Date()) async -> MonthlyCost? {
        // Try workspace-based cost crawling first (real stacked data), then fallback to JSON endpoints
        if let mc = await fetchViaWorkspace() { return mc }
        guard let key = KeychainStore.resolvedKey(), !key.isEmpty else { return nil }
        for path in ["zen/go/v1/cost", "zen/go/v1/costs", "zen/go/v1/dashboard"] {
            if let url = URL(string: "https://opencode.ai/\(path)"),
               let mc = await tryCostJSON(url: url, key: key, month: month) {
                return mc
            }
        }
        return nil
    }

    // MARK: - Workspace HAR-based crawler (Cookie + workspaceID) - App Group only, no direct file read

    private func fetchViaWorkspace() async -> MonthlyCost? {
        // Only via App Group shared prefs (user filled in Settings window, already normalized by App)
        let shared = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
        var workspaceID: String? = shared?.string(forKey: "workspaceID")
        var authCookie: String? = shared?.string(forKey: "authCookie")
        // Normalize workspaceID: user may have pasted full URL https://opencode.ai/workspace/wrk_.../usage
        if let w = workspaceID, w.contains("/workspace/") {
            if let r = w.range(of: "/workspace/") {
                let rest = String(w[r.upperBound...])
                workspaceID = rest.split(separator: "/").first.map(String.init) ?? w
            }
        }
        // Defensive: if stored authCookie is still a HAR path (legacy), ignore and treat as missing
        // App.swift now ensures real 539B cookie is stored, so this is just a safety net.
        if let a = authCookie, (a.hasSuffix(".har") || a.contains(".har")) {
            logger.warning("CostCrawler: authCookie is still HAR path, ignoring - App should have parsed it")
            authCookie = nil
        }
        guard let ws = workspaceID, !ws.isEmpty, let auth = authCookie, !auth.isEmpty else {
            logger.info("CostCrawler: no workspaceID/auth in App Group, fallback to JSON")
            return nil
        }
        return await fetchWorkspaceCost(workspaceID: ws, authCookie: auth)
    }

    private func fetchWorkspaceCost(workspaceID: String, authCookie: String) async -> MonthlyCost? {
        let cal = Calendar.current
        let now = Date()
        let comps = cal.dateComponents(in: TimeZone(identifier: "Asia/Shanghai")!, from: now)
        let year = comps.year ?? 2026
        let month0 = (comps.month ?? 8) - 1

        // Layered fetch: with X-Server header -> without -> fallback to JSON/HAR
        if let mc = await fetchWorkspaceCostAttempt(workspaceID: workspaceID, authCookie: authCookie, year: year, month0: month0, includeServerHeader: true) {
            return mc
        }
        logger.info("CostCrawler: retry without X-Server-Id")
        if let mc = await fetchWorkspaceCostAttempt(workspaceID: workspaceID, authCookie: authCookie, year: year, month0: month0, includeServerHeader: false) {
            return mc
        }
        logger.info("CostCrawler: _server both header variants failed, fallback to HAR cached JSON if available")
        // HAR local fallback: try to parse locally cached HAR _server response if App has saved it via shared auth
        // Retained branch but triggered from shared auth, not file path
        if let mc = await fetchHARFallback() {
            return mc
        }
        logger.info("CostCrawler: HAR fallback also nil, will try legacy JSON in caller")
        return nil
    }

    private func fetchWorkspaceCostAttempt(workspaceID: String, authCookie: String, year: Int, month0: Int, includeServerHeader: Bool) async -> MonthlyCost? {
        let url = URL(string: "https://opencode.ai/_server")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("https://opencode.ai", forHTTPHeaderField: "Origin")
        req.setValue("https://opencode.ai/workspace/\(workspaceID)/usage", forHTTPHeaderField: "Referer")
        req.setValue("oc_locale=zh; auth=\(authCookie)", forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        if includeServerHeader {
            req.setValue("15702f3a12ff8bff357f8c2aa154a17e65b746d5f6b96adc9002c86ee0c15205", forHTTPHeaderField: "X-Server-Id")
            req.setValue("server-fn:0", forHTTPHeaderField: "X-Server-Instance")
        }

        let payload: [String: Any] = [
            "t": ["t": 9, "i": 0, "l": 4, "a": [["t": 1, "s": workspaceID], ["t": 0, "s": year], ["t": 0, "s": month0], ["t": 1, "s": "+08:00"]], "o": 0],
            "f": 31, "m": []
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        req.httpBody = body

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            logger.error("CostCrawler workspace POST failed includeHeader=\(includeServerHeader)")
            return nil
        }
        // If server returns HTML (auth expired / X-Server session gone), parse will return nil and we will retry
        if let mc = parseServerFnCost(text), !mc.daily.isEmpty {
            cacheServerText(text)
            cacheAvailableKeys(mc.keys)
            return mc
        }
        logger.warning("CostCrawler: parseServerFnCost returned nil, likely HTML/auth expired")
        return nil
    }

    private func fetchHARFallback() async -> MonthlyCost? {
        // Intentionally not reading ~/Desktop/opencode.ai.har directly (sandbox deny)
        // Instead, if App has previously persisted the last successful _server text into App Group, try it
        let shared = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
        if let cached = shared?.string(forKey: "lastServerText"), !cached.isEmpty,
           let mc = parseServerFnCost(cached) {
            logger.info("CostCrawler: HAR fallback via cached lastServerText succeeded")
            // 即使是缓存也要同步一次 keys，避免离线时 key 名丢失
            cacheAvailableKeys(mc.keys)
            return mc
        }
        // Legacy: try reading shared auth-triggered HAR JSON only if explicitly cached by App (not file path)
        return nil
    }

    func cacheServerText(_ text: String) {
        UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")?.set(text, forKey: "lastServerText")
    }

    func cacheAvailableKeys(_ keys: [ApiKeyInfo]) {
        guard !keys.isEmpty else { return }
        if let data = try? JSONEncoder().encode(keys) {
            UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")?.set(data, forKey: "availableKeys")
        }
    }

    func loadCachedKeys() -> [ApiKeyInfo] {
        guard let d = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego"),
              let data = d.data(forKey: "availableKeys"),
              let arr = try? JSONDecoder().decode([ApiKeyInfo].self, from: data) else { return [] }
        return arr
    }

    func cachedOrFetchedKeys() async -> [ApiKeyInfo] {
        let cached = loadCachedKeys()
        if !cached.isEmpty { return cached }
        // 尝试从 lastServerText 再解析一次（App 刚安装后可能还未刷新但已有缓存文本）
        if let d = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego"),
           let txt = d.string(forKey: "lastServerText"), !txt.isEmpty {
            let ks = parseKeys(from: txt)
            if !ks.isEmpty { cacheAvailableKeys(ks); return ks }
        }
        // 最后尝试按现有 workspace 再拉一次 _server（失败静默）
        if let ws = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")?.string(forKey: "workspaceID"),
           let auth = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")?.string(forKey: "authCookie"),
           !ws.isEmpty, !auth.isEmpty,
           let mc = await fetchWorkspaceCost(workspaceID: ws, authCookie: auth) {
            if !mc.keys.isEmpty { cacheAvailableKeys(mc.keys); return mc.keys }
        }
        return cached
    }

    func parseServerFnCost(_ text: String) -> MonthlyCost? {
        // text is: ;0x....;((self.$R=...)[{date:"2026-08-18",model:"mimo-v2.5",totalCost:123,keyId:"key_...",...},...] + keys:[{id:"key_...",displayName:"...",deleted:!1}]
        let pattern = #"date:"([^"]+)",model:"([^"]+)",totalCost:(\d+),keyId:"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        var byDate: [String: [String: Double]] = [:]
        var byDateByKey: [String: [String: [String: Double]]] = [:] // keyId -> date -> model->cost
        for m in matches {
            guard m.numberOfRanges == 5,
                  let dRange = Range(m.range(at: 1), in: text),
                  let mRange = Range(m.range(at: 2), in: text),
                  let cRange = Range(m.range(at: 3), in: text),
                  let kRange = Range(m.range(at: 4), in: text) else { continue }
            let date = String(text[dRange])
            let model = String(text[mRange])
            let costStr = String(text[cRange])
            let keyId = String(text[kRange])
            guard let costInt = Int(costStr) else { continue }
            // totalCost is in 1e-8 dollars (verified: 135915701 -> $1.359..., sum 5 days matches tooltip $1.36/$0.69)
            let cost = Double(costInt) / 100_000_000.0
            byDate[date, default: [:]][model, default: 0] += cost
            byDateByKey[keyId, default: [:]][date, default: [:]][model, default: 0] += cost
        }
        guard !byDate.isEmpty else { return nil }
        let daily = byDate.map { DailyCost(date: $0.key, entries: $0.value) }.sorted { $0.date < $1.date }
        var dailyByKey: [String: [DailyCost]] = [:]
        for (k, dict) in byDateByKey {
            dailyByKey[k] = dict.map { DailyCost(date: $0.key, entries: $0.value) }.sorted { $0.date < $1.date }
        }
        let keys = parseKeys(from: text)
        return MonthlyCost(daily: daily, keys: keys, dailyByKey: dailyByKey)
    }

    func parseKeys(from text: String) -> [ApiKeyInfo] {
        // Match keys:[{id:"key_...",displayName:"..."}] plus deleted flag; include deleted=!0 as well but mark
        let pattern = #"id:"(key_[^"]+)",displayName:"([^"]+)",deleted:([^,}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result: [ApiKeyInfo] = []
        for m in matches where m.numberOfRanges == 4 {
            guard let idR = Range(m.range(at: 1), in: text),
                  let nameR = Range(m.range(at: 2), in: text),
                  let delR = Range(m.range(at: 3), in: text) else { continue }
            let name = String(text[nameR])
            // deleted:!1 means deleted=false, deleted:!0 true; skip deleted keys
            let delRaw = String(text[delR]).trimmingCharacters(in: .whitespaces)
            let isDeleted: Bool = {
                if delRaw == "!0" || delRaw == "true" || delRaw == "!0," { return true }
                if delRaw == "!1" || delRaw == "false" { return false }
                return false
            }()
            if isDeleted { continue }
            let id = String(text[idR])
            result.append(ApiKeyInfo(id: id, displayName: name))
        }
        // fallback: if no deleted-aware match but simple id/displayName exists (older payload), parse leniently
        if result.isEmpty {
            let simple = #"id:"(key_[^"]+)",displayName:"([^"]+)""#
            if let r2 = try? NSRegularExpression(pattern: simple) {
                let ms2 = r2.matches(in: text, range: NSRange(location: 0, length: ns.length))
                for m in ms2 where m.numberOfRanges == 3 {
                    guard let idR = Range(m.range(at: 1), in: text), let nameR = Range(m.range(at: 2), in: text) else { continue }
                    result.append(ApiKeyInfo(id: String(text[idR]), displayName: String(text[nameR])))
                }
            }
        }
        // 去重保持原序
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Legacy JSON fallback

    private func tryCostJSON(url: URL, key: String, month: Date) async -> MonthlyCost? {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mc = extractCost(from: json, month: month) else { return nil }
        return mc
    }

    private func extractCost(from json: [String: Any], month: Date) -> MonthlyCost? {
        var found: [String: [String: Double]] = [:]
        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                for (_, v) in dict { walk(v) }
            } else if let arr = obj as? [Any] {
                for e in arr {
                    if let d = e as? [String: Any],
                       let date = d["date"] as? String ?? d["day"] as? String,
                       let model = d["model"] as? String,
                       let cost = d["cost"] as? Double ?? (d["cost"] as? Int).map(Double.init) ?? d["totalCost"] as? Double {
                        found[date, default: [:]][model] = cost
                    }
                    walk(e)
                }
            }
        }
        walk(json)
        guard !found.isEmpty else { return nil }
        let daily = found.map { DailyCost(date: $0.key, entries: $0.value) }.sorted { $0.date < $1.date }
        return MonthlyCost(daily: daily, keys: [], dailyByKey: [:])
    }
}
