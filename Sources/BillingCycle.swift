import Foundation

enum ChartAlignment: String, Codable {
    case billing = "billing"   // 按 Go 套餐账期（月重置日对齐）
    case calendar = "calendar" // 按自然月
}

enum BillingCycle {
    static let suiteName = "2DC432GLL2.com.steve233.opencodego"
    static let alignmentKey = "chartAlignment"
    static let tz = TimeZone(identifier: "Asia/Shanghai")!

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    static func loadAlignment() -> ChartAlignment {
        guard let d = UserDefaults(suiteName: suiteName),
              let raw = d.string(forKey: alignmentKey),
              let v = ChartAlignment(rawValue: raw) else {
            return .billing // 默认账期，解决月中开套餐被自然月切断
        }
        return v
    }

    static func saveAlignment(_ v: ChartAlignment) {
        UserDefaults(suiteName: suiteName)?.set(v.rawValue, forKey: alignmentKey)
        UserDefaults(suiteName: suiteName)?.synchronize()
    }

    /// monthlyReset -> cycleStart（往前 1 个日历月，自动处理 31→30/28 截断）
    static func cycleStart(from monthlyReset: Date) -> Date {
        // 用当前 calendar（已设 Asia/Shanghai）在月历语义上减 1 月，保持日/时分秒锚点
        calendar.date(byAdding: .month, value: -1, to: monthlyReset) ?? monthlyReset.addingTimeInterval(-30*86400)
    }

    /// 账期包含的每天（Asia/Shanghai 午夜递增），左闭右开：[startDay, endDay)
    static func billingDates(monthlyReset: Date) -> [Date] {
        let start = cycleStart(from: monthlyReset)
        let cal = calendar
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: monthlyReset)
        guard endDay > startDay else { return [] }
        var dates: [Date] = []
        var cur = startDay
        // 正常账期 28-31 天；兜底 45 天防死循环
        var guardCount = 0
        while cur < endDay, guardCount < 45 {
            dates.append(cur)
            guard let nxt = cal.date(byAdding: .day, value: 1, to: cur) else { break }
            cur = nxt
            guardCount += 1
        }
        return dates
    }

    /// 用于过滤 dailyCosts 的字符串区间 [startStr, endStr)
    static func billingDateStrings(monthlyReset: Date) -> (start: String, end: String, dates: [Date]) {
        let dates = billingDates(monthlyReset: monthlyReset)
        let s = dates.first.map { ChartFormatters.day.string(from: $0) } ?? ""
        let e = ChartFormatters.day.string(from: calendar.startOfDay(for: monthlyReset))
        return (s, e, dates)
    }

    static func titleRange(monthlyReset: Date) -> String {
        let s = cycleStart(from: monthlyReset)
        let e = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: monthlyReset)) ?? monthlyReset
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "M月d日"
            f.locale = Locale(identifier: "zh_CN")
            f.timeZone = tz
            return f
        }()
        return "\(fmt.string(from: s))-\(fmt.string(from: e))"
    }

    static func subtitleDetail(monthlyReset: Date) -> String {
        let s = cycleStart(from: monthlyReset)
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "M月d日 HH:mm"
            f.locale = Locale(identifier: "zh_CN")
            f.timeZone = tz
            return f
        }()
        return "套餐生效 \(fmt.string(from: s)) — \(fmt.string(from: monthlyReset))"
    }

    /// 账期跨越的 (year, month0) 去重有序
    static func monthsInCycle(monthlyReset: Date) -> [(year: Int, month0: Int)] {
        let dates = billingDates(monthlyReset: monthlyReset)
        var seen = Set<String>()
        var out: [(Int, Int)] = []
        for d in dates {
            let c = calendar.dateComponents(in: tz, from: d)
            guard let y = c.year, let m = c.month else { continue }
            let key = "\(y)-\(m)"
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append((y, m - 1))
        }
        // 若账期尾月未被首日覆盖（如 8/18-9/18 的 9/18 当天未计入 billingDates），仍需补上尾月以展示 9/18 前的柱子
        // 上面已按左开右闭生成 8/18..<9/18 的天数，9 月已在 9/1..9/17 中出现，无需补；仅在 span<2 时兜底
        if out.isEmpty {
            let c = calendar.dateComponents(in: tz, from: monthlyReset)
            if let y = c.year, let m = c.month { out.append((y, m - 1)) }
            let sc = calendar.dateComponents(in: tz, from: cycleStart(from: monthlyReset))
            if let y = sc.year, let m = sc.month {
                let sKey = "\(y)-\(m)"
                if !seen.contains(sKey) { out.insert((y, m - 1), at: 0) }
            }
        }
        return out
    }
}
