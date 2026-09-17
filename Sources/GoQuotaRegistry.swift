import Foundation
import os

struct GoQuota: Codable, Equatable, Identifiable {
    var id: String { slug }
    let slug: String // e.g. kimi-k3
    let displayName: String // e.g. Kimi K3
    let h5: Int?
    let weekly: Int?
    let monthly: Int?
    /// 官方促销备注（如 "4x · 9 月 20 日结束"）；旧缓存没有这个字段时解码为 nil
    var note: String? = nil

    /// 行内小标签：优先取备注开头的乘数（4x / 1.5x），拿不到就取前 6 个字符
    var badge: String? {
        guard let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let head = note.split(separator: " ").first.map(String.init) ?? note
        if head.range(of: #"^[0-9]+(\.[0-9]+)?[xX]$"#, options: .regularExpression) != nil {
            return head.lowercased()
        }
        return String(note.prefix(6))
    }

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
    // v2（2026-09-14）：解析器从「纯文本单元格」改成「剥标签 + 取 <strong> 当前值」，
    // 缓存键一并升级，否则升级后 12h TTL 内还会继续显示缺 V4.1 Flash 的旧列表。
    // v3（2026-09-17）：免费行判定加上「无限制」（Union Alpha Free 三格都写这个），
    // 不升 key 的话 12h 内还会继续显示缺 Union 的 v2 缓存。
    static let cacheKey = "go_quotas_json_v3"
    static let cacheDateKey = "go_quotas_date_v3"
    static let ttl: TimeInterval = 12 * 3600 // 文档日更，12h 足够及时

