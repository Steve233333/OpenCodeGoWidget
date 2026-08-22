import Foundation
import os

struct DailyCost: Codable, Equatable {
    let date: String // YYYY-MM-DD
    let entries: [String: Double]
    var total: Double { entries.values.reduce(0, +) }
}

struct MonthlyCost: Equatable {
    let daily: [DailyCost]
    var total: Double { daily.reduce(0) { $0 + $1.total } }
    // Today's entries
    var todayEntries: [String: Double] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        // Try to match today's date string; fallback to last day
        let todayStr = fmt.string(from: today)
        if let d = daily.first(where: { $0.date == todayStr }) { return d.entries }
        return daily.last?.entries ?? [:]
    }
}

final class CostCrawler: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.steve233.opencodego", category: "CostCrawler")
    static let shared = CostCrawler()

    func fetchMonthlyCosts(for month: Date = Date()) async -> MonthlyCost? {
        guard let key = KeychainStore.resolvedKey(), !key.isEmpty else { return nil }
        // 1. Try JSON endpoints first
        for path in ["zen/go/v1/cost", "zen/go/v1/costs", "zen/go/v1/dashboard", "zen/go/v1/usage/cost", "api/cost"] {
            if let url = URL(string: "https://opencode.ai/\(path)"),
               let mc = await tryCostJSON(url: url, key: key, month: month) {
                logger.info("CostCrawler JSON hit \(path)")
                return mc
            }
        }
        // 2. Try HTML hydration
        if let html = await fetchHTML(urlString: "https://opencode.ai/zen", key: key),
           let mc = parseCostFromHTML(html, month: month) {
            logger.info("CostCrawler HTML hit")
            return mc
        }
        // 3. Also try /zen/go with Bearer (may 404, but keep)
        if let html = await fetchHTML(urlString: "https://opencode.ai/zen/go", key: key),
           let mc = parseCostFromHTML(html, month: month) {
            return mc
        }
        return nil
    }

    private func tryCostJSON(url: URL, key: String, month: Date) async -> MonthlyCost? {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        // Append month query if endpoint supports it
        if url.absoluteString.contains("cost") || url.absoluteString.contains("dashboard") {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM"
            fmt.timeZone = TimeZone(identifier: "UTC")
            comps?.queryItems = [URLQueryItem(name: "from", value: fmt.string(from: month) + "-01")]
            if let u = comps?.url { req.url = u }
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mc = extractCost(from: json, month: month) else { return nil }
        return mc
    }

    private func fetchHTML(urlString: String, key: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return html
    }

    private func parseCostFromHTML(_ html: String, month: Date) -> MonthlyCost? {
        // Try to find __NEXT_DATA__ JSON
        if let range = html.range(of: #"id="__NEXT_DATA__" type="application/json">"#),
           let start = html[range.upperBound...].firstIndex(of: ">"),
           let end = html[range.upperBound...].range(of: "</script>") {
            // This is simplified; real __NEXT_DATA__ is large JSON
            let jsonStr = String(html[html.index(after: start)..<end.lowerBound])
            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mc = extractCost(from: json, month: month) {
                return mc
            }
        }
        // Also try to find $R hydration arrays
        // Fallback: search for any JSON with model names
        return nil
    }

    private func extractCost(from json: [String: Any], month: Date) -> MonthlyCost? {
        var found: [String: [String: Double]] = [:] // date -> model -> cost
        func walk(_ obj: Any) {
            if let dict = obj as? [String: Any] {
                // Look for arrays of {date, model, cost} or {model, cost}
                for (_, v) in dict {
                    walk(v)
                }
            } else if let arr = obj as? [Any] {
                // Check if array looks like daily costs
                for e in arr {
                    if let d = e as? [String: Any],
                       let date = d["date"] as? String ?? d["day"] as? String,
                       let model = d["model"] as? String ?? d["model_id"] as? String,
                       let cost = d["cost"] as? Double ?? (d["cost"] as? Int).map(Double.init) ?? d["amount"] as? Double {
                        found[date, default: [:]][model] = cost
                    } else if let d = e as? [String: Any] {
                        // Also check nested
                        walk(d)
                    }
                }
            }
        }
        walk(json)
        guard !found.isEmpty else { return nil }
        let daily = found.map { DailyCost(date: $0.key, entries: $0.value) }.sorted { $0.date < $1.date }
        return MonthlyCost(daily: daily)
    }
}
