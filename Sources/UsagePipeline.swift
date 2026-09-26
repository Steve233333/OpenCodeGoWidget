import Foundation
import os

/// 用量管线：**历史回填 + 进度 + 落盘**（2026-09-23 Phase 1 从 CostCrawler.swift 拆出）。
///
/// 和 `fetchConsoleAPI`（日常刷新）共用同一套合并规则（`UsageMerge`），不再各写一份守卫 ——
/// 这正是"某视图纯色 / 差一天 / 按 Key 对不上"反复复发的原因。
extension CostCrawler {

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
        let snap0 = WidgetDataStore.load()
        let missing = UsageMerge.daysMissingDetail(daily: snap0?.dailyCosts ?? [],
                                                   dailyByKey: snap0?.dailyByKey ?? [:])
        // 只有"跑完整轮且缺口没变"才跳过：半轮中断绝不写备忘录，否则自己把自己挡住。
        // 2026-09-26：数据源从 usage/rows 换成 request-logs，判定逻辑也换了（"官方没日志的天"要记成
        // skipped 而不是永远算缺）—— 所以给备忘录加一个 logic 版本：老备忘录没有它 → 强制重跑一轮，
        // 跑完写上新版本号，之后才不会每 5 分钟白跑。
        let memoLogic = "request-logs-v1"
        let lastMemo = suite?.dictionary(forKey: "historyRepairLast")
        let lastMissing = Set((lastMemo?["missing"] as? [String]) ?? [])
        // 2026-09-26：缺口没变也**每天重试一次** —— 官方日志库现在只有 9/19 之后的数据，
        // 哪天他们把更早的补回来，我们下一轮就自动填上（不然得手动清缓存）。
        let lastAt = (lastMemo?["at"] as? Date) ?? .distantPast
        let retryDue = Date().timeIntervalSince(lastAt) > 24 * 3600
        guard !missing.isEmpty,
              (missing != lastMissing || (lastMemo?["logic"] as? String) != memoLogic || retryDue) else { return false }
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

        // 2026-09-19 提速：不再从头串行翻 170 页，而是"缺哪天抓哪天"，4 天并行。
        // 2026-09-26：数据源换成 `request-logs`（`usage/rows` 已被官方撤掉，404）。
        // 它一次 export 最多 1000 条，超了会自动按时间中点二分（见 requestLogsInWindow）。
        let fmt = ChartFormatters.day
        // 官方日志只保留 30 天（`retentionDays: 30` 实测）——比这更早的天补不了，
        // 记进 `skipped` 之后不再重试（否则就是"每 5 分钟白试一次"的老毛病）。
        let retentionDays = 30
        let retentionStart = BillingCycle.calendar.startOfDay(
            for: Date().addingTimeInterval(-Double(retentionDays - 1) * 86400))
        var windows: [(day: String, start: Date, end: Date)] = []
        var beyondRetention: [String] = []
        for dayStr in missing.sorted() {
            guard let start = fmt.date(from: dayStr),
                  let end = BillingCycle.calendar.date(byAdding: .day, value: 1, to: start) else { continue }
            guard end > retentionStart else { beyondRetention.append(dayStr); continue }
            windows.append((dayStr, start, end))
        }
        guard !windows.isEmpty else {
            suite?.set(["missing": Array(missing), "skipped": beyondRetention,
                        "logic": memoLogic, "at": Date()],
                       forKey: "historyRepairLast")
            logger.info("CostCrawler: 缺的 \(missing.count) 天全在 30 天保留期外，不再重试")
            return false
        }
        logger.info("CostCrawler: 回填 \(windows.count) 天（每天一个窗口，4 并发；\(beyondRetention.count) 天超出 30 天保留期）")

