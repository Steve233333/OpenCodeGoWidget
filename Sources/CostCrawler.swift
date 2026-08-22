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

    // MARK: - Workspace HAR-based crawler (Cookie + workspaceID)

    private func fetchViaWorkspace() async -> MonthlyCost? {
        // 1. Try App Group shared prefs (user filled in Settings window)
        let shared = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
        var workspaceID: String? = shared?.string(forKey: "workspaceID")
        var authCookie: String? = shared?.string(forKey: "authCookie")
        if let w = workspaceID, !w.isEmpty, let a = authCookie, !a.isEmpty {
            if let mc = await fetchWorkspaceCost(workspaceID: w, authCookie: a) { return mc }
        }

        // 2. Try HAR on Desktop (user exported via Safari)
        let harPath = NSString(string: "~/Desktop/opencode.ai.har").expandingTildeInPath
        if workspaceID == nil || authCookie == nil {
            if let harData = try? Data(contentsOf: URL(fileURLWithPath: harPath)),
               let har = try? JSONSerialization.jsonObject(with: harData) as? [String: Any],
               let log = har["log"] as? [String: Any],
               let entries = log["entries"] as? [[String: Any]] {
                for e in entries {
                    if let req = e["request"] as? [String: Any],
                       let cookies = req["cookies"] as? [[String: Any]] {
                        for c in cookies where (c["name"] as? String) == "auth" {
                            if let v = c["value"] as? String, !v.isEmpty { authCookie = v }
                        }
                    }
                    if let req = e["request"] as? [String: Any], let url = req["url"] as? String, url.contains("/workspace/") {
                        if let m = url.range(of: "/workspace/") {
                            let rest = String(url[m.upperBound...])
                            let id = rest.split(separator: "/").first.map(String.init)
                            if let id = id, id.hasPrefix("wrk_") { workspaceID = id }
                        }
                    }
                }
            }
        }

        // 2. Fallback: try to find workspaceID in opencode config dir (if user had config.json with cookie)
        if workspaceID == nil {
            let candidates = [
                NSString(string: "~/Desktop/opencode-go-widget-ref/config.json").expandingTildeInPath,
                NSString(string: "~/Desktop/opencode.ai.har").expandingTildeInPath
            ]
            for p in candidates {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: p)),
                   let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ws = j["workspaceID"] as? String, ws.hasPrefix("wrk_") {
                    workspaceID = ws
                    if authCookie == nil, let c = j["cookie"] as? String {
                        // cookie is "auth=Fe26...."
                        if c.contains("auth="), let m = c.range(of: "auth=") {
                            authCookie = String(c[m.upperBound...]).split(separator: ";").first.map(String.init) ?? c
                        } else {
                            authCookie = c
                        }
                    }
                }
            }
        }

        guard let ws = workspaceID, let auth = authCookie else {
            logger.info("CostCrawler: no workspaceID/auth in HAR, fallback to JSON")
            return nil
        }

        return await fetchWorkspaceCost(workspaceID: ws, authCookie: auth)
    }

    private func fetchWorkspaceCost(workspaceID: String, authCookie: String) async -> MonthlyCost? {
        let cal = Calendar.current
        let now = Date()
        // Fetch current month (server expects 0-based month)
        var comps = cal.dateComponents(in: TimeZone(identifier: "Asia/Shanghai")!, from: now)
        let year = comps.year ?? 2026
        let month0 = (comps.month ?? 8) - 1

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
        req.setValue("15702f3a12ff8bff357f8c2aa154a17e65b746d5f6b96adc9002c86ee0c15205", forHTTPHeaderField: "X-Server-Id")
        req.setValue("server-fn:0", forHTTPHeaderField: "X-Server-Instance")

        let payload: [String: Any] = [
            "t": ["t": 9, "i": 0, "l": 4, "a": [["t": 1, "s": workspaceID], ["t": 0, "s": year], ["t": 0, "s": month0], ["t": 1, "s": "+08:00"]], "o": 0],
            "f": 31, "m": []
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        req.httpBody = body

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            logger.error("CostCrawler workspace POST failed")
            return nil
        }

        return parseServerFnCost(text)
    }

    private func parseServerFnCost(_ text: String) -> MonthlyCost? {
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
            // totalCost is in micro-dollars? Divide by 1e6 for display, but keep raw for chart scaling
            let cost = Double(costInt) / 1_000_000.0
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
