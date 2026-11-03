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
                rolling: 42,
                weekly: 31,
                monthly: 18,
                rollingReset: Date().addingTimeInterval(3_600),
                weeklyReset: Date().addingTimeInterval(86_400),
                monthlyReset: Date().addingTimeInterval(604_800),
                costTotal: 0.82,
                costEntries: ["deepseek-v4.1-flash": 0.6, "glm-5.3": 0.22],
                dailyCosts: [],
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
}

struct OpenCodeGoIOSWidgetView: View {
    let entry: IOSWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .accessoryRectangular {
                accessoryView
            } else if let snapshot = entry.snapshot {
                standardView(snapshot)
            } else {
                emptyView
            }
        }
        .widgetURL(URL(string: "opencodego://refresh"))
    }

    private var accessoryView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("OpenCode Go").font(.caption2.bold())
            if let snapshot = entry.snapshot {
                Text("5h \(snapshot.rolling)% · 周 \(snapshot.weekly)% · 月 \(snapshot.monthly)%")
                    .font(.caption.monospacedDigit())
                Text("今日 $\(snapshot.costTotal, specifier: "%.2f")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("打开 App 登录").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func standardView(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                BrandIconView(size: 15)
                Text("OpenCode Go").font(.caption.bold())
                Spacer()
                Link(destination: URL(string: "opencodego://refresh")!) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.bold())
                }
            }

            if family == .systemSmall {
                IOSWidgetQuotaLine(label: "5h", value: snapshot.rolling)
                IOSWidgetQuotaLine(label: "周", value: snapshot.weekly)
                IOSWidgetQuotaLine(label: "月", value: snapshot.monthly)
                Spacer(minLength: 0)
                HStack {
                    Text("今日").foregroundStyle(.secondary)
                    Spacer()
                    Text("$\(snapshot.costTotal, specifier: "%.2f")")
                        .font(.caption.monospacedDigit().bold())
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 8) {
                        IOSWidgetQuotaLine(label: "5h", value: snapshot.rolling)
                        IOSWidgetQuotaLine(label: "周", value: snapshot.weekly)
                        IOSWidgetQuotaLine(label: "月", value: snapshot.monthly)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("近 7 天").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("$\(IOSWidgetWeek.total(snapshot.dailyCosts), specifier: "%.2f")")
                                .font(.caption2.monospacedDigit().bold())
                        }
                        IOSWidgetWeekChart(dailyCosts: snapshot.dailyCosts)
                            .frame(height: 56)
                    }
                }
            }

            HStack(spacing: 4) {
                Text(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))
                Spacer()
                if entry.state?.status == .loginRequired {
                    Text("需重登").foregroundStyle(.orange)
                } else if let error = snapshot.error {
                    Text(error).lineLimit(1)
                }
            }
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
        }
        .padding(family == .systemSmall ? 13 : 15)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            BrandIconView(size: 28)
            Text("OpenCode Go").font(.caption.bold())
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

    private var tint: Color {
        if value >= 80 { return .red }
        if value >= 50 { return .orange }
        return .green
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(label).font(.caption2)
                Spacer()
                Text("\(min(max(value, 0), 100))%")
                    .font(.caption2.monospacedDigit().bold())
                    .foregroundStyle(tint)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(tint)
                        .frame(width: geo.size.width * CGFloat(min(max(value, 0), 100)) / 100)
                }
            }
            .frame(height: 4)
        }
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
        max(1, values.map(\.total).max() ?? 0)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(values, id: \.date) { value in
                VStack(spacing: 2) {
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            ForEach(
                                ModelPalette.foldedEntries(value.entries)
                                    .sorted { $0.value > $1.value },
                                id: \.key
                            ) { item in
                                Rectangle()
                                    .fill(ModelPalette.color(for: item.key))
                                    .frame(height: geo.size.height * CGFloat(item.value / maximum))
                            }
                        }
                    }
                    .frame(height: 38)
                    Text(ChartFormatters.weekLabel.string(from: value.date))
                        .font(.system(size: 7))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
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
                    Color.clear
                }
        }
        .configurationDisplayName("OpenCode Go")
        .description("额度、今日与近 7 天花费")
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
