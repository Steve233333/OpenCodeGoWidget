import Foundation

// 用量管线的离线回归测试（不联网、不依赖界面）。
// 编译运行：scripts/test-usage-pipeline.sh   （build.sh --test 里的门禁之一）
//
// 起因（2026-09-19 ~ 2026-09-23）："不许丢明细 / 日界一致 / 按 Key 与总额对得上"这几条不变量
// 以前散在 4~5 处各写一遍，改一处漏一处，于是"某些天纯色 / 差一天 / 按 Key 对不上"反复复发。
// 现在规则只有一份（UsageRows 认日、UsageMerge 合并），下面把 8 条不变量钉死在构造数据上。

var failures: [String] = []

func check(_ cond: Bool, _ label: String) {
    if cond { print("  ✅ \(label)") } else { failures.append(label); print("  ❌ \(label)") }
}

func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

/// 造一条 `usage/rows` 记录：`micro` 是微美分（100,000,000 = 1 美元）
func row(model: String, micro: Int, at: String, key: String?) -> [String: Any] {
    var r: [String: Any] = ["model": model, "costMicroCents": String(micro), "createdAt": at]
    if let key { r["serviceApiKeyId"] = key }
    return r
}

func entries(_ pairs: [(String, Double)]) -> [String: Double] {
    var out: [String: Double] = [:]
    for (k, v) in pairs { out[k] = v }
    return out
}

// MARK: - ① 北京时间 0 点切天

func testDayBoundary() {
    print("① 北京时间 0 点切天")
    check(UsageRows.dayString(createdAt: "2026-09-22T15:59:00.000Z") == "2026-09-22", "北京 23:59 的行算前一天")
    check(UsageRows.dayString(createdAt: "2026-09-22T16:00:30.000Z") == "2026-09-23", "北京 00:00 的行算新一天")
    check(UsageRows.dayString(createdAt: "2026-09-22T16:00:00Z") == "2026-09-23", "不带毫秒的 ISO8601 也认")
    check(UsageRows.dayString(createdAt: "不是时间") == nil, "解析不了的返回 nil（调用方兜底）")

    let rows = [row(model: "glm-5.3", micro: 100_000_000, at: "2026-09-22T15:59:59.000Z", key: "k1"),
                row(model: "glm-5.3", micro: 50_000_000, at: "2026-09-22T16:00:01.000Z", key: "k1")]
    let (daily, _) = UsageRows.aggregate(rows)
    check(near(daily["2026-09-22"]?["glm-5.3"] ?? 0, 1.0), "跨 0 点两侧的行分别归日（9/22 得 $1.00）")
    check(near(daily["2026-09-23"]?["glm-5.3"] ?? 0, 0.5), "跨 0 点两侧的行分别归日（9/23 得 $0.50）")

    // 「今日」格子必须用同一套日界：北京 0 点刚过就翻页，不许还停在昨天
    let mc = MonthlyCost(daily: [DailyCost(date: "2026-09-22", entries: entries([("glm-5.3", 2.18)])),
                                 DailyCost(date: "2026-09-23", entries: entries([("glm-5.3", 0.21)]))],
                         keys: [], dailyByKey: [:])
    let beforeMidnight = ISO8601DateFormatter().date(from: "2026-09-22T15:59:00Z")!
    let afterMidnight = ISO8601DateFormatter().date(from: "2026-09-22T16:01:00Z")!
    check(near(mc.todayEntries(for: beforeMidnight)["glm-5.3"] ?? 0, 2.18), "北京 23:59 的「今日」还是 9/22")
    check(near(mc.todayEntries(for: afterMidnight)["glm-5.3"] ?? 0, 0.21), "北京 00:01 的「今日」已翻到 9/23")
}

// MARK: - ② 增量片段幂等（重复拉不翻倍）

func testIncrementalIdempotent() {
    print("② 增量片段幂等")
    let rows = [row(model: "kimi-k3", micro: 60_000_000, at: "2026-09-22T02:00:00.000Z", key: "k1"),
                row(model: "glm-5.3", micro: 40_000_000, at: "2026-09-22T02:30:00.000Z", key: "k2")]
    let (raw, _) = UsageRows.aggregate(rows)
    let newDay = raw.map { DailyCost(date: $0.key, entries: $0.value) }

    var daily = UsageMerge.mergeDaily(new: newDay, into: [])
    daily = UsageMerge.mergeDaily(new: newDay, into: daily)   // 同一批再合并一次（每 5 分钟刷新的常态）
    daily = UsageMerge.mergeDaily(new: newDay, into: daily)
    let total = daily.first { $0.date == "2026-09-22" }?.total ?? -1
    check(near(total, 1.0), "同一天同一批行合并 3 次仍是 $1.00（不翻倍）")
    check(daily.count == 1, "没多出重复的天")
}

