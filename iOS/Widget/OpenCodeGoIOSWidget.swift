import SwiftUI
import WidgetKit

struct IOSWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let state: KeyDirectoryState?
}

struct IOSWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> IOSWidgetEntry {
        IOSWidgetEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                rolling: 8,
                weekly: 13,
                monthly: 74,
                rollingReset: Date().addingTimeInterval(6_900),
                weeklyReset: Date().addingTimeInterval(5 * 86_400),
                monthlyReset: Date().addingTimeInterval(15 * 86_400),
                costTotal: 2.35,
                costEntries: ["deepseek-v4.1-flash": 2.1, "glm-5.3": 0.25],
                dailyCosts: Self.placeholderDailyCosts(),
                updatedAt: Date()
            ),
            state: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (IOSWidgetEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IOSWidgetEntry>) -> Void) {
        let now = Date()
        completion(Timeline(
            entries: [loadEntry(date: now)],
            policy: .after(now.addingTimeInterval(30 * 60))
        ))
    }

    private func loadEntry(date: Date = Date()) -> IOSWidgetEntry {
        IOSWidgetEntry(
            date: date,
            snapshot: WidgetDataStore.load(),
            state: KeyDirectoryStore.load()
        )
    }

    private static func placeholderDailyCosts() -> [DailyCost] {
        let calendar = BillingCycle.calendar
        let formatter = ChartFormatters.day
        let today = calendar.startOfDay(for: Date())
        let values = [1.2, 0.8, 4.1, 1.5, 0.7, 3.2, 1.1]
        return (0..<7).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index - 6, to: today) else {
                return nil
            }
            return DailyCost(
                date: formatter.string(from: date),
                entries: [
                    "deepseek-v4.1-flash": values[index] * 0.72,
                    "glm-5.3": values[index] * 0.18,
                    ModelPalette.otherName: values[index] * 0.10,
                ]
            )
        }
    }
}

struct OpenCodeGoIOSWidgetView: View {
    let entry: IOSWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                accessoryView
            } else if let snapshot = entry.snapshot {
                if family == .systemSmall {
                    smallView(snapshot)
                } else {
                    mediumView(snapshot)
                }
            } else {
                emptyView
            }
        }
        .widgetURL(URL(string: "opencodego://refresh"))
    }

    private func mediumView(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            widgetHeader

            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 10) {
                    IOSWidgetQuotaLine(
                        label: "5小时",
                        value: snapshot.rolling,
                        reset: snapshot.rollingReset,
                        showsReset: true
                    )
                    IOSWidgetQuotaLine(
                        label: "周",
                        value: snapshot.weekly,
                        reset: snapshot.weeklyReset,
                        showsReset: true
                    )
                    IOSWidgetQuotaLine(
                        label: "月",
                        value: snapshot.monthly,
                        reset: snapshot.monthlyReset,
                        showsReset: true
                    )
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("近 7 天")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text("$\(IOSWidgetWeek.total(snapshot.dailyCosts), specifier: "%.2f") USD")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    IOSWidgetWeekChart(dailyCosts: snapshot.dailyCosts)
                        .frame(height: 66)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 0)
                .frame(maxHeight: 2)
            widgetFooter(snapshot)
        }
        .padding(16)
    }

    private func smallView(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            widgetHeader
            IOSWidgetQuotaLine(
                label: "5小时",
                value: snapshot.rolling,
                reset: snapshot.rollingReset,
                showsReset: false
            )
            IOSWidgetQuotaLine(
                label: "周",
                value: snapshot.weekly,
                reset: snapshot.weeklyReset,
                showsReset: false
            )
            IOSWidgetQuotaLine(
                label: "月",
                value: snapshot.monthly,
                reset: snapshot.monthlyReset,
                showsReset: false
            )
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline) {
                Text("今日")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("$\(snapshot.costTotal, specifier: "%.2f")")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
        }
        .padding(14)
    }

    private var widgetHeader: some View {
        HStack(spacing: 7) {
            BrandIconView(size: 15)
            Text("OpenCode Go")
                .font(.system(size: 12, weight: .bold))
            Spacer()
        }
    }

    private func widgetFooter(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 5) {
            Text("更新于 \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
            Spacer()
            if entry.state?.status == .loginRequired {
                Text("需重新登录")
                    .foregroundStyle(IOSTheme.warning)
            } else if let error = snapshot.error {
                Text(error)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.secondary)
    }

    private var accessoryView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                BrandIconView(size: 11)
                Text("OpenCode Go")
                    .font(.caption2.bold())
            }
            if let snapshot = entry.snapshot {
                Text("5h \(snapshot.rolling)% · 周 \(snapshot.weekly)% · 月 \(snapshot.monthly)%")
                    .font(.caption.monospacedDigit())
                Text("今日 $\(snapshot.costTotal, specifier: "%.2f")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("打开 App 同步数据")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            BrandIconView(size: 28)
            Text("OpenCode Go")
                .font(.caption.bold())
            Text(entry.state?.status == .loginRequired ? "打开 App 重新登录" : "打开 App 同步数据")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }
}

