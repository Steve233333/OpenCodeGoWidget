import Foundation

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
        // 2026-09-22：月界必须用 **UTC 日历** —— 下面用 ChartFormatters.day 把日期转成 key，
        // 而它现在是 UTC 日界。以前这里用默认本地日历取月首（9/1 00:00+08 = 8/31 16:00Z），
        // 转成 key 就变成 8/31 → 整个自然月窗口偏一天：多算上月最后一天、少算本月最后一天。
        // 实测本月花费 $30.95（含 8/31 的 $1.29），正确口径应为 $29.66。
        let cal = BillingCycle.calendar
        let refDate: Date = {
            if let last = dailyCosts.last?.date,
               let d = ChartFormatters.day.date(from: last) { return d }
            return Date()
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
