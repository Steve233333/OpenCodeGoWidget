import Foundation
import os

struct DailyCost: Codable, Equatable {
    let date: String // YYYY-MM-DD
    var entries: [String: Double]
    var total: Double { entries.values.reduce(0, +) }
}

struct MonthlyCost: Equatable {
    let daily: [DailyCost]
    var total: Double { daily.reduce(0) { $0 + $1.total } }
    var todayEntries: [String: Double] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let todayStr = fmt.string(from: today)
        if let d = daily.first(where: { $0.date == todayStr }) { return d.entries }
        return daily.last?.entries ?? [:]
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
            return mc
        }
        // Legacy: try reading shared auth-triggered HAR JSON only if explicitly cached by App (not file path)
        return nil
    }

    func cacheServerText(_ text: String) {
        UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")?.set(text, forKey: "lastServerText")
    }

    func parseServerFnCost(_ text: String) -> MonthlyCost? {
        // text is: ;0x....;((self.$R=...)[{date:"2026-08-18",model:"mimo-v2.5",totalCost:123,...},...]
        let pattern = #"date:"([^"]+)",model:"([^"]+)",totalCost:(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        var byDate: [String: [String: Double]] = [:]
        for m in matches {
            guard m.numberOfRanges == 4,
                  let dRange = Range(m.range(at: 1), in: text),
                  let mRange = Range(m.range(at: 2), in: text),
                  let cRange = Range(m.range(at: 3), in: text) else { continue }
            let date = String(text[dRange])
            let model = String(text[mRange])
            let costStr = String(text[cRange])
            guard let costInt = Int(costStr) else { continue }
            // totalCost is in 1e-8 dollars (verified: 135915701 -> $1.359..., sum 5 days matches tooltip $1.36/$0.69)
            let cost = Double(costInt) / 100_000_000.0
            byDate[date, default: [:]][model, default: 0] += cost
        }
        guard !byDate.isEmpty else { return nil }
        let daily = byDate.map { DailyCost(date: $0.key, entries: $0.value) }.sorted { $0.date < $1.date }
        return MonthlyCost(daily: daily)
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
        return MonthlyCost(daily: daily)
    }
}
