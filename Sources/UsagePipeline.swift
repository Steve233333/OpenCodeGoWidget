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
        let still = UsageMerge.daysMissingDetail(daily: snap.dailyCosts, dailyByKey: snap.dailyByKey)
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
        let (daily, byKey) = UsageRows.aggregate(collected)
        // 同一个 UsageMerge：回填与日常刷新共用一套规则，不再各写一份守卫
        snap.dailyCosts = UsageMerge.mergeDaily(new: daily.map { DailyCost(date: $0.key, entries: $0.value) },
                                                into: snap.dailyCosts)
        snap.dailyByKey = UsageMerge.mergeByKey(new: UsageMerge.toByKeyDaily(byKey), into: snap.dailyByKey)
        snap.updatedAt = Date()
        return WidgetDataStore.save(snap)
    }
}
