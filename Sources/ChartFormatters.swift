import Foundation

/// 日期/口径格式化的**唯一真源**（2026-09-23 Phase 1 从 ModelPalette.swift 拆出）。
///
/// 这里不许 import SwiftUI：数据层（日界、回填窗口、快照比较）都要用它，
/// 混在 UI 文件里会让测试无法只编译数据层。
/// **日界 = 北京时间 0 点**（用户 2026-09-23 拍板），全 App 只有 `day` 定义了"一天从哪开始"。

struct DayModelCost: Identifiable {
    let id = UUID()
    let date: Date
    let model: String
    let cost: Double
}

enum ChartFormatters {
    /// 日界真源（2026-09-23 用户拍板）：**北京时间 0 点翻页**。
    /// 曾经短暂改成 UTC（为了和官网 `cost-by-day` 的 UTC 日逐天 0 差），但代价是日界落在早上 8 点，
    /// 用户明确要求"过了 0 点就重置"，所以回到 Asia/Shanghai。
    /// 全 App 只有这一处定义日界，其他所有地方（todayEntries / 回填窗口 / 小组件）都必须复用它，
    /// 否则就会出现"总额 0、模型拆分还有数"这种双口径 bug（2026-09-23 实拍）。
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()
    static let monthLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月 dd"
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()
    static let billingLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()
    static let weekLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/dd"
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()
}
