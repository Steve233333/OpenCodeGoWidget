import Foundation
import os

/// 控制台用量 API 的**网络 / 游标 / 解析**层（2026-09-23 Phase 1 从 CostCrawler.swift 拆出）。
///
/// 这里只负责"怎么把数据从 opencode.ai 拿下来、切成 [模型]/[Key] 的美元金额"：
///   * `usage/rows` 的分页游标（官方 100 条/页、TTFB 4~6s，靠**自造 keyset 游标**按时间窗并行提速）；
///   * 官方增量参数 `since=<ISO8601>`；
///   * 防御式解析（`cost-by-day` 的微美分、rows 的 model/serviceApiKeyId 聚合）。
/// 合并规则不在这里 —— 全部在 `UsageMerge`（唯一真源）。
extension CostCrawler {

    // MARK: - 2026-09-19 提速：合成游标 + 按时间窗并行
    //
    // 新控制台只有 `usage/rows` 带 per-row 费用，而它 **100 条/页封顶**、每次请求服务端要
    // 4–6s 才吐第一个字节（实测 TTFB）。30 天 ≈ 1.7 万条 = 170 页，串行翻要 17 分钟以上
    // —— 这就是"官网改版后慢得要命"的直接原因（老接口 /_server 一次请求给整月）。
    //
    // 但游标不是服务端会话，它只是 base64({"createdAt":"…","id":N}) 的 keyset 游标，
    // 所以可以**自己造游标直接跳到任意时刻**，按天/按小时切片并行抓。