// MARK: - ③ 24h 半窗不许冲掉整天

func testHalfWindowDoesNotOverwriteFullDay() {
    print("③ 24h 半窗不冲掉整天")
    let old = DailyCost(date: "2026-09-19", entries: entries([("deepseek-v4-pro", 1.5), ("glm-5.3", 0.68)]))
    // 只覆盖"边界那天"几个小时 → $0.52；旧的是整天 $2.18
    let half = DailyCost(date: "2026-09-19", entries: entries([("deepseek-v4-pro", 0.52)]))
    let picked = UsageMerge.pickDay(new: half, old: old)
    check(near(picked.total, 2.18), "半窗 $0.52 不覆盖整天 $2.18")
    check(UsageMerge.hasModelDetail(picked.entries), "保下来的仍是带明细的那份")

    // 反例：新的确实更全（更多天/更多用量）就该用新的
    let fuller = DailyCost(date: "2026-09-19", entries: entries([("deepseek-v4-pro", 2.5)]))
    check(near(UsageMerge.pickDay(new: fuller, old: old).total, 2.5), "新的总额更大时用新的")

    // 只有总额（cost-by-day 兜底）时：明细优先，除非新总额明显更大（>5%）
    let totalOnly = DailyCost(date: "2026-09-19", entries: entries([("(total)", 2.2)]))
    check(near(UsageMerge.pickDay(new: totalOnly, old: old).total, 2.18), "只差一点点（<5%）不许用纯总额盖掉明细")
    let muchBigger = DailyCost(date: "2026-09-19", entries: entries([("(total)", 3.0)]))
    check(near(UsageMerge.pickDay(new: muchBigger, old: old).total, 3.0), "总额明显更大时先保钱（明细交给回填）")
}

// MARK: - ④ 按 Key 覆盖不足 → 需要回填

func testMissingDetailDetection() {
    print("④ 缺明细判定（触发回填）")
    let daily = [DailyCost(date: "2026-09-20", entries: entries([("glm-5.3", 1.0)])),      // 按 Key 只覆盖 50% → 缺
                 DailyCost(date: "2026-09-21", entries: entries([("glm-5.3", 1.0)])),      // 按 Key 覆盖满 → 不缺
                 DailyCost(date: "2026-09-22", entries: entries([("(total)", 3.0)]))]      // 只有总额 → 缺
    let byKey: [String: [DailyCost]] = [
        "k1": [DailyCost(date: "2026-09-20", entries: entries([("glm-5.3", 0.5)])),
               DailyCost(date: "2026-09-21", entries: entries([("glm-5.3", 0.6)]))],
        "k2": [DailyCost(date: "2026-09-21", entries: entries([("deepseek-v4-pro", 0.4)]))],
    ]
    let missing = UsageMerge.daysMissingDetail(daily: daily, dailyByKey: byKey)
    check(missing.contains("2026-09-20"), "按 Key 合计只有 50% 的天要回填")
    check(!missing.contains("2026-09-21"), "按 Key 合计 100% 的天不用回填")
    check(missing.contains("2026-09-22"), "只有「(total)」纯色的天要回填")
    check(UsageMerge.daysMissingDetail(daily: [], dailyByKey: [:]).isEmpty, "空快照不算缺口")
}

// MARK: - ⑤ 口径/账号变了 → 旧快照整体作废

func testCachePolicy() {
    print("⑤ 口径变了就整体作废（不许在旧数据上合并）")
    check(UsageMerge.CachePolicy.needsWipe(storedConvention: nil), "第一次运行（没有记录）要作废一次")
    check(UsageMerge.CachePolicy.needsWipe(storedConvention: "utc"), "旧的 UTC 口径要作废")
    check(!UsageMerge.CachePolicy.needsWipe(storedConvention: "local"), "已是北京时间口径就不再动数据")
    check(UsageMerge.CachePolicy.dayConventionValue == "local", "当前口径 = 北京时间（local）")
}

// MARK: - ⑥ 按天总额 == 按 Key 相加

