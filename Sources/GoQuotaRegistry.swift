import Foundation
import os

enum GoPlan: String, CaseIterable, Identifiable, Codable {
    case go = "go"
    case goPlus = "go-plus"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .go: return "Go"
        case .goPlus: return "Go Plus"
        }
    }

    var shortName: String {
        switch self {
        case .go: return "Go"
        case .goPlus: return "Plus"
        }
    }
}

struct GoQuota: Codable, Equatable, Identifiable {
    var id: String { slug }
    let slug: String // e.g. kimi-k3
    let displayName: String // e.g. Kimi K3
    /// 官方 Console 的估算 5 小时请求数，按套餐分开。
    let requests5hByPlan: [String: Int]
    /// 官方模型的月度 usage 上限（美元），按套餐分开。
    let monthlyUSDByPlan: [String: Double]
    /// 官方促销备注（如 "4x · 9 月 20 日结束"）；旧缓存没有这个字段时解码为 nil
    var note: String? = nil

    /// 行内小标签：优先取备注开头的乘数（4x / 1.5x），拿不到就取前 6 个字符
    var badge: String? {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let head = note.split(separator: " ").first.map(String.init) ?? note
        if head.range(of: #"^[0-9]+(\.[0-9]+)?[xX]$"#, options: .regularExpression) != nil {
            return head.lowercased()
        }
        let lower = note.lowercased()
        if lower.contains("limited regions"), lower.contains("limited time") { return "限区限时" }
        if lower.contains("limited regions") { return "限区" }
        if lower.contains("limited time") { return "限免" }
        return String(note.prefix(6))
    }

    var isUnlimited: Bool {
        requests5hByPlan.isEmpty && monthlyUSDByPlan.isEmpty
    }

    func requests5h(for plan: GoPlan) -> Int? {
        requests5hByPlan[plan.rawValue]
    }

    func monthlyUSD(for plan: GoPlan) -> Double? {
        monthlyUSDByPlan[plan.rawValue]
    }

    func requests5hDisplay(for plan: GoPlan) -> String {
        requests5h(for: plan).map(Self.fmt) ?? "∞"
    }

    func monthlyDisplay(for plan: GoPlan) -> String {
        guard let value = monthlyUSD(for: plan) else { return "∞" }
        return "$" + Self.fmtUSD(value)
    }

