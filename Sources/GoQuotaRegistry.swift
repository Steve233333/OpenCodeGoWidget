import Foundation
import os

struct GoQuota: Codable, Equatable, Identifiable {
    var id: String { slug }
    let slug: String // e.g. kimi-k3
    let displayName: String // e.g. Kimi K3
    let h5: Int?
    let weekly: Int?
    let monthly: Int?

    var h5Display: String { h5.map { Self.fmt($0) } ?? "-" }
    var weeklyDisplay: String { weekly.map { Self.fmt($0) } ?? "-" }
    var monthlyDisplay: String { monthly.map { Self.fmt($0) } ?? "-" }

    static func fmt(_ v: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

/// 实时同步文档配额表：https://opencode.ai/docs/zh-cn/go/ 表 Model | 每5小时 | 每周 | 每月
enum GoQuotaRegistry {
    static let suiteName = "2DC432GLL2.com.steve233.opencodego"
    static let cacheKey = "go_quotas_json"
    static let cacheDateKey = "go_quotas_date"
    static let ttl: TimeInterval = 12 * 3600 // 文档日更，12h 足够及时

    static let fallbackQuotas: [GoQuota] = [
        GoQuota(slug: "grok-4.5", displayName: "Grok 4.5", h5: 120, weekly: 300, monthly: 600),
        GoQuota(slug: "gpt-5.6-luna", displayName: "GPT 5.6 Luna", h5: 2050, weekly: 5100, monthly: 10250),
        GoQuota(slug: "glm-5.3", displayName: "GLM-5.3", h5: 220, weekly: 540, monthly: 1080),
        GoQuota(slug: "glm-5.2", displayName: "GLM-5.2", h5: 880, weekly: 2150, monthly: 4300),
        GoQuota(slug: "glm-5.1", displayName: "GLM-5.1", h5: 880, weekly: 2150, monthly: 4300),
        GoQuota(slug: "kimi-k3", displayName: "Kimi K3", h5: 110, weekly: 250, monthly: 490),
        GoQuota(slug: "kimi-k2.7-code", displayName: "Kimi K2.7 Code", h5: 1350, weekly: 3380, monthly: 6750),
        GoQuota(slug: "kimi-k2.6", displayName: "Kimi K2.6", h5: 1150, weekly: 2880, monthly: 5750),
        GoQuota(slug: "mimo-v2.5", displayName: "MiMo-V2.5", h5: 30100, weekly: 75200, monthly: 150400),
        GoQuota(slug: "mimo-v2.5-pro", displayName: "MiMo-V2.5-Pro", h5: 3250, weekly: 8150, monthly: 16300),
        GoQuota(slug: "minimax-m3", displayName: "MiniMax M3", h5: 3200, weekly: 8000, monthly: 16000),
        GoQuota(slug: "minimax-m2.7", displayName: "MiniMax M2.7", h5: 3400, weekly: 8500, monthly: 17000),
        GoQuota(slug: "muse-spark-1.2-contributor", displayName: "Muse Spark 1.2 Contributor", h5: 45300, weekly: 113300, monthly: 226600),
        GoQuota(slug: "muse-spark-1.3-contributor", displayName: "Muse Spark 1.3 Contributor", h5: 45300, weekly: 113300, monthly: 226600),
        GoQuota(slug: "qwen3.8-max", displayName: "Qwen3.8 Max", h5: 160, weekly: 400, monthly: 810),
        GoQuota(slug: "qwen3.7-max", displayName: "Qwen3.7 Max", h5: 340, weekly: 840, monthly: 1690),
        GoQuota(slug: "qwen3.7-plus", displayName: "Qwen3.7 Plus", h5: 4300, weekly: 10800, monthly: 21600),
        GoQuota(slug: "qwen3.6-plus", displayName: "Qwen3.6 Plus", h5: 3300, weekly: 8200, monthly: 16300),
        GoQuota(slug: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", h5: 1050, weekly: 2600, monthly: 5200),
        GoQuota(slug: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash", h5: 7600, weekly: 18900, monthly: 37800),
        GoQuota(slug: "deepseek-v4-flash-vision-exp", displayName: "DeepSeek V4 Flash Vision Exp", h5: 3800, weekly: 9450, monthly: 18900),
        GoQuota(slug: "hy3", displayName: "Hy3", h5: 4300, weekly: 10750, monthly: 21500),
        GoQuota(slug: "ox-alpha-free", displayName: "Ox Alpha Free", h5: nil, weekly: nil, monthly: nil),
    ]

    private static let logger = Logger(subsystem: "com.steve233.opencodego", category: "GoQuota")
    private static let cnURL = URL(string: "https://opencode.ai/docs/zh-cn/go/")!
    private static let enURL = URL(string: "https://opencode.ai/docs/go/")!

    // MARK: Cache

    static func cachedSync() -> [GoQuota] {
        guard let d = UserDefaults(suiteName: suiteName),
              let data = d.data(forKey: cacheKey),
              let arr = try? JSONDecoder().decode([GoQuota].self, from: data), !arr.isEmpty else {
            return fallbackQuotas
        }
        return arr
    }

    static func cachedDate() -> Date? {
        UserDefaults(suiteName: suiteName)?.object(forKey: cacheDateKey) as? Date
    }

    static func save(_ quotas: [GoQuota]) {
        guard !quotas.isEmpty else { return }
        if let data = try? JSONEncoder().encode(quotas) {
            let d = UserDefaults(suiteName: suiteName)
            d?.set(data, forKey: cacheKey)
            d?.set(Date(), forKey: cacheDateKey)
            d?.synchronize()
            logger.info("GoQuota cached \(quotas.count) rows")
        }
    }

    // MARK: Remote

    static func fetchRemote() async -> [GoQuota]? {
        let urls = [cnURL, enURL]
        for url in urls {
            if let q = await fetchFrom(url: url), !q.isEmpty {
                return q
            }
        }
        logger.warning("GoQuota fetchRemote both cn/en failed")
        return nil
    }

    private static func fetchFrom(url: URL) async -> [GoQuota]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parse(html: html)
    }

    static func parse(html: String) -> [GoQuota]? {
        // 匹配 <tr><td>Model</td><td>h5</td><td>weekly</td><td>monthly</td></tr>
        let pattern = #"<tr>\s*<td>([^<]+)</td>\s*<td>([^<]+)</td>\s*<td>([^<]+)</td>\s*<td>([^<]+)</td>\s*</tr>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        var result: [GoQuota] = []
        for m in matches where m.numberOfRanges == 5 {
            guard let r1 = Range(m.range(at: 1), in: html),
                  let r2 = Range(m.range(at: 2), in: html),
                  let r3 = Range(m.range(at: 3), in: html),
                  let r4 = Range(m.range(at: 4), in: html) else { continue }
            let name = String(html[r1]).trimmingCharacters(in: .whitespacesAndNewlines)
            // 表头行 "Model" 跳过
            if name.lowercased() == "model" || name.contains("模型") { continue }
            let h5s = String(html[r2]).trimmingCharacters(in: .whitespacesAndNewlines)
            let ws = String(html[r3]).trimmingCharacters(in: .whitespacesAndNewlines)
            let ms = String(html[r4]).trimmingCharacters(in: .whitespacesAndNewlines)
            let slug = normalize(name)
            // 仅保留 Go 配额表行：需至少一列为数字或 "-"，且 name 匹配已知模型或含字母
            // 过滤掉其他表（如价格表）可通过检查 h5s 是否为数字/ - 且 weekly 同理
            func parseInt(_ s: String) -> Int? {
                let t = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
                if t == "-" || t == "—" || t.isEmpty { return nil }
                return Int(t)
            }
            // 若三列全为价格/货币等含 $ 则跳过（价格表）
            if h5s.contains("$") || ws.contains("$") || ms.contains("$") { continue }
            // 若三列均为纯数字/ - 视为配额表行
            let isQuotaRow = (Int(h5s.replacingOccurrences(of: ",", with: "")) != nil || h5s == "-") &&
                             (Int(ws.replacingOccurrences(of: ",", with: "")) != nil || ws == "-")
            if !isQuotaRow && !name.contains(" ") && !name.contains("-") { continue }

            let quota = GoQuota(slug: slug, displayName: name, h5: parseInt(h5s), weekly: parseInt(ws), monthly: parseInt(ms))
            // 去重
            if result.contains(where: { $0.slug == quota.slug }) { continue }
            result.append(quota)
            if result.count >= 30 { break }
        }
        // 需至少 10 行才认为成功，避免误抓小表
        guard result.count >= 10 else { return nil }
        // 按 h5 升序便于与截图一致
        return result.sorted { ($0.h5 ?? Int.max) < ($1.h5 ?? Int.max) }
    }

    static func normalize(_ display: String) -> String {
        var s = display.lowercased()
        s = s.replacingOccurrences(of: " ", with: "-")
        s = s.replacingOccurrences(of: "_", with: "-")
        s = s.replacingOccurrences(of: "--", with: "-")
        // 保留点号如 qwen3.8-max
        // 去掉括号备注
        if let r = s.range(of: "(") { s = String(s[..<r.lowerBound]) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s
    }

    @discardableResult
    static func refreshIfNeeded(force: Bool = false) async -> [GoQuota] {
        let now = Date()
        let cached = cachedSync()
        let hasCache = UserDefaults(suiteName: suiteName)?.data(forKey: cacheKey) != nil
        let date = cachedDate()
        let stale = date == nil || now.timeIntervalSince(date!) >= ttl
        if !force, hasCache, !stale {
            return cached
        }
        if let remote = await fetchRemote(), !remote.isEmpty {
            save(remote)
            return remote
        }
        return cached
    }
}