    /// 造一个 keyset 游标：`{"createdAt": ISO8601, "id": N}`（取 id 上限即可定位到该时刻之前）
    static func syntheticCursor(date: Date, id: Int = 9_000_000_000) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload = "{\"createdAt\":\"\(f.string(from: date))\",\"id\":\(id)}"
        return Data(payload.utf8).base64EncodedString()
    }

    /// rows 里的 createdAt（带毫秒的 ISO8601）→ Date
    static func rowDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        return f2.date(from: s)
    }

    /// 抓 [start, end) 这个时间窗的 rows：用合成游标跳到 end，再往前翻直到跨过 start。
    func consoleRowsInWindow(cookie: String, ws: String, start: Date, end: Date,
                                     maxPages: Int = 120) async -> (rows: [[String: Any]], ok: Bool) {
        var out: [[String: Any]] = []
        var ok = true
        var cursor: String? = Self.syntheticCursor(date: end)
        for _ in 0..<maxPages {
            var page: (items: [[String: Any]], next: String?, status: Int)?
            for attempt in 0..<3 {
                page = await consoleRowsPage(cookie: cookie, ws: ws, range: "30d", cursor: cursor)
                if page?.status == 200 { break }
                page = nil
                if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(1_200_000_000) * UInt64(attempt + 1)) }
            }
            guard let p = page else { ok = false; break }   // 这一窗拉不动就算了，别拖垮整轮
            var sawOlder = false
            for it in p.items {
                guard let s = it["createdAt"] as? String, let d = Self.rowDate(s) else { continue }
                if d >= start && d < end { out.append(it) } else if d < start { sawOlder = true }
            }
            guard let n = p.next, !n.isEmpty, !sawOlder else { break }
            cursor = n
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return (out, ok)
    }

    /// 官方支持的**增量**抓取：`rows?range=all&since=<ISO8601>`（实测到 since 边界就停）。
    /// 比"最近 24h 窗口"便宜得多：正常情况下一次刷新只要 1~2 页。
    func consoleRowsSince(cookie: String, ws: String, since: Date) async -> [[String: Any]] {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sinceStr = f.string(from: since)
        var out: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<200 {              // 200 页 = 2 万条，正常远小于此
            var page: (items: [[String: Any]], next: String?, status: Int)?
            for attempt in 0..<3 {
                page = await consoleRowsPage(cookie: cookie, ws: ws, range: "all", cursor: cursor, since: sinceStr)
                if page?.status == 200 { break }
                page = nil
                if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64(1_200_000_000) * UInt64(attempt + 1)) }
            }
            guard let p = page else { break }
            out += p.items
            guard let n = p.next, !n.isEmpty else { break }
            cursor = n
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return out
    }

    /// 多个时间窗并行抓（窗口内部顺序翻页，窗口之间并发 4 个）。
    /// 每个窗口抓完就把结果交给 onBatch，方便边抓边落盘（进度条能看到）。
    func consoleRowsInWindows(_ windows: [(start: Date, end: Date)], cookie: String, ws: String,
                                      concurrency: Int = 4,
                                      onBatch: ([[String: Any]], Bool) -> Void) async {
        var idx = 0
        while idx < windows.count {
            let slice = Array(windows[idx..<min(idx + concurrency, windows.count)])
            idx += slice.count
            await withTaskGroup(of: (rows: [[String: Any]], ok: Bool).self) { group in
                for w in slice {
                    group.addTask { await self.consoleRowsInWindow(cookie: cookie, ws: ws, start: w.start, end: w.end) }
                }
                var rows: [[String: Any]] = []
                var allOK = true
                for await r in group {
                    rows += r.rows
                    if !r.ok { allOK = false }
                }
                onBatch(rows, allOK)
            }
        }
    }

    /// 单页 usage/rows（返回 items + nextCursor + HTTP 状态；status=0 表示传输层失败/超时）
    func consoleRowsPage(cookie: String, ws: String, range: String,
                                 cursor: String?, since: String? = nil) async -> (items: [[String: Any]], next: String?, status: Int) {
        var comps = URLComponents(string: "https://opencode.ai/console/api/usage/rows")!
        var query = [URLQueryItem(name: "range", value: range), URLQueryItem(name: "pageSize", value: "100")]
        if let c = cursor, !c.isEmpty { query.append(URLQueryItem(name: "cursor", value: c)) }
        // 2026-09-22：官方支持 since=<ISO8601>，到边界就停（实测 since=05:00 → 108 条即止）
        if let s = since, !s.isEmpty { query.append(URLQueryItem(name: "since", value: s)) }
        comps.queryItems = query
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 25
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(ws, forHTTPHeaderField: "x-org-id")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://opencode.ai/console/\(ws)/usage", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return ([], nil, 0) }
        guard (200...299).contains(http.statusCode) else { return ([], nil, http.statusCode) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["items"] as? [[String: Any]] else { return ([], nil, http.statusCode) }
        return (arr, obj["nextCursor"] as? String, http.statusCode)
    }

    /// 新控制台的 cookie 头
    static func consoleCookieHeader(auth: String, session: String) -> String {
        var parts = ["oc_locale=zh"]
        if !auth.isEmpty { parts.append("auth=\(auth)") }
        if !session.isEmpty { parts.append("__Host-console_session=\(session)") }
        return parts.joined(separator: "; ")
    }

    /// 调一个新控制台接口，返回响应体（非 2xx 返回 nil 并把样本存下来）
    func consoleFetch(path: String, query: String, cookie: String, ws: String) async -> Data? {
        var comps = URLComponents(string: "https://opencode.ai/console/api/\(path)")!
        comps.query = query
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(ws, forHTTPHeaderField: "x-org-id")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://opencode.ai/console/\(ws)/usage", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else {
            logger.error("CostCrawler: 新控制台 \(path) 请求发不出去")
            return nil
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")?
            .set(String(text.prefix(8000)), forKey: "lastConsoleAPISample")
        guard (200...299).contains(http.statusCode) else {
            logger.error("CostCrawler: 新控制台 \(path) HTTP \(http.statusCode)：\(text.prefix(160))")
            return nil
        }
        return data
    }

    /// 解析 usage/models：{items:[{model, totalCostMicroCents, ...}]} → 模型 → 美元
    static func parseModelCosts(_ json: Any) -> [String: Double] {
        var out: [String: Double] = [:]
        let items: [[String: Any]]
        if let d = json as? [String: Any], let arr = d["items"] as? [[String: Any]] { items = arr }
        else if let arr = json as? [[String: Any]] { items = arr }
        else { return out }
        for item in items {
            guard let model = item["model"] as? String else { continue }
            let micro = UsageRows.microCents(item["totalCostMicroCents"])
            if micro > 0 { out[model, default: 0] += micro / 100_000_000.0 }
        }
        return out.filter { $0.value > 0 }
    }

    /// 防御式解析「按天花费」：在 JSON 里找同时带日期和金额的对象。
    /// 支持的字段名覆盖常见几种；找不到就继续往深处走。
    static func parseCostByDay(_ json: Any) -> [DailyCost] {
        // 新控制台的确定结构（2026-09-19 实测）：
        //   [{"date":"2026-09-19","totalCostMicroCents":"64094470","totalTokens":"…","totalRequests":"…"}]
        // 金额是「微美分」字符串，1 美元 = 100,000,000。
        if let arr = json as? [[String: Any]],
           arr.contains(where: { $0["date"] != nil && $0["totalCostMicroCents"] != nil }) {
            let rows = arr.compactMap { item -> DailyCost? in
                guard let date = item["date"] as? String else { return nil }
                let usd = UsageRows.microCents(item["totalCostMicroCents"]) / 100_000_000.0
                let key = (item["model"] as? String) ?? "(total)"
                return DailyCost(date: String(date.prefix(10)), entries: [key: usd])
            }
            var merged: [String: [String: Double]] = [:]
            for r in rows {
                for (k, v) in r.entries where v > 0 { merged[r.date, default: [:]][k, default: 0] += v }
            }
            if !merged.isEmpty {
                return merged.map { DailyCost(date: $0.key, entries: $0.value) }.sorted { $0.date < $1.date }
            }
        }

        var byDate: [String: [String: Double]] = [:]
        let dateKeys = ["date", "day", "bucket", "timestamp", "time", "createdAt"]
        let costKeys = ["cost", "total", "amount", "spend", "value", "totalCost", "costUsd", "usd"]
        let modelKeys = ["model", "modelId", "model_id", "name"]

        func dayString(_ value: Any?) -> String? {
            if let s = value as? String, s.count >= 10 { return String(s.prefix(10)) }
            if let n = value as? Double {
                let d = Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
                return ChartFormatters.day.string(from: d)
            }
            if let n = value as? Int { return dayString(Double(n)) }
            return nil
        }

        func walk(_ node: Any, inheritedDate: String?, inheritedModel: String?) {
            if let arr = node as? [Any] {
                for el in arr { walk(el, inheritedDate: inheritedDate, inheritedModel: inheritedModel) }
                return
            }
            guard let dict = node as? [String: Any] else { return }
            var date = inheritedDate
            for k in dateKeys where date == nil { date = dayString(dict[k]) }
            var model = inheritedModel
            for k in modelKeys where model == nil { if let s = dict[k] as? String, !s.isEmpty { model = s } }
            var amount: Double?
            for k in costKeys {
                if let v = dict[k] as? Double { amount = v; break }
                if let v = dict[k] as? Int { amount = Double(v); break }
                if let s = dict[k] as? String, let v = Double(s) { amount = v; break }
            }
            if let d = date, let a = amount {
                byDate[d, default: [:]][model ?? "(total)", default: 0] += a
                return
            }
            for value in dict.values { walk(value, inheritedDate: date, inheritedModel: model) }
        }

        walk(json, inheritedDate: nil, inheritedModel: nil)
        return byDate
            .map { DailyCost(date: $0.key, entries: $0.value.filter { $0.value > 0 }) }
            .filter { !$0.entries.isEmpty }
            .sorted { $0.date < $1.date }
    }
}