    static func fmtUSD(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.minimumFractionDigits = value.rounded() == value ? 0 : 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    static func fmt(_ v: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

/// 实时同步官方 Console：https://opencode.ai/console/go
/// 表内同时包含 Go / Go Plus 的 5 小时估算请求和月度美元额度和。
enum GoQuotaRegistry {
    static let suiteName = PlatformConfig.appGroupID
    // v4（2026-11-18）：官方从 Docs 静态请求表迁到 Console，Go/Go Plus 分额度。
    // 升 key 会一次性撤掉历史缓存，避免 GLM-5.3 继续显示旧 1,080 次。
    static let cacheKey = "go_quotas_json_v4"
    static let cacheDateKey = "go_quotas_date_v4"
    static let ttl: TimeInterval = 6 * 3600

    /// 离线 / 首装快照。联网后由 Console 整表替换。
    static let fallbackQuotas: [GoQuota] = GoQuotaFallback.all

    private static let logger = Logger(subsystem: "com.steve233.opencodego", category: "GoQuota")
    private static let consoleURL = URL(string: "https://opencode.ai/console/go")!

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
        if let q = await fetchFrom(url: consoleURL), !q.isEmpty {
            return q
        }
        logger.warning("GoQuota fetchRemote console failed")
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

    /// 取所有「跨行非贪婪」的捕获组 1（忽略大小写）
    static func rawGroups(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    static func rawMatches(in text: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            (1..<m.numberOfRanges).compactMap { idx in
                guard let r = Range(m.range(at: idx), in: text) else { return nil }
                return String(text[r])
            }
        }
    }

    static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    /// 剥标签 + 解实体 + 收空白
    static func plainText(_ s: String) -> String {
        let stripped = s.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
        return decodeEntities(stripped)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 名字格：第一个 `<br>` 之前是模型名，之后是官方促销备注（如 "4x · 9 月 20 日结束"）
    static func splitNameCell(_ cell: String) -> (name: String, note: String?) {
        var head = cell
        var tail: String?
        if let regex = try? NSRegularExpression(pattern: #"<br\s*/?>"#, options: .caseInsensitive),
           let m = regex.firstMatch(in: cell, range: NSRange(location: 0, length: (cell as NSString).length)),
           let r = Range(m.range, in: cell) {
            head = String(cell[cell.startIndex..<r.lowerBound])
            tail = String(cell[r.upperBound...])
        }
        let note = tail.map { plainText($0) }.flatMap { $0.isEmpty ? nil : $0 }
        return (plainText(head), note)
    }

    /// 数值格：官方做促销时会写 `<del>旧值</del><br><strong>当前值</strong>`，取最后一个 `<strong>` 的当前值
    static func currentValue(_ cell: String) -> String {
        if let regex = try? NSRegularExpression(pattern: #"<strong[^>]*>(.*?)</strong>"#,
                                                options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let ns = cell as NSString
            let ms = regex.matches(in: cell, range: NSRange(location: 0, length: ns.length))
            if let last = ms.last, let r = Range(last.range(at: 1), in: cell) {
                return plainText(String(cell[r]))
            }
        }
        return plainText(cell)
    }

    /// 解析官方 Console（当前真源）或旧 Docs 表（兼容历史 fixture）。
    ///
    /// Console 页面无需登录即可拿到隐藏的全部模型行：
    /// `Model | Relative request allowances | Est. requests / 5 hr | Monthly limit`
    /// 其中请求和月额度都按 `data-plan="go"` / `"go-plus"` 分列。
    static func parse(html: String) -> [GoQuota]? {
        if html.contains("data-allowance-type=\"requests\""), html.contains("data-plan=\"go-plus\"") {
            return parseConsole(html: html)
        }
        return parseLegacyDocs(html: html)
    }

    private static func parseConsole(html: String) -> [GoQuota]? {
        let rowMatches = rawMatches(
            in: html,
            pattern: #"<tr\b[^>]*data-model="([^"]+)"[^>]*>(.*?)</tr>"#
        )
        guard !rowMatches.isEmpty else { return nil }

        func parseInt(_ s: String) -> Int? {
            let t = plainText(s)
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "，", with: "")
                .replacingOccurrences(of: " ", with: "")
            return Int(t)
        }

        func parseUSD(_ s: String) -> Double? {
            let t = plainText(s)
                .replacingOccurrences(of: "$", with: "")
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: " ", with: "")
            return Double(t)
        }

        func planValues(_ cell: String) -> [String: String] {
            var out: [String: String] = [:]
            for pair in rawMatches(
                in: cell,
                pattern: #"data-plan="([^"]+)".*?data-layer="current-value"[^>]*>(.*?)</span>"#
            ) where pair.count >= 2 {
                out[pair[0]] = plainText(pair[1])
            }
            return out
        }

        var result: [GoQuota] = []
        for match in rowMatches where match.count >= 2 {
            let slug = match[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let row = match[1]
            let names = rawMatches(
                in: row,
                pattern: #"data-layer="model-name"[^>]*title="([^"]+)""#
            )
            let displayName = names.first?.first.map(plainText)
                ?? slug.replacingOccurrences(of: "-", with: " ")
            let note = rawGroups(
                in: row,
                pattern: #"data-layer="model-note"[^>]*>(.*?)</span>"#
            ).first.map(plainText).flatMap { $0.isEmpty ? nil : $0 }

            let requestCell = rawGroups(
                in: row,
                pattern: #"<td\b[^>]*data-allowance-type="requests"[^>]*>(.*?)</td>"#
            ).first ?? ""
            let usageCell = rawGroups(
                in: row,
                pattern: #"<td\b[^>]*data-allowance-type="usage"[^>]*>(.*?)</td>"#
            ).first ?? ""

            let requestValues = planValues(requestCell)
            let usageValues = planValues(usageCell)
            var requests: [String: Int] = [:]
            var usd: [String: Double] = [:]
            for plan in GoPlan.allCases {
                if let raw = requestValues[plan.rawValue], let value = parseInt(raw) {
                    requests[plan.rawValue] = value
                }
                if let raw = usageValues[plan.rawValue], let value = parseUSD(raw) {
                    usd[plan.rawValue] = value
                }
            }
            result.append(GoQuota(
                slug: slug,
                displayName: displayName,
                requests5hByPlan: requests,
                monthlyUSDByPlan: usd,
                note: note
            ))
        }

        guard result.count >= 10 else { return nil }
        return result.sorted {
            let l = $0.requests5h(for: .go) ?? Int.max
            let r = $1.requests5h(for: .go) ?? Int.max
            return l == r ? $0.displayName < $1.displayName : l < r
        }
    }

    /// 旧版 Docs 表：Model | 每5小时 | 每周 | 每月。仅为兼容历史 fixture。
    ///
    /// 2026-09-14 事故：官方给 DeepSeek V4.1 Flash 那行加了促销装饰
    /// （名字 `<br><small>4x · 9 月 20 日结束</small>`、数值 `<del>6,500</del><br><strong>26,000</strong>`），
    /// 老实现要求单元格是纯文本（`<td>([^<]+)</td>`）→ 整行匹配失败 → 该行从 widget 列表里消失。
    /// 现在一律「按行取格、剥标签取文本」：名字丢掉 `<br>` 之后的备注，数值取 `<strong>` 的当前值，
    /// 并把备注写进 `note` 供界面显示促销标记。
    private static func parseLegacyDocs(html: String) -> [GoQuota]? {
        let rows = rawGroups(in: html, pattern: #"<tr[^>]*>(.*?)</tr>"#)
        guard !rows.isEmpty else { return nil }

        // 免费/不限量官方换过好几种写法：-, 限免, 限时免费, 无限, 无限制(2026-09-17 Union Alpha Free), 不限, free
        let freeTokens: Set<String> = ["-", "—", "", "限免", "免费", "无限", "无限制", "不限", "不限量",
                                       "∞", "不计配额", "限时免费", "限时免费不计配额", "free", "unlimited"]
        func parseInt(_ s: String) -> Int? {
            let t = s.replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "，", with: "")
                .replacingOccurrences(of: " ", with: "")
                .trimmingCharacters(in: .whitespaces)
            if t == "-" || t == "—" || t.isEmpty { return nil }
            return Int(t)
        }
        func isQuotaCell(_ s: String) -> Bool {
            parseInt(s) != nil || freeTokens.contains(s.trimmingCharacters(in: .whitespaces).lowercased())
        }

        var result: [GoQuota] = []
        for row in rows {
            let cells = rawGroups(in: row, pattern: #"<td[^>]*>(.*?)</td>"#)
            guard cells.count == 4 else { continue }
            let (name, note) = splitNameCell(cells[0])
            if name.isEmpty || name.lowercased() == "model" || name.contains("模型") { continue }

            let h5s = currentValue(cells[1])
            let ws = currentValue(cells[2])
            let ms = currentValue(cells[3])
            // 价格表行带 $；「模型 / id / Base URL / SDK」清单表后两格不是数字 → 都排除
            if h5s.contains("$") || ws.contains("$") || ms.contains("$") { continue }
            guard isQuotaCell(h5s), isQuotaCell(ws) else { continue }

            var requests: [String: Int] = [:]
            if let value = parseInt(h5s) { requests[GoPlan.go.rawValue] = value }
            let quota = GoQuota(
                slug: normalize(name),
                displayName: name,
                requests5hByPlan: requests,
                monthlyUSDByPlan: [:],
                note: note
            )
            if result.contains(where: { $0.slug == quota.slug }) { continue }
            result.append(quota)
            if result.count >= 40 { break }
        }
        // 需至少 10 行才认为成功，避免误抓小表；不足就返回 nil，调用方继续用缓存
        guard result.count >= 10 else { return nil }
        return result.sorted {
            ($0.requests5h(for: .go) ?? Int.max) < ($1.requests5h(for: .go) ?? Int.max)
        }
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
        // 显示名跟网关真实 id 不一致的在这里对齐：文档写 "Union Alpha Free"，网关 id 是 `union-alpha`
        // （猜成 union-alpha-free 会 401 Model not supported，models.dev 里也没有这条可校正）
        if let alias = slugAliases[s] { return alias }
        return s
    }

    /// 显示名归一后 ≠ 网关真实 id 的对照表
    static let slugAliases: [String: String] = [
        "crouton-alpha-free": "crouton-alpha-free",
        "longcat-2.5-preview-free": "longcat-2.5-free",
        "union-alpha-free": "union-alpha",
    ]

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
