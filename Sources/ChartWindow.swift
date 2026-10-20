import Foundation

/// 柱状图 Y 轴范围的唯一真源（2026-10-16 修「爆表」）。
///
/// 起因：以前这里写死 `min(max(top, 2.5), 6.0)` —— 单日超过 $6 时柱子直接冲出图外，
/// 用户看到的就是"爆表"（当天实际 $7.05，轴却停在 $6）。金额本来就会随用量增长，
/// 不能有固定天花板。
///
/// 规则：
///   * 下限 $2.5 —— 用量很小时图表别被拉得过高，看得清；
///   * 上限跟着数据走：`maxDaily * 1.2` 向上取整到 0.5 的整数倍，永远留出顶部留白；
///   * 不再设任何硬上限（数据多大轴就多高）。
///
/// 放在数据层（不是 UI）是为了让离线门禁能直接断言"不许有天花板"这条不变量。
enum ChartAxis {
    static let minTop: Double = 2.5
    static let headroom: Double = 1.2
    static let step: Double = 0.5

    /// 由「单日最大值」推出 Y 轴上界。
    static func yUpperBound(maxDaily: Double) -> Double {
        let scaled = max(0, maxDaily) * headroom
        let stepped = (scaled / step).rounded(.up) * step
        return max(minTop, stepped)
    }

    /// 完整范围（0 起）。
    static func yDomain(maxDaily: Double) -> ClosedRange<Double> {
        0...yUpperBound(maxDaily: maxDaily)
    }
}

/// 图表窗口的唯一真源。
///
/// - 账期：月重置日往前推一个日历月（`BillingCycle.billingDates`）
/// - 自然月：数据锚点（最后一天，取不到就今天）所在自然月
///
/// 柱子、顶部总数、以及以后任何「这段时间花了多少」的地方都必须走这里。
/// 2026-09-19 实拍 bug：顶部总数当时是把快照里所有天相加，于是新账期刚开、
/// 图是空的，数字却还挂着上一个自然月的 $24.11。
enum ChartWindow {
    static func dates(dailyCosts: [DailyCost], monthlyReset: Date?, alignment: ChartAlignment) -> [Date] {
        if alignment == .billing, let reset = monthlyReset {
            let d = BillingCycle.billingDates(monthlyReset: reset)
            if !d.isEmpty { return d }
        }
        // 2026-09-22 的注释已经过时：`ChartFormatters.day` 现在是 **Asia/Shanghai** 日界。
        // 这里必须用同一个 `BillingCycle.calendar`，否则月首/月尾和日 key 会各偏一天。
        let cal = BillingCycle.calendar
        // 2026-10-20：dailyCosts 不一定按日期排序；用“最大的日期”作锚点，
        // 否则最后插入的 9/30 会把窗口拉到 9 月（用户看到的“多/少一天”）。
        let refDate: Date = {
            let parsed = dailyCosts.compactMap { ChartFormatters.day.date(from: $0.date) }
            return parsed.max() ?? Date()
        }()
        guard let monthInterval = cal.dateInterval(of: .month, for: refDate),
              let days = cal.range(of: .day, in: .month, for: refDate) else { return [] }
        return days.compactMap { day -> Date? in
            cal.date(byAdding: .day, value: day - 1, to: monthInterval.start)
        }
    }

    /// 窗口内所有日期的字符串形式（与 `DailyCost.date` 同格式）
    static func dateKeys(dailyCosts: [DailyCost], monthlyReset: Date?, alignment: ChartAlignment) -> Set<String> {
        Set(dates(dailyCosts: dailyCosts, monthlyReset: monthlyReset, alignment: alignment)
            .map { ChartFormatters.day.string(from: $0) })
    }

    /// 窗口内的花费合计；窗口取不到时退回全部相加（宁可多算也别显示 0 骗人）
    static func total(dailyCosts: [DailyCost], monthlyReset: Date?, alignment: ChartAlignment) -> Double {
        let keys = dateKeys(dailyCosts: dailyCosts, monthlyReset: monthlyReset, alignment: alignment)
        guard !keys.isEmpty else { return dailyCosts.reduce(0) { $0 + $1.total } }
        return dailyCosts.filter { keys.contains($0.date) }.reduce(0) { $0 + $1.total }
    }
}
