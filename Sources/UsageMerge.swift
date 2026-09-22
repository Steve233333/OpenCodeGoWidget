import Foundation
import os

/// 用量快照的**唯一合并规则**（2026-09-23 Phase 1 收敛）。
///
/// 背景：以前"不许丢明细"这条不变量在 4~5 个地方各写了一遍（两条抓取路径各一套守卫、
/// `preferDetail`、`applyUnionDetail`、`daysMissingDetail`），规则稍有出入就会出现
/// "某些天变纯色 / 差一天 / 按 Key 对不上总额"这类 bug（9/19–9/23 复发了 4 次）。
/// 现在**只在这里定义**，`fetchConsoleAPI`（增量/24h）与按天回填都必须调用它。
enum UsageMerge {
    private static let logger = Logger(subsystem: "com.steve233.opencodego", category: "UsageMerge")

    /// 判断一天的 entries 里有没有"逐模型明细"（`(total)` 是只有总额时的占位）
    static func hasModelDetail(_ entries: [String: Double]) -> Bool {
        entries.contains { $0.key != "(total)" && $0.value > 0 }
    }

    /// 同一天新旧两份数据取谁。规则（按优先级）：
    /// 1. 旧的没有 → 用新的；
    /// 2. 新的只有 `(total)`、旧的有明细：只有新的总额**明显更大**（>5%）才用新的
    ///    —— 说明旧明细漏了用量，先让钱对，明细随后由回填重抓；否则保留更细的旧数据；
    /// 3. 新的有明细：旧的总额比新的还大（>0.1%）就保留旧的
    ///    —— 24h/增量窗口只覆盖"边界那天"的一部分，不能把整天冲成半窗；
    /// 4. 其余情况用新的。
    static func pickDay(new: DailyCost, old: DailyCost?) -> DailyCost {
        guard let old else { return new }
        let newHasDetail = hasModelDetail(new.entries)
        let oldHasDetail = hasModelDetail(old.entries)
        if !newHasDetail, oldHasDetail {
            return new.total > old.total * 1.05 ? new : old
        }
        if newHasDetail, !oldHasDetail {
            return new
        }
        return old.total > new.total * 1.001 ? old : new
    }

    /// 合并整天数组（按日期）：旧的没提到的新天补齐，同一天走 `pickDay`
    static func mergeDaily(new: [DailyCost], into old: [DailyCost]) -> [DailyCost] {
        var map: [String: DailyCost] = [:]
        for d in old { map[d.date] = d }
        for d in new { map[d.date] = pickDay(new: d, old: map[d.date]) }
        return map.values.sorted { $0.date < $1.date }
    }

    /// 合并「按 Key」的每天数组
    static func mergeByKey(new: [String: [DailyCost]], into old: [String: [DailyCost]]) -> [String: [DailyCost]] {
        var out: [String: [DailyCost]] = [:]
        let allKeys = Set(new.keys).union(old.keys)
        for key in allKeys {
            out[key] = mergeDaily(new: new[key] ?? [], into: old[key] ?? [])
        }
        return out
    }

    /// 抓取结果的原始形状 `[keyId: [date: [model: cost]]]` → `[keyId: [DailyCost]]`
    static func toByKeyDaily(_ raw: [String: [String: [String: Double]]]) -> [String: [DailyCost]] {
        var out: [String: [DailyCost]] = [:]
        for (key, byDate) in raw {
            out[key] = byDate.map { DailyCost(date: $0.key, entries: $0.value) }.sorted { $0.date < $1.date }
        }
        return out
    }

    /// 自愈：所有密钥视图的每天数据，若"各 Key 明细的并集"比它更细，就用并集。
    /// 并集金额明显偏小（<98%）= 那份并集只是半天，拒绝替换；只有"这天现在只是官方总额、
    /// 并集只差一点点"时才按现有总额等比归一并集（既保钱又拿颜色）。
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

    /// 按 Key 覆盖：date -> 该日"各 Key 合计"
    static func perKeySumByDay(_ dailyByKey: [String: [DailyCost]]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (_, arr) in dailyByKey {
            for d in arr { out[d.date, default: 0] += d.total }
        }
        return out
    }

    /// 哪天需要回填：
    /// ① 没有逐模型明细（只有 `(total)`）；或 ② 按 Key 合计不足当天总额 90%
    /// （控制台每行都带 serviceApiKeyId，正常应≈100%）。
    /// 参数用「值」而不是 `WidgetSnapshot`：规则层不依赖快照/文件 IO 类型，离线测试只编译纯数据层。
    static func daysMissingDetail(daily: [DailyCost], dailyByKey: [String: [DailyCost]]) -> Set<String> {
        let perKey = perKeySumByDay(dailyByKey)
        var out: Set<String> = []
        for d in daily {
            guard d.total > 0 else { continue }
            let keySum = perKey[d.date] ?? 0
            if !hasModelDetail(d.entries) || keySum < d.total * 0.9 { out.insert(d.date) }
        }
        return out
    }

    /// 快照缓存的口径策略（2026-09-23 Phase 1 收敛）：口径变了就**整体作废**一次，
    /// 不许在旧口径的数据上做增量合并（合并是"保留旧天"的，旧数字会永远追不上新口径）。
    /// 放在纯数据层是为了能离线回归测试（见 Tests/UsagePipelineTests.swift ⑤）。
    enum CachePolicy {
        static let dayConventionKey = "usageDayConvention"
        /// `local` = 北京时间 0 点翻页（2026-09-23 用户拍板）。
        static let dayConventionValue = "local"
        static func needsWipe(storedConvention: String?) -> Bool {
            storedConvention != dayConventionValue
        }
    }
}