        var total = 0
        var failedWindows = 0
        // 官方日志库不是无限往回都能查（实测 9/19 之前的窗口返回 0 条，虽然总额在 cost-by-day 里还有）。
        // 这种"查得到但确实没有日志"的天要当成**已知缺口**记下来，否则每轮回填都白试一次。
        var emptyLogDays: [String] = []
        // 这里不用 `requestLogsInWindows`：它的回调是按批的，分不出"哪一天是空的"。
        // 自己按 4 并发跑，每个任务带着自己的日期回来，空窗口才能落到具体哪一天。
        var idx = 0
        while idx < windows.count {
            let slice = Array(windows[idx..<min(idx + 4, windows.count)])
            idx += slice.count
            await withTaskGroup(of: (day: String, logs: [[String: Any]], ok: Bool).self) { group in
                for w in slice {
                    group.addTask {
                        let r = await self.requestLogsInWindow(cookie: cookie, ws: ws, start: w.start, end: w.end)
                        return (w.day, r.logs, r.ok)
                    }
                }
                for await r in group {
                    total += r.logs.count
                    if !r.ok {
                        // 2026-09-20：**半截数据一律不落盘**。以前把"某页失败的窗口"里的残留行也合并了，
                        // 于是整天被写成"只覆盖了几个小时"的小数（9/19 显示 $0.41、实际 $2.19）。
                        // 宁可不补，也不要拿半天数据冒充整天 —— 这天保持"缺明细"，下次刷新重抓。
                        failedWindows += 1
                        continue
                    }
                    if r.logs.isEmpty {
                        emptyLogDays.append(r.day)   // 这天官方就是没有日志 → 记进 skipped，不再重试
                        continue
                    }
                    self.mergeRowsIntoSnapshot(r.logs)   // 每批落盘：进度条往前走、中途被杀也不白跑
                }
            }
        }
        suite?.set(failedWindows, forKey: "historyBackfillFailedWindows")
        suite?.set(total, forKey: "historyBackfillLastCount")
        if failedWindows > 0 {
            // 有窗口失败 = 网络/接口问题 → 必须重试，不能记备忘把自己挡住
            // （用户实拍：挡了一次就永远补不回来）
            logger.warning("CostCrawler: 回填有 \(failedWindows) 个窗口失败（抓到 \(total) 条），不写备忘，下次刷新再试")
            return false
        }
        if total == 0 {
            // 2026-09-26：窗口全查通了、但一条都没有 —— 说明这几天官方**根本没有日志**
            // （实测 9/19 之前只有总额、没有请求记录）。这也是"已知缺口"，要记 skipped 后停手；
            // 以前这条分支会当成"接口抖动"直接 return，于是每 5 分钟白试一次。
            let skipped = Array(Set(beyondRetention + emptyLogDays)).sorted()
            suite?.set(["missing": Array(missing), "skipped": skipped,
                        "logic": memoLogic, "at": Date()],
                       forKey: "historyRepairLast")
            logger.info("CostCrawler: 回填窗口都查通了但官方没有日志（\(emptyLogDays.count) 天 + 超保留 \(beyondRetention.count) 天）→ 记为只能看总额，不再重试")
            return false
        }
        guard let snap = WidgetDataStore.load() else { return false }
        let still = UsageMerge.daysMissingDetail(daily: snap.dailyCosts, dailyByKey: snap.dailyByKey)
        let skipped = Array(Set(beyondRetention + emptyLogDays)).sorted()
        suite?.set(["missing": Array(missing), "skipped": skipped,
                    "logic": memoLogic, "at": Date()],
                   forKey: "historyRepairLast")
        logger.info("CostCrawler: 历史回填 \(total) 条，仍缺 \(still.count) 天，无日志/超保留 \(beyondRetention.count + emptyLogDays.count) 天")
        return true
    }

    /// 把这一轮爬到（或爬到一半）的**日志**并进快照；只补"没有明细的天"，不冲掉已经更细的。
    @discardableResult
    private func mergeRowsIntoSnapshot(_ collectedLogs: [[String: Any]]) -> Bool {
        let collected = UsageRows.rowsFromLogs(collectedLogs)
        guard !collected.isEmpty, var snap = WidgetDataStore.load() else { return false }
        let (daily, byKey) = UsageRows.aggregate(collected)
        // 同一个 UsageMerge：回填与日常刷新共用一套规则，不再各写一份守卫
        snap.dailyCosts = UsageMerge.mergeDaily(new: daily.map { DailyCost(date: $0.key, entries: $0.value) },
                                                into: snap.dailyCosts)
        snap.dailyByKey = UsageMerge.mergeByKey(new: UsageMerge.toByKeyDaily(byKey), into: snap.dailyByKey)
        snap.updatedAt = Date()
        return WidgetDataStore.save(snap)
    }
}