private struct IOSWidgetQuotaLine: View {
    let label: String
    let value: Int
    let reset: Date
    let showsReset: Bool

    private var clamped: Int { min(max(value, 0), 100) }
    private var tint: Color { IOSTheme.quotaColor(clamped) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(clamped)%")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
                if showsReset {
                    Text("· \(IOSWidgetReset.text(reset))")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(IOSTheme.track)
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * CGFloat(clamped) / 100)
                }
            }
            .frame(height: 4)
        }
    }
}

private enum IOSWidgetReset {
    static func text(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours >= 24 { return "\(hours / 24)d" }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }
}

private enum IOSWidgetWeek {
    static func dates() -> [Date] {
        let calendar = BillingCycle.calendar
        let today = calendar.startOfDay(for: Date())
        return (0..<7).compactMap {
            calendar.date(byAdding: .day, value: $0 - 6, to: today)
        }
    }

    static func total(_ daily: [DailyCost]) -> Double {
        let formatter = ChartFormatters.day
        let values = Dictionary(uniqueKeysWithValues: daily.map { ($0.date, $0) })
        return dates().reduce(0) { partial, date in
            partial + (values[formatter.string(from: date)]?.total ?? 0)
        }
    }
}

private struct IOSWidgetWeekChart: View {
    let dailyCosts: [DailyCost]

    private var values: [(date: Date, entries: [String: Double], total: Double)] {
        let formatter = ChartFormatters.day
        let map = Dictionary(uniqueKeysWithValues: dailyCosts.map { ($0.date, $0) })
        return IOSWidgetWeek.dates().map { date in
            let day = map[formatter.string(from: date)]
            return (date, day?.entries ?? [:], day?.total ?? 0)
        }
    }

    private var maximum: Double {
        max(0.01, (values.map(\.total).max() ?? 0) * 1.08)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(values, id: \.date) { value in
                VStack(spacing: 3) {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            ForEach(
                                ModelPalette.foldedEntries(value.entries)
                                    .sorted { $0.value > $1.value },
                                id: \.key
                            ) { item in
                                Rectangle()
                                    .fill(modelColor(item.key))
                                    .frame(
                                        height: geometry.size.height
                                            * CGFloat(item.value / maximum)
                                    )
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    }
                    .frame(height: 48)

                    Text(weekdayLabel(value.date))
                        .font(.system(size: 10, weight: isToday(value.date) ? .bold : .medium))
                        .foregroundStyle(isToday(value.date) ? IOSTheme.brand : Color.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "最近七天花费 \(String(format: "%.2f", IOSWidgetWeek.total(dailyCosts))) 美元"
        )
    }

    private func modelColor(_ model: String) -> Color {
        model == ModelPalette.otherName
            ? Color.secondary.opacity(0.45)
            : ModelPalette.color(for: model)
    }

    private func isToday(_ date: Date) -> Bool {
        BillingCycle.calendar.isDateInToday(date)
    }

    private func weekdayLabel(_ date: Date) -> String {
        let labels = ["日", "一", "二", "三", "四", "五", "六"]
        let index = BillingCycle.calendar.component(.weekday, from: date) - 1
        return labels[max(0, min(labels.count - 1, index))]
    }
}

struct OpenCodeGoIOSWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: PlatformConfig.widgetKind,
            provider: IOSWidgetProvider()
        ) { entry in
            OpenCodeGoIOSWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color(uiColor: .systemBackground)
                }
        }
        .configurationDisplayName("OpenCode Go")
        .description("近 7 天用量、三档额度与今日花费")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
        .contentMarginsDisabled()
    }
}

@main
struct OpenCodeGoIOSWidgetBundle: WidgetBundle {
    var body: some Widget {
        OpenCodeGoIOSWidget()
    }
}
