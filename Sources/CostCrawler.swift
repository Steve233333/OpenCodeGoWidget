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

/// 历史回填的"只允许一个在跑"闸门（actor 版，从 async 上下文里调用不会报警告）
actor BackfillGate {
    private var running = false
    func acquire() -> Bool {
        if running { return false }
        running = true
        return true
    }
    func release() { running = false }
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
    /// 回填是长跑（30 天 ≈ 170 页），而刷新每 5 分钟来一次 —— 不加锁会有两个爬虫
    /// 同时写同一个游标，互相把进度往回拽。这里只允许一个在跑。
    private let backfillGate = BackfillGate()

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
        // 官方每天总额（对账用）：日后发现某天存的明细比官方总额少很多，说明那天只有"半天明细"
        var officialTotals: [String: Double] = [:]
        for d in daily { officialTotals[d.date] = d.total }
        // 明细：`usage/rows` 每条带 costMicroCents + model + serviceApiKeyId（pageSize 上限 100）。
        // 24h 约 500 条 → 6 次请求，拿到「按模型」+「按 Key」的当日拆分。
        // 30 天全量要 169 次请求，太重 → 采用增量累积：每天刷新把当日明细并进快照，
        // 历史逐日堆起来（老快照里的旧天原样保留）。
        // 2026-09-19：24h 也切片并行（4 × 6 小时）—— 串行翻 10 页 ×6s ≈ 1 分钟，并行后约 20 秒
        let now24 = Date()
        let windows24: [(start: Date, end: Date)] = (0..<4).map { i in
            let end = now24.addingTimeInterval(-Double(i) * 6 * 3600)
            return (start: end.addingTimeInterval(-6 * 3600), end: end)
        }
        var rows: [[String: Any]] = []
        await consoleRowsInWindows(windows24, cookie: cookie, ws: workspaceID, concurrency: 4) { batch, _ in
            rows += batch
        }
        let (rowDaily, rowByKey) = Self.aggregateRows(rows)
        if !rowDaily.isEmpty {
            let previous = WidgetDataStore.load()
            var merged: [String: DailyCost] = [:]
            for d in (previous?.dailyCosts ?? []) { merged[d.date] = d }
            // ⚠️ cost-by-day 只有「每天一个总额」，是无明细时的兜底 —— **不能覆盖**已有明细的天
            // （2026-09-19 实测：写成"覆盖"会把回填好的历史明细每轮冲掉，于是"所有密钥"永远纯色，
            //   而按 Key 视图走 dailyByKey 的合并逻辑、反而有颜色 —— 就是用户看到的怪现象）
            for d in daily where merged[d.date] == nil { merged[d.date] = d }
            for (date, entries) in rowDaily {
                let newTotal = entries.values.reduce(0, +)
                // 2026-09-20：24h 窗口只覆盖"边界那天"的一部分 —— 直接覆盖会把昨天整天冲成
                // 晚上那一小段（用户实拍：9/19 实际 $2.19，被写成 $0.45）。
                // 用量只会累加，所以新的明显更少时保留旧的。
                if let old = merged[date], old.total > newTotal * 1.001 { continue }
                merged[date] = DailyCost(date: date, entries: entries)
            }
            // 和官方总额对账：明细明显偏小 = 那天只有部分明细 → 先按官方总额显示（钱先对），
            // 这天随即变成"只有总额、缺明细"，下一次回填会用整天窗口重抓。
            // 2026-09-20：官方总额只覆盖"已结算的整天"（今天的官方总额还是 0，所以只对 >0 的天对账）。
            for (date, official) in officialTotals where official > 0 {
                guard let cur = merged[date], cur.total > 0, cur.total < official * 0.999 else { continue }
                let ratio = official / cur.total
                let hasDetail = cur.entries.contains { $0.key != "(total)" && $0.value > 0 }
                if hasDetail, ratio < 1.10 {
                    // 只差一点点（日界/舍入级别）：把各模型按同一比例归一到官方总额，
                    // 这样柱子上的钱和官网完全一致，颜色拆分比例仍然来自真实明细。
                    var scaled: [String: Double] = [:]
                    for (k, v) in cur.entries { scaled[k] = v * ratio }
                    merged[date] = DailyCost(date: date, entries: scaled)
                    logger.info("CostCrawler: \(date) 明细 $\(cur.total) 归一到官方 $\(official)（×\(ratio)）")
                } else {
                    // 差得多：说明这天只有"半天明细" → 先按官方总额显示（钱先对），排队重抓明细
                    logger.info("CostCrawler: \(date) 明细 $\(cur.total) 远少于官方 $\(official) → 先按官方总额显示并排队重抓")
                    merged[date] = DailyCost(date: date, entries: ["(total)": official])
                }
            }
            daily = merged.values.sorted { $0.date < $1.date }

            var mergedByKey: [String: [String: DailyCost]] = [:]
            for (key, arr) in (previous?.dailyByKey ?? [:]) {
                for d in arr where rowByKey[key]?[d.date] == nil { mergedByKey[key, default: [:]][d.date] = d }
            }
            for (key, byDate) in rowByKey {
                for (date, entries) in byDate {
                    let newTotal = entries.values.reduce(0, +)
                    if let old = mergedByKey[key]?[date], old.total > newTotal * 1.001 { continue }
                    mergedByKey[key, default: [:]][date] = DailyCost(date: date, entries: entries)
                }
            }
            let byKey = mergedByKey.mapValues { $0.values.sorted { $0.date < $1.date } }
            daily = Self.applyUnionDetail(daily: daily, byKey: byKey)
            return MonthlyCost(daily: daily, keys: [], dailyByKey: byKey)
        }
        return MonthlyCost(daily: daily, keys: [], dailyByKey: [:])
    }

    /// 自愈：所有密钥视图的每天数据，若「各 Key 明细的并集」比它更细，就用并集。
    /// （历史天只有 cost-by-day 的单个总额时会被替换成按模型的明细 → 图上就有颜色了）
    static func applyUnionDetail(daily: [DailyCost], byKey: [String: [DailyCost]]) -> [DailyCost] {
        var union: [String: [String: Double]] = [:]
        for (_, arr) in byKey {
            for day in arr {
                for (model, v) in day.entries where v > 0 {
                    union[day.date, default: [:]][model, default: 0] += v
                }
            }
        }
        guard !union.isEmpty else { return daily }
        var map: [String: DailyCost] = [:]
        for d in daily { map[d.date] = d }
        for (date, entries) in union {
            let current = map[date]?.entries ?? [:]
            let curTotal = current.values.reduce(0, +)
            let unionTotal = entries.values.reduce(0, +)
            guard entries.count > current.count, unionTotal > 0 else { continue }
            if curTotal > 0, unionTotal < curTotal * 0.98 {
                // 2026-09-20：并集金额明显比现在少 = 这份并集是"半天明细"。以前无条件用它替换，
                // 结果把刚对上的官方总额又顶回成 $0.40（用户实拍：9/19 官方 $2.19 显示 $0.40）。
                // 只有"这天现在只是官方总额、并集只差一点点（日界/舍入）"时，才按官方总额等比归一并集，既保钱又拿颜色。
                if unionTotal >= curTotal * 0.90, current.count == 1, current["(total)"] != nil {
                    let ratio = curTotal / unionTotal
                    map[date] = DailyCost(date: date, entries: entries.mapValues { $0 * ratio })
                }
                continue
            }
            map[date] = DailyCost(date: date, entries: entries)
        }
        return map.values.sorted { $0.date < $1.date }
    }

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
    private func consoleRowsInWindow(cookie: String, ws: String, start: Date, end: Date,
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

    /// 多个时间窗并行抓（窗口内部顺序翻页，窗口之间并发 4 个）。
    /// 每个窗口抓完就把结果交给 onBatch，方便边抓边落盘（进度条能看到）。
    private func consoleRowsInWindows(_ windows: [(start: Date, end: Date)], cookie: String, ws: String,
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
    private func consoleRowsPage(cookie: String, ws: String, range: String,
                                 cursor: String?) async -> (items: [[String: Any]], next: String?, status: Int) {
        var comps = URLComponents(string: "https://opencode.ai/console/api/usage/rows")!
        var query = [URLQueryItem(name: "range", value: range), URLQueryItem(name: "pageSize", value: "100")]
        if let c = cursor, !c.isEmpty { query.append(URLQueryItem(name: "cursor", value: c)) }
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

    /// 一小段数据里"只有每天一个总额、没有模型维度"的天 —— 就是图上纯色的那些天。
    static func daysMissingDetail(_ snap: WidgetSnapshot?) -> Set<String> {
        guard let snap else { return [] }
        var out: Set<String> = []
        for d in snap.dailyCosts {
            guard d.total > 0 else { continue }
            let hasModel = d.entries.contains { $0.key != "(total)" && $0.value > 0 }
            if !hasModel { out.insert(d.date) }
        }
        return out
    }

    /// 历史明细回填（2026-09-19，当晚改成"按需修复"）：新接口的 cost-by-day 只给每天一个总额，
    /// 改版前的历史天没有模型维度（用户看到"账期之前的日期全是纯色"）。这里分页拉 30 天 rows
    /// 把历史按天按模型补回来。可中断可续：游标存 UserDefaults，下次刷新接着拉。
    ///
    /// ⚠️ 以前是一次性闩锁（`historyBackfillDone` 置位后再也不跑）。明细一旦被某次"粗数据"覆盖
    /// （老 /_server 回落 / HAR 缓存 / cost-by-day 兜底都可能只给每天一个总额），用户点多少次
    /// 「刷新」都补不回来 —— 实测就是这样，用户重启后 9/1–9/18 又全变纯色。
    /// 现在按需修复：快照里还有"只有 (total) 的天"就重跑；跑完仍补不上的天记进
    /// `historyRepairMissing`，同样缺口不再重复打接口（缺口变了才再跑一次）。
    /// 返回 true = 快照被改写（调用方应重读并刷新界面）。
    @discardableResult
    func backfillHistoryIfNeeded() async -> Bool {
        guard await backfillGate.acquire() else { return false }
        let updated = await runBackfill()
        await backfillGate.release()
        return updated
    }

    private func runBackfill() async -> Bool {
        let suite = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
        let missing = Self.daysMissingDetail(WidgetDataStore.load())
        // 只有"跑完整轮且缺口没变"才跳过：半轮中断绝不写备忘录，否则自己把自己挡住
        let lastMissing = Set((suite?.dictionary(forKey: "historyRepairLast")?["missing"] as? [String]) ?? [])
        guard !missing.isEmpty, missing != lastMissing else { return false }
        logger.info("CostCrawler: 历史明细缺失 \(missing.count) 天 → 触发回填")
        let ws = suite?.string(forKey: "workspaceID") ?? ""
        let auth = suite?.string(forKey: "authCookie") ?? ""
        let session = suite?.string(forKey: "consoleSession") ?? ""
        guard !ws.isEmpty, !session.isEmpty else { return false }
        let cookie = Self.consoleCookieHeader(auth: auth, session: session)

        // 回填是长跑：给界面留一个"在跑"的标记（进度条 + 每 5 秒重读快照靠它）
        suite?.set(true, forKey: "historyBackfillRunning")
        suite?.set(Date(), forKey: "historyBackfillRunningAt")
        defer { suite?.set(false, forKey: "historyBackfillRunning") }

        // 2026-09-19 提速：不再从头串行翻 170 页，而是"缺哪天抓哪天"——
        // 用合成游标直接跳到那天，4 天并行。实测把 17 分钟压到几分钟。
        let fmt = ChartFormatters.day
        let deadline = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        var windows: [(start: Date, end: Date)] = []
        for dayStr in missing.sorted() {
            guard let start = fmt.date(from: dayStr),
                  let end = BillingCycle.calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            guard end > deadline else { continue }   // 超出 30 天窗口的天接口根本给不了，别浪费请求
            windows.append((start, end))
        }
        guard !windows.isEmpty else {
            suite?.set(["missing": Array(missing), "at": Date()], forKey: "historyRepairLast")
            logger.info("CostCrawler: 缺的 \(missing.count) 天全在 30 天窗口外，无法回填")
            return false
        }
        logger.info("CostCrawler: 回填 \(windows.count) 天（每天一个窗口，4 并发）")

        var total = 0
        var failedWindows = 0
        await consoleRowsInWindows(windows, cookie: cookie, ws: ws, concurrency: 4) { rows, ok in
            total += rows.count
            if !ok {
                failedWindows += 1
                // 2026-09-20：**半截数据一律不落盘**。以前把"某页失败的窗口"里的残留行也合并了，
                // 于是整天被写成"只覆盖了几个小时"的小数（用户实拍：9/19 显示 $0.41，实际 $2.19）。
                // 宁可不补，也不要拿半天数据冒充整天 —— 这天保持"缺明细"，下次刷新重抓。
                return
            }
            self.mergeRowsIntoSnapshot(rows)   // 每批落盘：进度条往前走、中途被杀也不白跑
        }
        suite?.set(failedWindows, forKey: "historyBackfillFailedWindows")
        suite?.set(total, forKey: "historyBackfillLastCount")
        guard total > 0, let snap = WidgetDataStore.load() else {
            logger.warning("CostCrawler: 回填一条也没抓到（接口抖动），不写备忘，下次刷新再试")
            return false
        }
        let still = Self.daysMissingDetail(snap)
        // 只在"这一轮没有窗口失败"时才记备忘：有失败说明是网络/接口问题，下次必须重试，
        // 不能像以前那样把自己挡住（用户实拍：挡了一次就永远补不回来）
        if failedWindows == 0 {
            suite?.set(["missing": Array(still), "at": Date()], forKey: "historyRepairLast")
        }
        logger.info("CostCrawler: 历史回填 \(total) 条，仍缺 \(still.count) 天，失败窗口 \(failedWindows)")
        return true
    }

    /// 把这一轮爬到（或爬到一半）的明细并进快照；只补"没有明细的天"，不冲掉已经更细的。
    @discardableResult
    private func mergeRowsIntoSnapshot(_ collected: [[String: Any]]) -> Bool {
        guard !collected.isEmpty, var snap = WidgetDataStore.load() else { return false }
        let (daily, byKey) = Self.aggregateRows(collected)
        var dayMap: [String: DailyCost] = [:]
        for d in snap.dailyCosts { dayMap[d.date] = d }
        for (date, entries) in daily {
            let current = dayMap[date]?.entries ?? [:]
            let curTotal = current.values.reduce(0, +)
            let newTotal = entries.values.reduce(0, +)
            let hasDetail = current.contains { $0.key != "(total)" && $0.value > 0 }
            // 有明细、而且这次（整天窗口）不比旧的多 → 不动；否则用整天数据。
            // 2026-09-20：这里以前是"有明细就跳过"，于是"半天明细"永远修不回来。
            if hasDetail && newTotal <= curTotal { continue }
            dayMap[date] = DailyCost(date: date, entries: entries)
        }
        snap.dailyCosts = dayMap.values.sorted { $0.date < $1.date }

        var byKeyMap: [String: [String: DailyCost]] = [:]
        for (k, arr) in snap.dailyByKey { for d in arr { byKeyMap[k, default: [:]][d.date] = d } }
        for (k, byDate) in byKey {
            for (date, entries) in byDate {
                let cur = byKeyMap[k]?[date]?.entries ?? [:]
                let hasDetail = cur.contains { $0.key != "(total)" && $0.value > 0 }
                if hasDetail, cur.values.reduce(0, +) > entries.values.reduce(0, +) { continue }
                byKeyMap[k, default: [:]][date] = DailyCost(date: date, entries: entries)
            }
        }
        snap.dailyByKey = byKeyMap.mapValues { $0.values.sorted { $0.date < $1.date } }
        snap.updatedAt = Date()
        return WidgetDataStore.save(snap)
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