func testPerKeySumsMatchDaily() {
    print("⑥ 按天总额 == 按 Key 相加")
    let rows = [row(model: "glm-5.3", micro: 30_000_000, at: "2026-09-21T01:00:00.000Z", key: "k1"),
                row(model: "kimi-k3", micro: 20_000_000, at: "2026-09-21T02:00:00.000Z", key: "k2"),
                row(model: "glm-5.3", micro: 50_000_000, at: "2026-09-22T01:00:00.000Z", key: "k2"),
                row(model: "muse-spark-1.2", micro: 70_000_000, at: "2026-09-22T03:00:00.000Z", key: "k2")]
    let (rawDaily, rawByKey) = UsageRows.aggregate(rows)
    let daily = rawDaily.map { DailyCost(date: $0.key, entries: $0.value) }
    let byKey = UsageMerge.toByKeyDaily(rawByKey)
    let perKey = UsageMerge.perKeySumByDay(byKey)
    for d in daily {
        check(near(perKey[d.date] ?? 0, d.total), "\(d.date)：按 Key 相加 = 当天总额")
    }
    check(daily.count == 2, "只有两天的数据（没有凭空多出的天）")
    check(byKey.keys.count == 2, "两条 Key 的拆分都在")

    // 现实里偶尔有行没带 serviceApiKeyId：它照样算进当天总额，但不进按 Key 视图 ——
    // 这正是 `daysMissingDetail` 用「按 Key 合计 < 总额 90%」兜底的原因（差额靠回填补齐）。
    let (rawDaily2, rawByKey2) = UsageRows.aggregate([row(model: "glm-5.3", micro: 100_000_000,
                                                         at: "2026-09-23T01:00:00.000Z", key: nil)])
    let daily2 = rawDaily2.map { DailyCost(date: $0.key, entries: $0.value) }
    let perKey2 = UsageMerge.perKeySumByDay(UsageMerge.toByKeyDaily(rawByKey2))
    check(near(daily2.first?.total ?? 0, 1.0) && (perKey2["2026-09-23"] ?? 0) == 0,
          "没带 Key 的行：算总额、不算按 Key（差额由回填补齐）")
}

// MARK: - ⑦ 纯色的天能靠按 Key 并集自愈（保钱又保颜色）

func testUnionDetailSelfHeal() {
    print("⑦ 按 Key 并集自愈（纯色 → 有颜色）")
    let daily = [DailyCost(date: "2026-09-18", entries: entries([("(total)", 1.00)]))]
    let full = ["k1": [DailyCost(date: "2026-09-18", entries: entries([("glm-5.3", 0.6)]))],
                "k2": [DailyCost(date: "2026-09-18", entries: entries([("kimi-k3", 0.4)]))]]
    let healed = UsageMerge.applyUnionDetail(daily: daily, byKey: full)
    check(healed.first?.entries.count == 2, "并集齐全 → 换成分模型明细（这天不再纯色）")
    check(near(healed.first?.total ?? 0, 1.00), "金额不变（保钱）")

    // 并集只是半天（<98%）→ 宁可继续纯色，也不许把金额改小
    let half = ["k1": [DailyCost(date: "2026-09-18", entries: entries([("glm-5.3", 0.3)]))]]
    let kept = UsageMerge.applyUnionDetail(daily: daily, byKey: half)
    check(near(kept.first?.total ?? 0, 1.00), "半天的并集（$0.30）不许替换 $1.00")
}

// MARK: - ⑧ 三视图相加 = 全部（所有密钥 = 各 Key 之和）

