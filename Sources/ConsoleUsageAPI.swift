import Foundation
import os

/// 控制台用量 API 的**网络 / 游标 / 解析**层（2026-09-23 Phase 1 从 CostCrawler.swift 拆出）。
///
/// 这里只负责"怎么把数据从 opencode.ai 拿下来"；合并规则在 `UsageMerge`，
/// 行级归日/拆分在 `UsageRows`（都是唯一真源）。
///
/// 2026-09-26 数据源迁移：上游把 `usage/rows` 撤了（任何参数都 404），明细改用 `/logs` 页面的
/// `request-logs`：
///   * `GET /console/api/request-logs?since=<ms>&until=<ms>&cursor=&limit=≤100` → `{items, nextCursor, retentionDays}`
///   * `GET /console/api/request-logs/export?format=json&since=<ms>&until=<ms>`
///     → `{content:"{\"items\":[…]}", count, truncated, until}`，**单次最多 1000 条**
///   一条记录带 `serviceAPIKeyID / model / cost(美元) / startedAt(ms)` —— 正是我们要的维度；
///   保留 `retentionDays = 30`（实测）。
extension CostCrawler {

    // MARK: - request-logs（新数据源）

    /// 一页 request-logs（100 条/页）。增量的小窗口用这个就够，省一次 export 的 JSON 解包。
    func requestLogsPage(cookie: String, ws: String, since: Date?, until: Date?,
                                 cursor: String? = nil, limit: Int = 100) async
        -> (items: [[String: Any]], next: String?, ok: Bool) {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(min(100, max(1, limit))))]
        if let since { query.append(URLQueryItem(name: "since", value: String(Int(since.timeIntervalSince1970 * 1000)))) }
        if let until { query.append(URLQueryItem(name: "until", value: String(Int(until.timeIntervalSince1970 * 1000)))) }
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        guard let data = await consoleFetch(path: "request-logs", queryItems: query, cookie: cookie, ws: ws),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], nil, false)
        }
        return (obj["items"] as? [[String: Any]] ?? [], obj["nextCursor"] as? String, true)
    }

    /// 一次 export（≤1000 条；`truncated=true` 说明窗口里还有更老的，要二分）。
    /// 实测大窗口单次要 7~20s，偶发读超时 → 单次重试（再失败就交给下一轮刷新）。
    func requestLogsExport(cookie: String, ws: String, start: Date, end: Date) async
        -> (items: [[String: Any]], truncated: Bool, ok: Bool) {
        let query = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "since", value: String(Int(start.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "until", value: String(Int(end.timeIntervalSince1970 * 1000))),
        ]
        var obj: [String: Any]?
        for attempt in 0..<2 {
            if let data = await consoleFetch(path: "request-logs/export", queryItems: query,
                                             cookie: cookie, ws: ws, timeout: 60),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                obj = parsed
                break
            }
            if attempt == 0 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        }
        guard let obj else { return ([], false, false) }
        // content 是一段 JSON 字符串：{"items":[…],"truncated":…,"until":…}
        var items: [[String: Any]] = []
        if let text = obj["content"] as? String, let inner = text.data(using: .utf8),
           let wrapper = try? JSONSerialization.jsonObject(with: inner) as? [String: Any] {
            items = wrapper["items"] as? [[String: Any]] ?? []
        } else if let direct = obj["items"] as? [[String: Any]] {
            items = direct     // 万一以后官方直接返回数组
        }
        return (items, obj["truncated"] as? Bool ?? false, true)
    }

    /// 从 `since` 起分页抓（每页 100 条，最多 maxPages 页）——增量刷新用这个，比 export 便宜
    func requestLogsSince(cookie: String, ws: String, since: Date, maxPages: Int = 8) async
        -> (logs: [[String: Any]], ok: Bool) {
        var out: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<maxPages {
            let page = await requestLogsPage(cookie: cookie, ws: ws, since: since, until: nil, cursor: cursor)
            guard page.ok else { return (out, false) }
            out += page.items
            guard let next = page.next, !next.isEmpty else { return (out, true) }
            cursor = next
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return (out, true)
    }

    /// 抓 [start, end) 这个时间窗的**全部**日志：超过 1000 条就按时间中点二分递归。
    /// 实测：9/25 一整天 639 条（一次 export 拿完，7s）；半天 427 + 212 也正好等于 639，说明
    /// 窗口两端是半开区间、不会重复也不会漏。
    func requestLogsInWindow(cookie: String, ws: String, start: Date, end: Date,
                                     depth: Int = 0) async -> (logs: [[String: Any]], ok: Bool) {
        let page = await requestLogsExport(cookie: cookie, ws: ws, start: start, end: end)
        guard page.ok else { return ([], false) }
        guard page.truncated else { return (page.items, true) }
        guard let mid = UsageRows.windowMidpoint(start: start, end: end), depth < 8 else {
            logger.warning("CostCrawler: request-logs 窗口 \(Int(end.timeIntervalSince(start)))s 仍超 1000 条，先用已有 \(page.items.count) 条")
            return (page.items, true)
        }
        async let left = requestLogsInWindow(cookie: cookie, ws: ws, start: start, end: mid, depth: depth + 1)
        async let right = requestLogsInWindow(cookie: cookie, ws: ws, start: mid, end: end, depth: depth + 1)
        let (l, r) = await (left, right)
        return (l.logs + r.logs, l.ok && r.ok)
    }

    /// 多个时间窗并行抓（窗口之间并发 N 个；每个窗口内部若超 1000 条会自己二分）。
    /// 每个窗口抓完就把结果交给 onBatch，方便边抓边落盘（进度条能看到）。
    func requestLogsInWindows(_ windows: [(start: Date, end: Date)], cookie: String, ws: String,
                                      concurrency: Int = 4,
                                      onBatch: ([[String: Any]], Bool) -> Void) async {
        var idx = 0
        while idx < windows.count {
            let slice = Array(windows[idx..<min(idx + concurrency, windows.count)])
            idx += slice.count
            await withTaskGroup(of: (logs: [[String: Any]], ok: Bool).self) { group in
                for w in slice {
                    group.addTask { await self.requestLogsInWindow(cookie: cookie, ws: ws, start: w.start, end: w.end) }
                }
                var logs: [[String: Any]] = []
                var allOK = true
                for await r in group {
                    logs += r.logs
                    if !r.ok { allOK = false }
                }
                onBatch(logs, allOK)
            }
        }
    }

    /// 新控制台的 cookie 头
    static func consoleCookieHeader(auth: String, session: String) -> String {
        var parts = ["oc_locale=zh"]
        if !auth.isEmpty { parts.append("auth=\(auth)") }
        if !session.isEmpty { parts.append("__Host-console_session=\(session)") }
        return parts.joined(separator: "; ")
    }

    /// 调一个新控制台接口（query 已经是拼好的字符串），返回响应体（非 2xx 返回 nil 并把样本存下来）
    func consoleFetch(path: String, query: String, cookie: String, ws: String) async -> Data? {
        var comps = URLComponents(string: "https://opencode.ai/console/api/\(path)")!
        comps.query = query
        return await consoleFetch(url: comps.url, path: path, cookie: cookie, ws: ws)
    }

    /// 同上，但用 URLQueryItem 拼参数（request-logs 的 cursor/毫秒时间戳里带特殊字符，必须走这里）
    func consoleFetch(path: String, queryItems: [URLQueryItem], cookie: String, ws: String,
                      timeout: TimeInterval = 20) async -> Data? {
        var comps = URLComponents(string: "https://opencode.ai/console/api/\(path)")!
        comps.queryItems = queryItems
        return await consoleFetch(url: comps.url, path: path, cookie: cookie, ws: ws, timeout: timeout)
    }

    private func consoleFetch(url: URL?, path: String, cookie: String, ws: String,
                              timeout: TimeInterval = 20) async -> Data? {
        guard let url else {
            logger.error("CostCrawler: 新控制台 \(path) 的 URL 拼不出来")
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
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
