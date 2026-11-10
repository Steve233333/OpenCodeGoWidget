import SwiftUI
import WidgetKit

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
        Task {
            let now = Date()
            let cached = WidgetDataStore.load()
            let snapshot: WidgetSnapshot?
            if let cached, now.timeIntervalSince(cached.updatedAt) < 120 {
                snapshot = cached
            } else {
                snapshot = await WidgetSnapshotRefresher.refreshAllForWidget()
            }
            completion(makeTimeline(
                snapshot: snapshot,
                state: KeyDirectoryStore.load(),
                now: now
            ))
        }
    }

    private func makeTimeline(
        snapshot: WidgetSnapshot?,
        state: KeyDirectoryState?,
        now: Date
    ) -> Timeline<IOSWidgetEntry> {
        let policy = TimelineReloadPolicy.after(now.addingTimeInterval(30 * 60))
        guard let snapshot else {
            return Timeline(
                entries: [IOSWidgetEntry(date: now, snapshot: nil, state: state)],
                policy: policy
            )
        }

        var entries = [IOSWidgetEntry(date: now, snapshot: snapshot, state: state)]
        let resets: [(date: Date, window: QuotaWindow)] = [
            (snapshot.rollingReset, .rolling),
            (snapshot.weeklyReset, .weekly),
            (snapshot.monthlyReset, .monthly),
        ]
        for reset in resets
            .filter({ $0.date > now.addingTimeInterval(60) })
            .sorted(by: { $0.date < $1.date })
            .prefix(3) {
            var copy = snapshot
            switch reset.window {
            case .rolling:
                copy.rolling = 0
                copy.rollingReset = reset.date.addingTimeInterval(5 * 3_600)
            case .weekly:
                copy.weekly = 0
                copy.weeklyReset = reset.date.addingTimeInterval(7 * 86_400)
            case .monthly:
                copy.monthly = 0
                copy.monthlyReset = BillingCycle.calendar.date(
                    byAdding: .month,
                    value: 1,
                    to: reset.date
                ) ?? reset.date
            }
            entries.append(IOSWidgetEntry(date: reset.date, snapshot: copy, state: state))
        }
        return Timeline(entries: entries, policy: policy)
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

private enum QuotaWindow {
    case rolling, weekly, monthly
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
        .description("5 小时额度、近 7 天花费与模型用量")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
        ])
        .contentMarginsDisabled()
    }
}

@main
struct OpenCodeGoIOSWidgetBundle: WidgetBundle {
    var body: some Widget {
        OpenCodeGoIOSWidget()
    }
}