func testViewsAddUp() {
    print("⑧ 所有密钥视图 = 各 Key 相加")
    let rows = [row(model: "glm-5.3", micro: 64_300_000, at: "2026-09-22T01:00:00.000Z", key: "ding"),
                row(model: "mimo-v2.6", micro: 686_610_000, at: "2026-09-22T02:00:00.000Z", key: "fang"),
                row(model: "kimi-k3", micro: 12_000_000, at: "2026-09-22T03:00:00.000Z", key: "fang")]
    let (rawDaily, rawByKey) = UsageRows.aggregate(rows)
    let daily = rawDaily.map { DailyCost(date: $0.key, entries: $0.value) }
    let byKey = UsageMerge.toByKeyDaily(rawByKey)
    var union: [String: [String: Double]] = [:]
    for (_, arr) in byKey {
        for d in arr { for (m, v) in d.entries { union[d.date, default: [:]][m, default: 0] += v } }
    }
    let mc = MonthlyCost(daily: daily, keys: [ApiKeyInfo(id: "ding", displayName: "丁雁"),
                                              ApiKeyInfo(id: "fang", displayName: "方泽恩")],
                         dailyByKey: byKey)
    let all = mc.total
    let sumOfKeys = mc.daily(for: nil).map { $0.total }.reduce(0, +)
    let sumOfEach = ["ding", "fang"].map { mc.daily(for: $0).map { $0.total }.reduce(0, +) }.reduce(0, +)
    check(near(all, 7.6291), "所有密钥账期总额 = $7.6291")
    check(near(sumOfKeys, all), "按天相加 = 总额")
    check(near(sumOfEach, all), "各 Key 相加 = 总额（三视图对得上）")
    let todayStr = "2026-09-22"
    check(near(union[todayStr, default: [:]].values.reduce(0, +), all), "并集口径同样等于总额")
}

// MARK: - ⑨~⑬ request-logs（2026-09-26 数据源迁移：usage/rows 已被官方撤掉）

/// 造一条 `request-logs` 记录（cost 是**美元**、startedAt 是 **epoch 毫秒**）
func logItem(model: String?, requested: String? = nil, cost: Double,
             startedAt: Double, key: String? = nil, id: String = UUID().uuidString) -> [String: Any] {
    var it: [String: Any] = ["cost": cost, "startedAt": startedAt, "id": id]
    if let model { it["model"] = model }
    if let requested { it["requestedModel"] = requested }
    if let key { it["serviceAPIKeyID"] = key }
    return it
}

func isoMs(_ s: String) -> Double {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return (f.date(from: s)?.timeIntervalSince1970 ?? 0) * 1000
}

func dayOfRow(_ row: [String: Any]?) -> String? {
    guard let s = row?["createdAt"] as? String else { return nil }
    return UsageRows.dayString(createdAt: s)
}

func testLogRowMapping() {
    print("⑨ request-logs → 行映射")
    let late = UsageRows.rowFromLog(logItem(model: "glm-5.3", cost: 1.5,
                                            startedAt: isoMs("2026-09-22T15:59:00.000Z"), key: "k1"))
    let early = UsageRows.rowFromLog(logItem(model: "glm-5.3", cost: 0.25,
                                             startedAt: isoMs("2026-09-22T16:00:00.000Z"), key: "k1"))
    check(dayOfRow(late) == "2026-09-22", "北京 23:59 的日志算前一天")
    check(dayOfRow(early) == "2026-09-23", "北京 00:00 的日志算新一天")
    check(late?["costMicroCents"] as? String == "150000000", "$1.5 → 150,000,000 微美分")
    check(UsageRows.rowFromLog(logItem(model: nil, requested: "deepseek-v4.1-flash-go", cost: 0.1,
                                       startedAt: isoMs("2026-09-25T03:00:00.000Z")))?["model"] as? String
          == "deepseek-v4.1-flash-go", "model 缺失时回退 requestedModel")
    check(UsageRows.rowFromLog(logItem(model: "x", cost: 0.1, startedAt: 0)) == nil, "没有 startedAt → 丢掉")
    check(UsageRows.rowFromLog(["cost": 1, "startedAt": isoMs("2026-09-25T03:00:00.000Z")]) == nil,
          "model / requestedModel 都没有 → 丢掉")
    check(UsageRows.rowFromLog(logItem(model: "x", cost: 0.05,
                                       startedAt: isoMs("2026-09-25T03:00:00.000Z")))?["serviceApiKeyId"] == nil,
          "没有 key 也不崩（只是不进按 Key 拆分）")
    check(UsageRows.rowsFromLogs([["bad": 1], logItem(model: "y", cost: 0.01,
                                                      startedAt: isoMs("2026-09-25T03:00:00.000Z"))]).count == 1,
          "一批里坏的丢掉、好的留下")
}

