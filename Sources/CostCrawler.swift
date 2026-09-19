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

    /// 账期拉取：并发拉账期跨越的两个自然月并按 [cycleStart..<monthlyReset) 合并
    func fetchBillingCycleCosts(workspaceID: String, authCookie: String, monthlyReset: Date) async -> MonthlyCost? {
        // 无 workspace 凭据时别并发空请求，直接走本地缓存（fresh Mac 上避免 Widget 空刷成 0）
        if workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || authCookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let cached = await fetchHARFallback() { return filterToBilling(cached, monthlyReset: monthlyReset) }
            logger.info("CostCrawler: billing fetch skipped — workspace credentials missing")
            return nil
        }
        // 2026-09-19：OpenCode 上线新控制台（/console/），老的 /_server server-fn 接口直接 303 到登录页。
        // 先走新 API（正规 REST，带 x-org-id），失败再回落到老路径，保证过渡期不彻底断数据。
        if let mc = await fetchConsoleAPI(workspaceID: workspaceID, authCookie: authCookie, monthlyReset: monthlyReset) {
            logger.info("CostCrawler: 新控制台 API 拉取成功（\(mc.daily.count) 天）")
            return mc
        }
        logger.warning("CostCrawler: 新控制台 API 未成功，回落老 /_server 路径")
        let months = BillingCycle.monthsInCycle(monthlyReset: monthlyReset)
        guard !months.isEmpty else { return nil }
        var fetched: [MonthlyCost] = []
        await withTaskGroup(of: MonthlyCost?.self) { group in
            for (y, m0) in months {
                group.addTask {
                    if let a = await self.fetchWorkspaceCostAttempt(workspaceID: workspaceID, authCookie: authCookie, year: y, month0: m0, includeServerHeader: true) { return a }
                    return await self.fetchWorkspaceCostAttempt(workspaceID: workspaceID, authCookie: authCookie, year: y, month0: m0, includeServerHeader: false)
                }
            }
            for await v in group { if let c = v { fetched.append(c) } }
        }
        if fetched.isEmpty {
            if let cached = await fetchHARFallback() { return filterToBilling(cached, monthlyReset: monthlyReset) }
            return nil
        }
        // 合并所有月 -> 再按账期过滤 + 按模型聚合去重
        var byDate: [String: [String: Double]] = [:]
        var byDateByKey: [String: [String: [String: Double]]] = [:]
        var allKeys: [ApiKeyInfo] = []
        var seenKeys = Set<String>()
        for mc in fetched {
            for k in mc.keys where seenKeys.insert(k.id).inserted { allKeys.append(k) }
            for dc in mc.daily {
                // 先合并，后过滤，避免跨月同一天被截
                byDate[dc.date, default: [:]] = mergeModelDict(into: byDate[dc.date] ?? [:], from: dc.entries)
            }
            for (kid, arr) in mc.dailyByKey {
                for dc in arr {
                    byDateByKey[kid, default: [:]][dc.date, default: [:]] = mergeModelDict(into: byDateByKey[kid]?[dc.date] ?? [:], from: dc.entries)
                }
            }
        }
        // 2026-09-19 修：以前这里只留「账期窗口内」的天，新账期刚开、还没任何用量时结果就是空 →
        // 上层（WidgetSnapshotRefresher）会走"保旧"回退，把上一个月的数据继续当结果用
        // （用户实拍：账期 9/19-10/18 顶部挂着自然月的 $24.11）。
        // 现在保留抓到的整月数据（这些月份天然覆盖"当前账期 + 当前自然月"），
        // 由各视图自己按窗口过滤：账期图、自然月图、顶部总数都走 MonthChartView.windowDates。
        let daily = byDate.map { DailyCost(date: $0.key, entries: $0.value) }.sorted { $0.date < $1.date }
        var dailyByKey: [String: [DailyCost]] = [:]
        for (k, dict) in byDateByKey {
            dailyByKey[k] = dict.map { DailyCost(date: $0.key, entries: $0.value) }.sorted { $0.date < $1.date }
        }
        if daily.isEmpty { return nil }
        return MonthlyCost(daily: daily, keys: allKeys, dailyByKey: dailyByKey)
    }
    /// 新控制台 API（2026-09-19 改版后）：
    ///   GET https://opencode.ai/console/api/usage/cost-by-day?range=30d
    ///   头：Cookie: oc_locale=zh; auth=<cookie>   +   x-org-id: <wrk_... 或 org_...>
    /// 老接口 /_server 已随改版下线（返回 303 到 /console/login）。
    /// 返回结构官方没公开，这里**防御式解析**并把原始响应存下来（自检会显示样本），
    /// 拿到真实样本后再收紧。
    func fetchConsoleAPI(workspaceID: String, authCookie: String, monthlyReset: Date) async -> MonthlyCost? {
        // 新控制台要两个 cookie：auth（老站）+ __Host-console_session（新会话，缺它必 401）
        let session = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")?
            .string(forKey: "consoleSession") ?? ""
        let cookie = Self.consoleCookieHeader(auth: authCookie, session: session)

        guard let days = await consoleFetch(path: "usage/cost-by-day", query: "range=30d",
                                            cookie: cookie, ws: workspaceID),
              let json = try? JSONSerialization.jsonObject(with: days) else {
            return nil
        }
        var daily = Self.parseCostByDay(json)
        guard !daily.isEmpty else {
            logger.warning("CostCrawler: cost-by-day 解析出 0 天：\(String(data: days, encoding: .utf8)?.prefix(200) ?? "")")
            return nil
        }
        // 明细：`usage/rows` 每条带 costMicroCents + model + serviceApiKeyId（pageSize 上限 100）。
        // 24h 约 500 条 → 6 次请求，拿到「按模型」+「按 Key」的当日拆分。
        // 30 天全量要 169 次请求，太重 → 采用增量累积：每天刷新把当日明细并进快照，
        // 历史逐日堆起来（老快照里的旧天原样保留）。
        let rows = await consoleFetchRows(cookie: cookie, ws: workspaceID, range: "24h")
        let (rowDaily, rowByKey) = Self.aggregateRows(rows)
        if !rowDaily.isEmpty {
            let previous = WidgetDataStore.load()
            var merged: [String: DailyCost] = [:]
            for d in (previous?.dailyCosts ?? []) { merged[d.date] = d }
            for d in daily where rowDaily[d.date] == nil { merged[d.date] = d }   // cost-by-day 里的旧天
            for (date, entries) in rowDaily { merged[date] = DailyCost(date: date, entries: entries) }
            daily = merged.values.sorted { $0.date < $1.date }

            var mergedByKey: [String: [String: DailyCost]] = [:]
            for (key, arr) in (previous?.dailyByKey ?? [:]) {
                for d in arr where rowByKey[key]?[d.date] == nil { mergedByKey[key, default: [:]][d.date] = d }
            }
            for (key, byDate) in rowByKey {
                for (date, entries) in byDate {
                    mergedByKey[key, default: [:]][date] = DailyCost(date: date, entries: entries)
                }
            }
            let byKey = mergedByKey.mapValues { $0.values.sorted { $0.date < $1.date } }
            return MonthlyCost(daily: daily, keys: [], dailyByKey: byKey)
        }
        return MonthlyCost(daily: daily, keys: [], dailyByKey: [:])
    }

    /// 翻页拉 usage/rows（cursor 分页，pageSize 上限 100；24h 最多 12 页 = 1200 条足够）
    private func consoleFetchRows(cookie: String, ws: String, range: String) async -> [[String: Any]] {
        var items: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<12 {
            var comps = URLComponents(string: "https://opencode.ai/console/api/usage/rows")!
            var query = [URLQueryItem(name: "range", value: range), URLQueryItem(name: "pageSize", value: "100")]
            if let c = cursor, !c.isEmpty { query.append(URLQueryItem(name: "cursor", value: c)) }
            comps.queryItems = query
            var req = URLRequest(url: comps.url!)
            req.timeoutInterval = 20
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            req.setValue(ws, forHTTPHeaderField: "x-org-id")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("https://opencode.ai/console/\(ws)/usage", forHTTPHeaderField: "Referer")
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["items"] as? [[String: Any]] else {
                if items.isEmpty { logger.error("CostCrawler: usage/rows 拉取失败") }
                break
            }
            items += arr
            cursor = obj["nextCursor"] as? String
            if cursor == nil || cursor!.isEmpty { break }
        }
        return items
    }

    /// 明细行 → (date→model→美元, keyId→date→model→美元)
    static func aggregateRows(_ rows: [[String: Any]]) -> ([String: [String: Double]], [String: [String: [String: Double]]]) {
        var daily: [String: [String: Double]] = [:]
        var byKey: [String: [String: [String: Double]]] = [:]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        for row in rows {
            guard let model = row["model"] as? String else { continue }
            let usd = microCents(row["costMicroCents"]) / 100_000_000.0
            guard usd > 0 else { continue }
            guard let created = row["createdAt"] as? String else { continue }
            let date = (iso.date(from: created) ?? isoNoFrac.date(from: created))
                .map { ChartFormatters.day.string(from: $0) } ?? String(created.prefix(10))
            daily[date, default: [:]][model, default: 0] += usd
            if let key = row["serviceApiKeyId"] as? String, !key.isEmpty {
                byKey[key, default: [:]][date, default: [:]][model, default: 0] += usd
            }
        }
        return (daily, byKey)
    }

    /// 新控制台的 cookie 头
    static func consoleCookieHeader(auth: String, session: String) -> String {
        var parts = ["oc_locale=zh"]
        if !auth.isEmpty { parts.append("auth=\(auth)") }
        if !session.isEmpty { parts.append("__Host-console_session=\(session)") }
        return parts.joined(separator: "; ")
    }

    /// 调一个新控制台接口，返回响应体（非 2xx 返回 nil 并把样本存下来）
    private func consoleFetch(path: String, query: String, cookie: String, ws: String) async -> Data? {
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
            let micro = Self.microCents(item["totalCostMicroCents"])
            if micro > 0 { out[model, default: 0] += micro / 100_000_000.0 }
        }
        return out.filter { $0.value > 0 }
    }

    /// 新接口的金额字段是「微美分」字符串：100,000,000 微美分 = 1 美元
    static func microCents(_ value: Any?) -> Double {
        if let s = value as? String { return Double(s) ?? 0 }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return 0
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
                let usd = microCents(item["totalCostMicroCents"]) / 100_000_000.0
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

    private func mergeModelDict(into base: [String: Double], from add: [String: Double]) -> [String: Double] {
        var r = base
        for (k,v) in add { r[k, default: 0] += v }
        return r
    }
    private func filterToBilling(_ mc: MonthlyCost, monthlyReset: Date) -> MonthlyCost? {
        let (s, e, _) = BillingCycle.billingDateStrings(monthlyReset: monthlyReset)
        let daily = mc.daily.filter { $0.date >= s && $0.date < e }
        var byKey: [String: [DailyCost]] = [:]
        for (k, arr) in mc.dailyByKey { byKey[k] = arr.filter { $0.date >= s && $0.date < e } }
        guard !daily.isEmpty else { return nil }
        return MonthlyCost(daily: daily, keys: mc.keys, dailyByKey: byKey)
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
