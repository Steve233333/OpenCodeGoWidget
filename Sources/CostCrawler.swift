import Foundation
import os

final class CostCrawler: @unchecked Sendable {
    /// 拆文件后（2026-09-23 Phase 1）三个文件共用一个 logger / 回填闸门，所以不再是 private。
    let logger = Logger(subsystem: "com.steve233.opencodego", category: "CostCrawler")
    static let shared = CostCrawler()
    /// 回填是长跑（30 天 ≈ 170 页），而刷新每 5 分钟来一次 —— 不加锁会有两个爬虫
    /// 同时写同一个游标，互相把进度往回拽。这里只允许一个在跑。
    let backfillGate = BackfillGate()


    // MARK: - 用量抓取（唯一数据源：新控制台 REST API）

    /// 账期/自然月都用这条：新控制台 API（`usage/rows` + `cost-by-day`）是**唯一数据源**。
    /// 抓不到就返回 nil，上层保留旧快照 —— 2026-09-23 Phase 1 起不再回落老 `/_server`／HAR 缓存
    /// （那个接口早已 404，回落只会把 9/19 的陈旧数字当成本日数据，比"报错"更难查）。
    func fetchBillingCycleCosts(workspaceID: String, authCookie: String, monthlyReset: Date) async -> MonthlyCost? {
        if workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.info("CostCrawler: billing fetch skipped — workspace credentials missing")
            return nil
        }
        if let mc = await fetchConsoleAPI(workspaceID: workspaceID, authCookie: authCookie, monthlyReset: monthlyReset) {
            logger.info("CostCrawler: 新控制台 API 拉取成功（\(mc.daily.count) 天）")
            return mc
        }
        logger.warning("CostCrawler: 新控制台 API 未成功 → 保留旧快照（不再回落老接口）")
        return nil
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

