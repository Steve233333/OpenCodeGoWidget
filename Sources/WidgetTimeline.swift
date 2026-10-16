import Foundation

/// 磁贴小组件的**时间线刷新节奏**（2026-10-16 修「不重启电脑就不刷新」）。
///
/// 事故现场（chronod 日志）：
/// ```
/// Not checking cache (timelineExhausted)
/// entry count: 1
/// date range: 15:34:48 … 15:34:48     ← 起点=终点，时间线一出生就过期
/// ```
///
/// 旧代码把下次刷新时间算成 `快照时间 + 2 分钟`。快照越旧，这个时间越落在**过去** ——
/// 交给系统时已经是"已耗尽（timelineExhausted）"，于是系统把它丢进预算队列往后拖，
/// 表现就是小组件卡住不动、只有重启电脑（chronod 重来）才恢复。
/// 偏偏"数据已经旧了"正是最该刷新的场景，逻辑上正好反过来。
///
/// 现在改成「当前时间 + 固定间隔」，永远指向未来；间隔也调到预算友好的量级 ——
/// WidgetKit 每天只给几十次刷新，2 分钟一次会被限流成更长的间隔，15 分钟既够及时
/// 又不会把额度烧光。主 App 在跑时另有推送（`reloadTimelines`），这里只是它没跑时的兜底。
enum WidgetTimeline {
    /// 小组件自己轮询的间隔（秒）。
    static let pollInterval: TimeInterval = 15 * 60
    /// 交给系统的刷新时间至少离现在这么久，避免任何"过去时间"再次把时间线判死。
    static let minimumLead: TimeInterval = 60

    /// 下次请求时间线的时刻（永远在未来）。
    static func nextRefreshDate(now: Date) -> Date {
        max(now.addingTimeInterval(pollInterval), now.addingTimeInterval(minimumLead))
    }

    /// 时间线条目是否"还活着"（有未来覆盖）—— 用来在测试里断言不会再出现起点=终点。
    static func timelineIsExhausted(now: Date, nextRefresh: Date) -> Bool {
        nextRefresh <= now
    }
}