    /// 兜底名单（离线 / 首装用）：2026-09-17 从实时配额表整表刷新，28 行含
    /// `deepseek-v4.1-flash`（4x 促销当前值 26,000/65,000/130,000 + 备注）。
    /// 限时免费那行 9 月已由 `union-alpha` 接手：`ox-alpha-free` 2026-08-28 从 Go 下架（直连 401），
    /// 它的亮绿配色留给 Union，旧配色只在历史费用里还认得出（见 ModelPalette）。
    static let fallbackQuotas: [GoQuota] = [
        GoQuota(slug: "kimi-k3", displayName: "Kimi K3", h5: 110, weekly: 250, monthly: 490),
        GoQuota(slug: "qwen3.8-max", displayName: "Qwen3.8 Max", h5: 160, weekly: 400, monthly: 810),
        GoQuota(slug: "grok-4.6", displayName: "Grok 4.6", h5: 169, weekly: 423, monthly: 845),
        GoQuota(slug: "qwen3.7-max", displayName: "Qwen3.7 Max", h5: 170, weekly: 420, monthly: 840),
        GoQuota(slug: "glm-5.3", displayName: "GLM-5.3", h5: 220, weekly: 540, monthly: 1080),
        GoQuota(slug: "glm-5.2", displayName: "GLM-5.2", h5: 880, weekly: 2150, monthly: 4300),
        GoQuota(slug: "glm-5.1", displayName: "GLM-5.1", h5: 880, weekly: 2150, monthly: 4300),
        GoQuota(slug: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", h5: 1050, weekly: 2600, monthly: 5200),
        GoQuota(slug: "kimi-k2.6", displayName: "Kimi K2.6", h5: 1150, weekly: 2880, monthly: 5750),
        GoQuota(slug: "kimi-k2.7-code", displayName: "Kimi K2.7 Code", h5: 1350, weekly: 3380, monthly: 6750),
        GoQuota(slug: "hy4-preview", displayName: "Hy4 preview", h5: 1350, weekly: 3380, monthly: 6770),
        GoQuota(slug: "gpt-5.6-luna", displayName: "GPT 5.6 Luna", h5: 2050, weekly: 5100, monthly: 10250),
        GoQuota(slug: "minimax-m3", displayName: "MiniMax M3", h5: 3200, weekly: 8000, monthly: 16000),
        GoQuota(slug: "mimo-v2.5-pro", displayName: "MiMo-V2.5-Pro", h5: 3250, weekly: 8150, monthly: 16300),
        GoQuota(slug: "qwen3.6-plus", displayName: "Qwen3.6 Plus", h5: 3300, weekly: 8200, monthly: 16300),
        GoQuota(slug: "minimax-m2.7", displayName: "MiniMax M2.7", h5: 3400, weekly: 8500, monthly: 17000),
        GoQuota(slug: "hy3", displayName: "Hy3", h5: 4300, weekly: 10750, monthly: 21500),
        GoQuota(slug: "qwen3.7-plus", displayName: "Qwen3.7 Plus", h5: 4300, weekly: 10800, monthly: 21600),
        GoQuota(slug: "qwen3.8-flash", displayName: "Qwen3.8 Flash", h5: 5400, weekly: 13500, monthly: 27000),
        GoQuota(slug: "glm-5.3-flash", displayName: "GLM-5.3-Flash", h5: 6320, weekly: 15790, monthly: 31580),
        GoQuota(slug: "deepseek-v4-flash-vision-exp", displayName: "DeepSeek V4 Flash Vision Exp", h5: 6500, weekly: 16250, monthly: 32500),
        GoQuota(slug: "longcat-2.0", displayName: "LongCat-2.0", h5: 11400, weekly: 28600, monthly: 57200),
        GoQuota(slug: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash", h5: 13000, weekly: 32500, monthly: 65000),
        GoQuota(slug: "deepseek-v4.1-flash", displayName: "DeepSeek V4.1 Flash", h5: 26000, weekly: 65000, monthly: 130000, note: "4x · 9 月 20 日结束"),
        GoQuota(slug: "mimo-v2.5", displayName: "MiMo-V2.5", h5: 30100, weekly: 75200, monthly: 150400),
        GoQuota(slug: "muse-spark-1.3-contributor", displayName: "Muse Spark 1.3 Contributor", h5: 45300, weekly: 113300, monthly: 226600),
        GoQuota(slug: "muse-spark-1.2-contributor", displayName: "Muse Spark 1.2 Contributor", h5: 45300, weekly: 113300, monthly: 226600),
        GoQuota(slug: "union-alpha", displayName: "Union Alpha Free", h5: nil, weekly: nil, monthly: nil, note: "限时"),
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

    /// 解析文档配额表：Model | 每5小时 | 每周 | 每月
    ///
    /// 2026-09-14 事故：官方给 DeepSeek V4.1 Flash 那行加了促销装饰
    /// （名字 `<br><small>4x · 9 月 20 日结束</small>`、数值 `<del>6,500</del><br><strong>26,000</strong>`），
    /// 老实现要求单元格是纯文本（`<td>([^<]+)</td>`）→ 整行匹配失败 → 该行从 widget 列表里消失。
    /// 现在一律「按行取格、剥标签取文本」：名字丢掉 `<br>` 之后的备注，数值取 `<strong>` 的当前值，
    /// 并把备注写进 `note` 供界面显示促销标记。
    static func parse(html: String) -> [GoQuota]? {
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

            let quota = GoQuota(slug: normalize(name), displayName: name,
                                h5: parseInt(h5s), weekly: parseInt(ws), monthly: parseInt(ms), note: note)
            if result.contains(where: { $0.slug == quota.slug }) { continue }
            result.append(quota)
            if result.count >= 40 { break }
        }
        // 需至少 10 行才认为成功，避免误抓小表；不足就返回 nil，调用方继续用缓存
        guard result.count >= 10 else { return nil }
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
        // 显示名跟网关真实 id 不一致的在这里对齐：文档写 "Union Alpha Free"，网关 id 是 `union-alpha`
        // （猜成 union-alpha-free 会 401 Model not supported，models.dev 里也没有这条可校正）
        if let alias = slugAliases[s] { return alias }
        return s
    }

    /// 显示名归一后 ≠ 网关真实 id 的对照表
    static let slugAliases: [String: String] = [
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