        // 2026-09-26：`cost-by-day` 优先用**小时桶**（`&bucket=hour`）再按北京时间归日 ——
        // 老接口给的是 UTC 日，和我们的日界（北京 0 点）差 8 小时；小时桶能精确重分桶
        // （实测 9/25 日志合计 $0.278950 ↔ 重分桶 $0.2790）。它只当"那天没有明细"时的兜底。
        //
        // 2026-10-15 事故：上游把 `bucket=hour` 参数改坏了 —— 带它**必 500**（实测 5/5 失败，
        // 每次耗 16s 才断），而它以前是这里的第一个 guard：一挂整轮刷新就被放弃、界面永远
        // 停在旧快照（用户报"用了多少钱不会刷新了"）。现在改成三层候选 + **非致命**：
        //   ① range=30d&bucket=hour —— 小时桶，能精确重分桶（上游恢复即自动用回）
        //   ② range=30d            —— 按天（带 bucket 的那条坏掉时的第一兜底）
        //   ③ 无参数                —— 全量按天，最后的兜底
        // 三种全挂也不立刻放弃：request-logs 才是今天/近 30 天的真源，它活着这轮就该继续
        // （历史天由 mergeDaily 的"只增不减"保住；真的一条数据都没有才在下面保留旧快照）。
        let costByDay = await UsageRows.firstParsableCostByDay(
            candidates: UsageRows.costByDayQueries,
            attempt: { query in
                guard let data = await consoleFetch(path: "usage/cost-by-day", query: query,
                                                    cookie: cookie, ws: workspaceID),
                      let json = try? JSONSerialization.jsonObject(with: data) else {
                    logger.warning("CostCrawler: cost-by-day 口径 '\(query.isEmpty ? "(默认)" : query)' 没拿到响应，换下一个")
                    return nil
                }
                return json
            },
            parse: { json in
                let hourly = UsageRows.dailyFromHourlyCost(json)
                return hourly.isEmpty ? Self.parseCostByDay(json) : hourly
            })
        var daily: [DailyCost] = costByDay?.daily ?? []
        if let costByDay {
            logger.info("CostCrawler: cost-by-day 口径 '\(costByDay.query.isEmpty ? "(默认)" : costByDay.query)' 解析出 \(costByDay.daily.count) 天")
        }
        if daily.isEmpty {
            logger.warning("CostCrawler: cost-by-day 三个口径都不可用 → 继续走 request-logs（今天仍会更新）")
        }
        // 明细：`request-logs`（2026-09-26 起替代已下线的 `usage/rows`）每条带
        // serviceAPIKeyID + model + cost(美元) + startedAt(ms)。增量优先、今天整天窗口保完整。
        let syncSuite = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
        let lastSyncAt = syncSuite?.double(forKey: "lastRowSyncAt") ?? 0
        let syncNow = Date()
        let usableIncremental = lastSyncAt > 0 && syncNow.timeIntervalSince1970 - lastSyncAt < 24 * 3600
        var logs: [[String: Any]] = []
        // 2026-09-28：上游日志接口会整段时间不可用（超时/503），这时**不要再往下砸请求** ——
        // 以前会接着跑"最近 24h 切 4 窗并发"，每个窗口 60s 超时，一轮刷新能拖好几分钟。
        var logsApiFailed = false
        if usableIncremental {
            // 往前多要 2 小时重叠：上游是批量入库的，偶尔会有"迟到"的记录
            let since = Date(timeIntervalSince1970: lastSyncAt - 2 * 3600)
            // 增量窗口通常只有几十条 → 用分页（100/页）比 export 便宜得多
            let inc = await requestLogsSince(cookie: cookie, ws: workspaceID, since: since)
            logs = inc.logs
            if !inc.ok { logsApiFailed = true }
            logger.info("CostCrawler: 增量同步 since=\(ISO8601DateFormatter().string(from: since)) 拿到 \(logs.count) 条日志（ok=\(inc.ok)）")
        }
        // 今天整天窗口必抓：增量的片段会让"按 Key / 按模型"停在某个小数（2026-09-22 踩过）。
        let dayStart = BillingCycle.calendar.startOfDay(for: Date())
        let todayWindow = await requestLogsInWindow(cookie: cookie, ws: workspaceID, start: dayStart, end: Date())
        if !todayWindow.ok { logsApiFailed = true }
        if !todayWindow.logs.isEmpty {
            var seen = Set<String>()
            var deduped: [[String: Any]] = []
            for log in todayWindow.logs + logs {
                let key = (log["id"] as? String) ?? UUID().uuidString
                if seen.insert(key).inserted { deduped.append(log) }
            }
            logs = deduped
            logger.info("CostCrawler: 今天整天窗口 \(todayWindow.logs.count) 条，去重后合计 \(logs.count) 条")
        }
        if logs.isEmpty && !logsApiFailed {
            // 增量拿不到（首次运行 / 间隔太久）：最近 24h 切 4 段并发补
            let now24 = Date()
            let windows24: [(start: Date, end: Date)] = (0..<4).map { i in
                let end = now24.addingTimeInterval(-Double(i) * 6 * 3600)
                return (start: end.addingTimeInterval(-6 * 3600), end: end)
            }
            await requestLogsInWindows(windows24, cookie: cookie, ws: workspaceID, concurrency: 4) { batch, _ in
                logs += batch
            }
        } else if logs.isEmpty {
            logger.warning("CostCrawler: 日志接口本轮不可用（超时/503）→ 跳过 24h 补抓，等下一轮；今日逐模型走 usage/models 兜底")
        }
        if !logs.isEmpty { syncSuite?.set(syncNow.timeIntervalSince1970, forKey: "lastRowSyncAt") }
        let rows = UsageRows.rowsFromLogs(logs)
        var (rowDaily, rowByKey) = UsageRows.aggregate(rows)
        let todayStr = ChartFormatters.day.string(from: Date())
        // 一次请求干两件事：① 对账 ② 日志接口退化时的"今日逐模型"兜底。
        //
        // 2026-09-28：上游 `request-logs` 被拖垮（实测 5 条要 24s、20 条直接超时、cost-by-day 也开始 reset），
        // 于是"今日模型"会退化成没有名字的 (total) 条 —— 用户看到就像"小组件挂了"。
        // `usage/models?since=今天0点`（实测 1 秒）本来就是按模型的汇总，正好够这一条用；
        // 按 Key 的那份仍以日志为准（拿不到就保留旧值，不冲掉）。
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // 今天这一格的**权威来源之一**：`usage/models?since=今天0点` 就是"今天整天"的汇总，
        // 而且每轮都调（对账用）。日志接口退化时它就是今天的真源（2026-09-30 起也参与"重算今天"）。
        var officialTodayModels: [String: Double] = [:]
        if let md = await consoleFetch(path: "usage/models",
                                       queryItems: [URLQueryItem(name: "range", value: "30d"),
                                                    URLQueryItem(name: "since", value: iso.string(from: dayStart))],
                                       cookie: cookie, ws: workspaceID),
           let json = try? JSONSerialization.jsonObject(with: md) {
            let officialModels = Self.parseModelCosts(json)
            officialTodayModels = officialModels
            let official = officialModels.values.reduce(0, +)
            let fromLogs = rowDaily[todayStr]?.values.reduce(0, +) ?? 0
            if official > 0.01, abs(official - fromLogs) > max(0.01, official * 0.01) {
                logger.warning("CostCrawler: 今日对账不一致 —— 官方按模型 \(official) vs 日志明细 \(fromLogs)（日志接口退化时属正常）")
            } else if official > 0.01 {
                logger.info("CostCrawler: 今日对账一致（官方 \(official) ≈ 日志 \(fromLogs)）")
            }
            if !officialModels.isEmpty, fromLogs == 0 {
                rowDaily[todayStr] = officialModels
                logger.info("CostCrawler: 今日逐模型走 usage/models 快速路径（\(officialModels.count) 个模型，日志接口不可用时的兜底）")
            }
        }
        if !rowDaily.isEmpty {
            let previous = WidgetDataStore.load()
            var merged: [String: DailyCost] = [:]
            for d in (previous?.dailyCosts ?? []) { merged[d.date] = d }
            // ⚠️ cost-by-day 只有「每天一个总额」，是无明细时的兜底 —— **不能覆盖**已有明细的天
            // （2026-09-19 实测：写成"覆盖"会把回填好的历史明细每轮冲掉，于是"所有密钥"永远纯色，
            //   而按 Key 视图走 dailyByKey 的合并逻辑、反而有颜色 —— 就是用户看到的怪现象）
            for d in daily where merged[d.date] == nil { merged[d.date] = d }
            // 2026-09-23 Phase 1：合并规则收敛到 UsageMerge（唯一一份"只增不减 / 细化优先"）
            let rowDailyList = rowDaily.map { DailyCost(date: $0.key, entries: $0.value) }
            daily = UsageMerge.mergeDaily(new: rowDailyList,
                                          into: merged.values.sorted { $0.date < $1.date })
            let byKey = UsageMerge.mergeByKey(new: UsageMerge.toByKeyDaily(rowByKey),
                                              into: previous?.dailyByKey ?? [:])
            daily = UsageMerge.applyUnionDetail(daily: daily, byKey: byKey)
            daily = Self.recomputeToday(daily, today: todayStr,
                                        logsToday: todayWindow.ok ? (rowDaily[todayStr] ?? [:]) : [:],
                                        officialToday: officialTodayModels,
                                        logWindowOK: todayWindow.ok)
            return MonthlyCost(daily: daily, keys: [], dailyByKey: byKey)
        }
        // 一条日志都没拿到（接口退化）：今天仍要用 `usage/models` 的权威值重算，
        // 否则那次错误写入会被"只增不减"永久锁死。
        guard !daily.isEmpty else {
            // cost-by-day 三个口径全挂、明细也没拿到 —— 这轮什么都没有，保留旧快照
            logger.warning("CostCrawler: cost-by-day 与 request-logs 本轮都不可用 → 保留旧快照")
            return nil
        }
        daily = Self.recomputeToday(daily, today: todayStr, logsToday: [:],
                                    officialToday: officialTodayModels, logWindowOK: false)
        return MonthlyCost(daily: daily, keys: [], dailyByKey: [:])
    }

    /// 2026-09-30：**今天这一格必须能被打扫干净** —— 一次错误写入（实测：半夜把昨天整天的
    /// $2.2893 写进了今天，界面卡在 $2.29 而实际只有 $0.51）在 `pickDay` 的"只增不减"下
    /// 永远出不来，用户怎么刷新都一样。
    ///
    /// 权威来源按顺序取（两者都是"今天整天"的口径，不是半窗）：
    ///   ① `request-logs` 的今天整天窗口（成功且非空时优先 —— 它带逐模型 + 逐 Key 明细）；
    ///   ② `usage/models?since=今天0点`（每轮都调，日志接口退化时兜底）。
    /// 两边都拿到时取**大的那个**（今天宁可不少算），差得离谱只记日志不猜。
    /// 都没有 → 一个字都不动（宁可用旧值，也不要把今天清成 0）。
    private static func recomputeToday(_ daily: [DailyCost], today: String,
                                       logsToday: [String: Double], officialToday: [String: Double],
                                       logWindowOK: Bool) -> [DailyCost] {
        let logsTotal = logsToday.values.reduce(0, +)
        let officialTotal = officialToday.values.reduce(0, +)
        let fresh: [String: Double]
        if !logsToday.isEmpty, logsTotal >= officialTotal * 0.98 {
            fresh = logsToday
        } else if !officialToday.isEmpty {
            fresh = officialToday
        } else {
            fresh = logsToday
        }
        guard !fresh.isEmpty else { return daily }
        if !logWindowOK, !officialToday.isEmpty {
            // 记录一次"日志不可用、走官方按模型兜底重算今天"，便于排障
            Logger(subsystem: "com.steve233.opencodego", category: "CostCrawler")
                .info("CostCrawler: 今天用 usage/models 权威值重算（日志窗口这轮不可用）")
        }
        return UsageMerge.overrideToday(daily: daily, today: today, fresh: fresh, authoritative: true)
    }

    // MARK: - 密钥列表（下拉框）

    /// 密钥目录：只有本次官网成功验证过的 active Key 才能进入下拉框。
    ///
    /// 2026-10-22 修：旧实现 401 后静默回退 `availableKeys`，于是 Legacy 下已吊销的
    /// “临时/方泽恩/丁雁”会无限期显示。现在把“登录失效 / 官网没有 Key / 临时网络故障”
    /// 分成不同状态；401/403 会立刻撤下旧列表并清除失效会话。
    func cachedOrFetchedKeys(force: Bool = false) async -> KeyDirectoryState {
        let suite = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
        let ws = suite?.string(forKey: "workspaceID") ?? ""
        let auth = suite?.string(forKey: "authCookie") ?? ""
        let session = suite?.string(forKey: "consoleSession") ?? ""
        let fingerprint = KeyDirectoryStore.fingerprint(
            workspaceID: ws, auth: auth, session: session
        )
        let previous = KeyDirectoryStore.load(defaults: suite)

        if !force, let previous,
           previous.status == .live,
           previous.sessionFingerprint == fingerprint,
           !previous.keys.isEmpty {
            return previous
        }

        guard !ws.isEmpty, !session.isEmpty || !auth.isEmpty else {
            let state = KeyDirectoryReducer.reduce(
                .loginRequired("缺少 workspace 或控制台登录信息"),
                previous: previous,
                sessionFingerprint: fingerprint
            )
            KeyDirectoryStore.save(state, defaults: suite)
            logger.warning("CostCrawler: Key 目录不可用 → 缺少 workspace / 控制台会话")
            return state
        }

        let cookie = Self.consoleCookieHeader(auth: auth, session: session)
        let result = await consoleFetchResult(
            path: "service-accounts", query: "", cookie: cookie, ws: ws
        )

        let outcome: KeyDirectoryFetchOutcome
        switch result {
        case .success(let data):
            if let list = ApiKeyInfo.parseConsoleKeys(data) {
                outcome = .fetched(list)
            } else {
                outcome = .temporaryFailure("密钥接口返回了无法解析的数据")
            }
        case .httpError(401), .httpError(403):
            outcome = .loginRequired("控制台登录已失效，请重新登录")
        case .httpError(let code):
            outcome = .temporaryFailure("密钥接口 HTTP \(code)")
        case .networkError:
            outcome = .temporaryFailure("网络异常，暂时无法验证 Key 列表")
        case .invalidURL:
            outcome = .temporaryFailure("密钥接口地址无效")
        }

        let state = KeyDirectoryReducer.reduce(
            outcome, previous: previous, sessionFingerprint: fingerprint
        )
        KeyDirectoryStore.save(state, defaults: suite)

        switch state.status {
        case .live:
            KeyDirectoryStore.clearRejectedSession(defaults: suite)
            logger.info("密钥目录刷新：\(state.keys.count) 把有效（\(state.detail ?? "无跳过项")）")
        case .loginRequired:
            // 只清控制台会话，不动 Go API Key / DeepSeek Key / 历史用量。
            suite?.removeObject(forKey: "consoleSession")
            suite?.removeObject(forKey: "selectedCostKeyId")
            suite?.synchronize()
            KeyDirectoryStore.rejectSession(fingerprint, defaults: suite)
            logger.error("密钥目录刷新：控制台登录失效 → 已撤下旧 Key，等待重新登录")
        case .noActiveKeys:
            suite?.removeObject(forKey: "selectedCostKeyId")
            suite?.synchronize()
            logger.info("密钥目录刷新：官网当前没有 active Key")
        case .temporaryFailure:
            logger.warning("密钥目录刷新失败：\(state.detail ?? "未知错误")；仅在同会话下保留上次已验证列表")
        }
        return state
    }

}
