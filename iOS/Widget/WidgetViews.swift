import SwiftUI
import WidgetKit

struct IOSWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let state: KeyDirectoryState?
}

struct OpenCodeGoIOSWidgetView: View {
    let entry: IOSWidgetEntry
    var previewFamily: WidgetFamily? = nil

    @Environment(\.widgetFamily) private var environmentFamily

    private var family: WidgetFamily {
        previewFamily ?? environmentFamily
    }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemSmall:
                    smallView(snapshot)
                case .systemMedium:
                    mediumView(snapshot)
                case .systemLarge:
                    largeView(snapshot)
                case .accessoryRectangular:
                    accessoryRectangular(snapshot)
                case .accessoryCircular:
                    accessoryCircular(snapshot)
                case .accessoryInline:
                    accessoryInline(snapshot)
                default:
                    mediumView(snapshot)
                }
            } else {
                emptyView
            }
        }
        .widgetURL(URL(string: "opencodego://overview"))
    }

    // MARK: - System widgets

    private func smallView(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            widgetHeader

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("5 小时")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text("已用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(clamped(snapshot.rolling))")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(IOSTheme.quotaTextColor(snapshot.rolling))
                Text("%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(IOSTheme.quotaTextColor(snapshot.rolling))
            }

            WidgetBar(percent: snapshot.rolling, tint: IOSTheme.quotaBarColor(snapshot.rolling), height: 4)
            WidgetResetLine(reset: snapshot.rollingReset)

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                Text("周 \(clamped(snapshot.weekly))%")
                Text(" · 月 \(clamped(snapshot.monthly))%")
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(14)
    }

    private func mediumView(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            widgetHeader

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("5 小时")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(clamped(snapshot.rolling))")
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(IOSTheme.quotaTextColor(snapshot.rolling))
                            Text("%")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(IOSTheme.quotaTextColor(snapshot.rolling))
                        }
                    }

                    WidgetBar(percent: snapshot.rolling, tint: IOSTheme.quotaBarColor(snapshot.rolling), height: 4)
                    WidgetResetLine(reset: snapshot.rollingReset)

                    HStack(spacing: 0) {
                        Text("周 \(clamped(snapshot.weekly))%")
                        Text(" · 月 \(clamped(snapshot.monthly))%")
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(width: 124, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("近 7 天")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        Text("$\(WidgetWeek.total(snapshot.dailyCosts), specifier: "%.2f")")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    WidgetBarChart(days: WidgetWindow.days(snapshot.dailyCosts, count: 7), height: 52)
                }
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            widgetFooter(snapshot)
        }
        .padding(16)
    }

    private func largeView(_ snapshot: WidgetSnapshot) -> some View {
        let days = WidgetWindow.days(snapshot.dailyCosts, count: 14)
        let periodTotal = WidgetWindow.periodTotal(snapshot)
        let models = WidgetWindow.topModels(snapshot, limit: 3)
        let maxAmount = max(models.map(\.amount).max() ?? 0, 0.01)
        let trendTotal = days.reduce(0) { $0 + $1.total }

        return VStack(alignment: .leading, spacing: 8) {
            widgetHeader

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("5 小时")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("已用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(clamped(snapshot.rolling))")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(IOSTheme.quotaTextColor(snapshot.rolling))
                Text("%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(IOSTheme.quotaTextColor(snapshot.rolling))
            }

            WidgetBar(percent: snapshot.rolling, tint: IOSTheme.quotaBarColor(snapshot.rolling), height: 4)
            WidgetResetLine(reset: snapshot.rollingReset)

            HStack(spacing: 0) {
                Text("周 \(clamped(snapshot.weekly))%")
                Text(" · 月 \(clamped(snapshot.monthly))%")
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("近 14 天")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text("$\(trendTotal, specifier: "%.2f")")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .padding(.top, 2)

            WidgetBarChart(days: days, height: 62)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("本期模型")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text("$\(periodTotal, specifier: "%.2f")")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .padding(.top, 2)

            if models.isEmpty {
                Text("暂无模型花费")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 5) {
                    let tints: [Color] = [IOSTheme.brand, IOSTheme.lime, IOSTheme.sand]
                    ForEach(Array(models.enumerated()), id: \.offset) { pair in
                        let tint = tints[pair.offset % tints.count]
                        HStack(spacing: 6) {
                            Circle()
                                .fill(tint)
                                .frame(width: 6, height: 6)
                            Text(ModelPalette.displayName(pair.element.model))
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("$\(pair.element.amount, specifier: "%.2f")")
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                            WidgetBar(
                                percent: Int((pair.element.amount / maxAmount * 100).rounded()),
                                tint: tint.opacity(0.85),
                                height: 3
                            )
                            .frame(width: 50)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            widgetFooter(snapshot)
        }
        .padding(16)
    }

    // MARK: - Lock screen

    private func accessoryRectangular(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text("5h")
                    .font(.caption2.bold())
                Text("\(clamped(snapshot.rolling))%")
                    .font(.caption.monospacedDigit().bold())
                Text("· 周 \(clamped(snapshot.weekly))%")
                    .font(.caption2.monospacedDigit())
                Text("· 月 \(clamped(snapshot.monthly))%")
                    .font(.caption2.monospacedDigit())
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)

            WidgetResetLine(reset: snapshot.rollingReset)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accessoryCircular(_ snapshot: WidgetSnapshot) -> some View {
        let percent = clamped(snapshot.rolling)
        return ZStack {
            Circle()
                .stroke(IOSTheme.track, lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(
                    IOSTheme.brand,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(percent)%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("5h")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("5 小时额度，已用 \(percent)%")
    }

    private func accessoryInline(_ snapshot: WidgetSnapshot) -> some View {
        Text("5h \(clamped(snapshot.rolling))% · 周 \(clamped(snapshot.weekly))% · 月 \(clamped(snapshot.monthly))%")
    }

    // MARK: - Shared pieces

    private var widgetHeader: some View {
        HStack(spacing: 6) {
            BrandIconView(size: 14)
            Text("OpenCode Go")
                .font(.system(size: 12, weight: .bold))
            Spacer()
        }
    }

    private func widgetFooter(_ snapshot: WidgetSnapshot) -> some View {
        let quotaAt = snapshot.quotaUpdatedAt ?? snapshot.updatedAt
        let costAt = snapshot.updatedAt
        let sameTime = abs(quotaAt.timeIntervalSince(costAt)) < 60
        let timeText = sameTime
            ? "更新于 \(costAt.formatted(date: .omitted, time: .shortened))"
            : "额度 \(quotaAt.formatted(date: .omitted, time: .shortened)) · 花费 \(costAt.formatted(date: .omitted, time: .shortened))"

        return HStack(spacing: 4) {
            Text(timeText)
            Spacer(minLength: 4)
            if entry.state?.status == .loginRequired {
                Text("需重新登录")
                    .foregroundStyle(IOSTheme.warning)
            } else if let error = snapshot.error {
                Text(error)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
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

    private func clamped(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }
}

private struct WidgetBar: View {
    let percent: Int
    let tint: Color
    let height: CGFloat

    private var clamped: Double {
        Double(min(max(percent, 0), 100)) / 100
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(IOSTheme.track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, geometry.size.width * clamped))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct WidgetResetLine: View {
    let reset: Date

    var body: some View {
        (Text(reset, style: .relative) + Text("后重置"))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

private struct WidgetDay: Identifiable {
    let date: Date
    let total: Double
    var id: Date { date }
}

private struct WidgetModel: Identifiable {
    let model: String
    let amount: Double
    var id: String { model }
}

private enum WidgetWindow {
    static func days(_ daily: [DailyCost], count: Int) -> [WidgetDay] {
        let formatter = ChartFormatters.day
        let map = Dictionary(uniqueKeysWithValues: daily.map { ($0.date, $0) })
        let calendar = BillingCycle.calendar
        let today = calendar.startOfDay(for: Date())
        return (0..<count).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index - count + 1, to: today) else {
                return nil
            }
            let key = formatter.string(from: date)
            return WidgetDay(date: date, total: map[key]?.total ?? 0)
        }
    }

    static func total(_ daily: [DailyCost]) -> Double {
        days(daily, count: 7).reduce(0) { $0 + $1.total }
    }

    static func periodTotal(_ snapshot: WidgetSnapshot) -> Double {
        ChartWindow.total(
            dailyCosts: snapshot.dailyCosts,
            monthlyReset: snapshot.monthlyReset,
            alignment: .billing
        )
    }

    static func topModels(_ snapshot: WidgetSnapshot, limit: Int) -> [WidgetModel] {
        let keys = ChartWindow.dateKeys(
            dailyCosts: snapshot.dailyCosts,
            monthlyReset: snapshot.monthlyReset,
            alignment: .billing
        )
        var totals: [String: Double] = [:]
        for day in snapshot.dailyCosts where keys.contains(day.date) {
            for (model, amount) in day.entries where amount > 0 {
                totals[model, default: 0] += amount
            }
        }
        return ModelPalette.foldedEntries(totals)
            .map { WidgetModel(model: $0.key, amount: $0.value) }
            .sorted { lhs, rhs in
                if abs(lhs.amount - rhs.amount) > 0.000_001 { return lhs.amount > rhs.amount }
                return lhs.model < rhs.model
            }
            .prefix(max(1, limit))
            .map { $0 }
    }
}

private enum WidgetWeek {
    static func total(_ daily: [DailyCost]) -> Double {
        WidgetWindow.total(daily)
    }
}

private struct WidgetBarChart: View {
    let days: [WidgetDay]
    let height: CGFloat

    private var maximum: Double {
        max(0.01, (days.map(\.total).max() ?? 0) * 1.05)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(days) { day in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(isToday(day.date) ? IOSTheme.lime : IOSTheme.brand.opacity(0.82))
                        .frame(height: max(2, height * day.total / maximum))
                    Text(weekday(day.date))
                        .font(.system(size: 9, weight: isToday(day.date) ? .bold : .medium))
                        .foregroundStyle(isToday(day.date) ? IOSTheme.brandText : Color.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "花费趋势，合计 \(String(format: "%.2f", days.reduce(0) { $0 + $1.total })) 美元"
        )
    }

    private func isToday(_ date: Date) -> Bool {
        BillingCycle.calendar.isDateInToday(date)
    }

    private func weekday(_ date: Date) -> String {
        let labels = ["日", "一", "二", "三", "四", "五", "六"]
        let index = BillingCycle.calendar.component(.weekday, from: date) - 1
        return labels[max(0, min(labels.count - 1, index))]
    }
}