func testHourlyCostToBeijingDay() {
    print("⑩ 小时桶 → 北京时间归日")
    let json: [[String: Any]] = [
        ["date": "2026-09-22T15:00:00Z", "totalCostMicroCents": "30000000"],   // 北京 23:00 → 9/22
        ["date": "2026-09-22T16:00:00Z", "totalCostMicroCents": "20000000"],   // 北京 00:00 → 9/23
        ["date": "2026-09-22T17:00:00Z", "totalCostMicroCents": "10000000"],   // 北京 01:00 → 9/23
    ]
    let daily = UsageRows.dailyFromHourlyCost(json)
    let map = Dictionary(uniqueKeysWithValues: daily.map { ($0.date, $0) })
    check(near(map["2026-09-22"]?.total ?? 0, 0.30), "16:00Z 之前的桶算 9/22（$0.30）")
    check(near(map["2026-09-23"]?.total ?? 0, 0.30), "16:00Z 之后算 9/23（$0.20+$0.10）")
    check(map["2026-09-22"]?.entries.keys.first == UsageRows.totalOnlyKey, "兜底天用 (total) 占位")
    check(UsageRows.dailyFromHourlyCost("不是数组").isEmpty, "畸形输入返回空")
}

func testWindowSplitDecision() {
    print("⑪ 超 1000 条时的二分判据")
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let mid = UsageRows.windowMidpoint(start: start, end: start.addingTimeInterval(86400))
    check(mid != nil && abs((mid?.timeIntervalSince(start) ?? 0) - 43200) < 1, "一天窗口切成两半")
    check(UsageRows.windowMidpoint(start: start, end: start.addingTimeInterval(60)) == nil,
          "窗口 <120s 不再切（避免病态递归）")
}

func testTotalMismatchGuard() {
    print("⑫ 合计 vs 明细同源护栏（305% 事故）")
    check(UsageMerge.totalMismatch(entries: entries([("deepseek-v4.1-flash", 0.3421),
                                                     ("deepseek-v4-flash", 0.0041)]), total: 0.11196),
          "明细 $0.346 / 合计 $0.112 → 判定对不上（记日志）")
    check(!UsageMerge.totalMismatch(entries: entries([("a", 0.30), ("b", 0.20)]), total: 0.50),
          "同源 → 正常")
    check(!UsageMerge.totalMismatch(entries: entries([("a", 0.30)]), total: 0.302), "1% 内的零头不算不一致")
    check(UsageMerge.totalMismatch(entries: [:], total: 1.0), "没有明细却报有金额 → 也算对不上")
}

func testLogsEndToEnd() {
    print("⑬ 日志 → 行 → 聚合 → 缺明细判定（端到端）")
    let logs: [[String: Any]] = [
        logItem(model: "deepseek-v4.1-flash", cost: 0.20, startedAt: isoMs("2026-09-25T02:00:00.000Z"), key: "key_A"),
        logItem(model: "deepseek-v4.1-flash", cost: 0.05, startedAt: isoMs("2026-09-25T03:00:00.000Z"), key: "key_B"),
        logItem(model: "glm-5.3", cost: 0.03, startedAt: isoMs("2026-09-25T04:00:00.000Z"), key: "key_A"),
    ]
    let rows = UsageRows.rowsFromLogs(logs)
    check(rows.count == 3, "3 条日志都映射成行")
    let (daily, byKey) = UsageRows.aggregate(rows)
    check(near(daily["2026-09-25"]?["deepseek-v4.1-flash"] ?? 0, 0.25), "按模型聚合 $0.25")
    check(near(byKey["key_A"]?["2026-09-25"]?["glm-5.3"] ?? 0, 0.03), "按 Key 聚合跟得上")
    let dailyList = daily.map { DailyCost(date: $0.key, entries: $0.value) }
    let byKeyList = byKey.mapValues { $0.map { DailyCost(date: $0.key, entries: $0.value) } }
    check(UsageMerge.daysMissingDetail(daily: dailyList, dailyByKey: byKeyList).isEmpty,
          "日志明细齐全 → 这天不再算'缺明细'")
}

@main
struct UsagePipelineTestRunner {
    static func main() {
        testDayBoundary()
        testIncrementalIdempotent()
        testHalfWindowDoesNotOverwriteFullDay()
        testMissingDetailDetection()
        testCachePolicy()
        testPerKeySumsMatchDaily()
        testUnionDetailSelfHeal()
        testViewsAddUp()
        testLogRowMapping()
        testHourlyCostToBeijingDay()
        testWindowSplitDecision()
        testTotalMismatchGuard()
        testLogsEndToEnd()

        if failures.isEmpty {
            print("\n全部通过 ✅")
            exit(0)
        } else {
            print("\n失败 \(failures.count) 项 ❌")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
    }
}
