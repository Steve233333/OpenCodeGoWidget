import SwiftUI
import Charts

struct IOSDashboardView: View {
    @ObservedObject var usage: IOSUsageController
    @Binding var chartAlignment: ChartAlignment
    @Binding var selectedKeyID: String?
    let onRelogin: () -> Void

    @State private var modelScope: IOSModelScope = .period

    private var usableKeys: [ApiKeyInfo] {
        usage.keyDirectory?.usableKeys ?? []
    }

    private var selectedKeyName: String {
        guard let selectedKeyID else { return "所有密钥" }
        return usableKeys.first(where: { $0.id == selectedKeyID })?.displayName ?? "所有密钥"
    }

    private var updatedSubtitle: String {
        guard let snapshot = usage.snapshot else { return "额度与花费" }
        let time = snapshot.updatedAt.formatted(date: .omitted, time: .shortened)
        let age = Date().timeIntervalSince(snapshot.updatedAt)
        if age < 60 { return "更新于 \(time) · 刚刚" }
        if age < 3_600 { return "更新于 \(time) · \(Int(age / 60)) 分钟前" }
        return "更新于 \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                IOSPageHeader(title: "总览", subtitle: updatedSubtitle) {
                    Button {
                        Task { await usage.refresh() }
                    } label: {
                        Group {
                            if usage.loading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                        }
                        .frame(width: 44, height: 44)
                        .iosGlass(Circle(), interactive: true, tint: IOSTheme.brand.opacity(0.18))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(IOSTheme.brandText)
                    .disabled(usage.loading)
                    .accessibilityLabel("刷新用量")
                }

                if usage.loginExpired {
                    IOSLoginExpiredBanner(
                        onRetry: { Task { await usage.refresh() } },
                        onRelogin: onRelogin
                    )
                } else if usage.keyDirectory?.status == .loginRequired {
                    IOSKeyDirectoryWarningBanner {
                        Task { await usage.refresh() }
                    }
                }
                if let error = usage.error, !usage.loginExpired {
                    IOSNotice(text: error, tint: IOSTheme.warning)
                }
                if let sharingError = usage.widgetSharingError {
                    IOSNotice(text: sharingError, tint: IOSTheme.warning)
                }

                if let snapshot = usage.snapshot {
                    let daily = IOSDashboardData.periodDaily(
                        snapshot: snapshot,
                        selectedKeyID: selectedKeyID,
                        alignment: chartAlignment
                    )
                    let periodTotal = IOSDashboardData.total(daily)
                    let periodTitle = IOSDashboardData.periodTitle(
                        snapshot: snapshot,
                        alignment: chartAlignment
                    )
                    let todayEntries = IOSDashboardData.todayEntries(
                        snapshot: snapshot,
                        selectedKeyID: selectedKeyID
                    )
                    let todayTotal = todayEntries.reduce(0) { $0 + $1.amount }
                    let sparkline = daily.suffix(14).map(\.total)
                    let chartColors = IOSChartPalette.map(
                        for: IOSDashboardData.foldedChart(daily, topCount: 5).legend
                    )

                    IOSPeriodHeroCard(
                        periodTitle: periodTitle,
                        periodTotal: periodTotal,
                        todayTotal: todayTotal,
                        sparkline: sparkline
                    )

                    IOSUsageLimitsCard(snapshot: snapshot)

                    IOSSectionHeader(title: "花费") {
                        HStack(spacing: 8) {
                            IOSPeriodPicker(selection: $chartAlignment)
                            IOSKeyMenu(
                                selectedKeyID: $selectedKeyID,
                                selectedKeyName: selectedKeyName,
                                keys: usableKeys
                            )
                        }
                    }

                    IOSSpendChartCard(
                        snapshot: snapshot,
                        daily: daily,
                        alignment: chartAlignment,
                        colors: chartColors
                    )
                    .id("chart")

                    IOSModelBreakdownCard(
                        scope: $modelScope,
                        periodLabel: chartAlignment == .billing ? "账期" : "自然月",
                        todayItems: folded(todayEntries, topCount: 5),
                        todayTotal: todayTotal,
                        periodItems: IOSDashboardData.foldedModelTotals(daily),
                        periodTotal: periodTotal,
                        colorMap: chartColors
                    )
                    .id("models")
                } else if usage.loading {
                    IOSLoadingState()
                } else {
                    IOSEmptyState(
                        icon: "chart.bar.xaxis",
                        title: "还没有用量数据",
                        detail: "首次同步可能需要几十秒，请下拉刷新。"
                    )
                }
            }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 96)
            }
            .background(IOSTheme.pageBackground)
            .scrollIndicators(.hidden)
            .refreshable { await usage.refresh() }
            .task {
                await usage.refreshIfStale()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-scroll-models") {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    proxy.scrollTo("models", anchor: .top)
                }
                #endif
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private func folded(_ items: [IOSModelAmount], topCount: Int) -> [IOSModelAmount] {
        guard items.count > topCount else { return items }
        let top = Array(items.prefix(topCount))
        let other = items.dropFirst(topCount).reduce(0) { $0 + $1.amount }
        return top + [IOSModelAmount(model: ModelPalette.otherName, amount: other)]
    }
}

private struct IOSKeyMenu: View {
    @Binding var selectedKeyID: String?
    let selectedKeyName: String
    let keys: [ApiKeyInfo]

    var body: some View {
        Menu {
            Button {
                selectedKeyID = nil
            } label: {
                Label("所有密钥", systemImage: "key.horizontal")
            }
            if !keys.isEmpty {
                Divider()
            }
            ForEach(keys) { key in
                Button(key.displayName) {
                    selectedKeyID = key.id
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "key.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(selectedKeyName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .iosGlass(Capsule(), interactive: true, tint: IOSTheme.brand.opacity(0.10))
        }
        .disabled(keys.isEmpty)
        .accessibilityLabel("筛选密钥，当前 \(selectedKeyName)")
    }
}

private struct IOSPeriodHeroCard: View {
    let periodTitle: String
    let periodTotal: Double
    let todayTotal: Double
    let sparkline: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("本期花费")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(IOSTheme.heroSecondary)
                Spacer(minLength: 6)
                Text(periodTitle.replacingOccurrences(of: "-", with: "–"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(IOSTheme.heroMuted)
                    .lineLimit(1)
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("$\(periodTotal, specifier: "%.2f")")
                            .font(.system(size: 38, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(IOSTheme.heroForeground)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("USD")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(IOSTheme.heroMuted)
                    }
                    Text("今日 $\(todayTotal, specifier: "%.2f")")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(IOSTheme.heroSecondary)
                }
                Spacer(minLength: 4)
                if sparkline.contains(where: { $0 > 0 }) {
                    IOSMiniSparkline(values: sparkline)
                        .frame(width: 96, height: 44)
                        .accessibilityHidden(true)
                }
            }

        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IOSTheme.heroGradient)
        .clipShape(RoundedRectangle(cornerRadius: IOSTheme.Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "本期花费 \(String(format: "%.2f", periodTotal)) 美元，今日 \(String(format: "%.2f", todayTotal)) 美元"
        )
    }
}

private struct IOSMiniSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(values.max() ?? 0, 0.01)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { pair in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(pair.offset == values.count - 1 ? IOSTheme.heroSparkLast : IOSTheme.heroSpark)
                        .frame(height: max(2, geometry.size.height * pair.element / maximum))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

private struct IOSUsageLimitsCard: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        IOSCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                IOSSectionTitle(title: "套餐额度", detail: "已用比例")
                HStack(spacing: 8) {
                    IOSQuotaMiniTile(
                        label: "5 小时",
                        percent: snapshot.rolling,
                        reset: snapshot.rollingReset,
                        emphasized: true
                    )
                    IOSQuotaMiniTile(
                        label: "周",
                        percent: snapshot.weekly,
                        reset: snapshot.weeklyReset
                    )
                    IOSQuotaMiniTile(
                        label: "月",
                        percent: snapshot.monthly,
                        reset: snapshot.monthlyReset
                    )
                }
            }
        }
    }
}

struct IOSQuotaFocusTile: View {
    let label: String
    let percent: Int
    let reset: Date

    private var textTint: Color { IOSTheme.quotaTextColor(percent) }
    private var barTint: Color { IOSTheme.quotaBarColor(percent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 6)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(min(max(percent, 0), 100))")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(textTint)
                    Text("%")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(textTint)
                }
            }
            IOSProgressBar(percent: percent, tint: barTint, height: 4)
            Text(IOSResetText.relative(reset))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .background(
            LinearGradient(
                colors: [IOSTheme.brandSoft, IOSTheme.brandSoft.opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: IOSTheme.Radius.tile, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)额度，已用 \(percent)%，\(IOSResetText.relative(reset))")
    }
}

struct IOSQuotaMiniTile: View {
    let label: String
    let percent: Int
    let reset: Date
    var emphasized = false

    private var textTint: Color { IOSTheme.quotaTextColor(percent) }
    private var barTint: Color { IOSTheme.quotaBarColor(percent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: emphasized ? .semibold : .medium))
                Spacer(minLength: 2)
                if percent >= 80 {
                    Text("接近上限")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(IOSTheme.warning)
                        .lineLimit(1)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(min(max(percent, 0), 100))")
                    .font(.system(size: emphasized ? 26 : 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(textTint)
                Text("%")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(textTint)
            }
            IOSProgressBar(percent: percent, tint: barTint, height: 3)
            Text(IOSResetText.relative(reset))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(emphasized ? IOSTheme.brandSoft : IOSTheme.insetBackground)
        .clipShape(RoundedRectangle(cornerRadius: IOSTheme.Radius.tile, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)额度，已用 \(percent)%，\(IOSResetText.relative(reset))")
    }
}

private struct IOSSpendChartCard: View {
    let snapshot: WidgetSnapshot
    let daily: [DailyCost]
    let alignment: ChartAlignment
    let colors: [String: Color]

    private var folded: IOSFoldResult {
        IOSDashboardData.foldedChart(daily, topCount: 5)
    }

    private var dates: [Date] {
        ChartWindow.dates(
            dailyCosts: snapshot.dailyCosts,
            monthlyReset: snapshot.monthlyReset,
            alignment: alignment
        )
    }

    var body: some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 12) {
                IOSSectionTitle(
                    title: "每日花费",
                    detail: String(format: "$%.2f", IOSDashboardData.total(daily))
                )
                if folded.rows.isEmpty {
                    IOSEmptyState(
                        icon: "chart.bar",
                        title: "当前窗口暂无花费",
                        detail: "切换账期或自然月后再看看。"
                    )
                } else {
                    IOSSpendChart(
                        rows: folded.rows,
                        dates: dates,
                        alignment: alignment,
                        colors: colors
                    )
                    .frame(height: 175)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 118), spacing: 8)],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(folded.legend) { item in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(colors[item.model] ?? Color.secondary.opacity(0.45))
                                    .frame(width: 12, height: 8)
                                Text(ModelPalette.displayName(item.model))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

}

private enum IOSChartPalette {
    static let colors: [Color] = [
        IOSTheme.brand,
        IOSTheme.lime,
        IOSTheme.sand,
        IOSTheme.slate,
        IOSTheme.brand.opacity(0.55),
    ]

    static func map(for legend: [IOSModelAmount]) -> [String: Color] {
        var result: [String: Color] = [:]
        var index = 0
        for item in legend {
            if item.model == ModelPalette.otherName {
                result[item.model] = Color.secondary.opacity(0.45)
            } else {
                result[item.model] = colors[index % colors.count]
                index += 1
            }
        }
        return result
    }
}

private struct IOSSpendChart: View {
    let rows: [IOSChartRow]
    let dates: [Date]
    let alignment: ChartAlignment
    let colors: [String: Color]

    private var domain: ClosedRange<Date> {
        let start = dates.first ?? rows.map(\.date).min() ?? Date()
        let end = dates.last ?? rows.map(\.date).max() ?? start
        return start...max(start.addingTimeInterval(86_400), end)
    }

    private var maxDaily: Double {
        var byDay: [Date: Double] = [:]
        for row in rows {
            let day = BillingCycle.calendar.startOfDay(for: row.date)
            byDay[day, default: 0] += row.amount
        }
        return byDay.values.max() ?? 0
    }

    /// 不再用固定的 $2.5 下限。花得少时让柱子占满图高，轴标签跟着数据换精度。
    private var yTop: Double {
        let scaled = max(0.3, maxDaily * 1.15)
        let step: Double = scaled <= 1 ? 0.25 : scaled <= 5 ? 0.5 : scaled <= 20 ? 2 : 10
        return (scaled / step).rounded(.up) * step
    }

    private var axisFontSize: CGFloat { 10 }

    private func axisLabel(_ amount: Double) -> String {
        if yTop <= 1 { return String(format: "$%.2f", amount) }
        if yTop <= 5 { return String(format: "$%.1f", amount) }
        return String(format: "$%.0f", amount)
    }

    var body: some View {
        Chart(rows) { row in
            BarMark(
                x: .value("日期", row.date, unit: .day),
                y: .value("花费", row.amount)
            )
            .foregroundStyle(by: .value("模型", row.model))
            .cornerRadius(2)
        }
        .chartForegroundStyleScale { model in
            colors[model] ?? Color.secondary.opacity(0.45)
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...yTop)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(IOSTheme.stroke)
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(axisLabel(amount))
                            .font(.system(size: axisFontSize))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: alignment == .billing ? 6 : 5)) { _ in
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel(format: .dateTime.month().day())
                    .font(.system(size: axisFontSize))
                    .foregroundStyle(.secondary)
            }
        }
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot
                .background(IOSTheme.insetBackground.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private enum IOSModelScope: String, CaseIterable {
    case today
    case period
}

private struct IOSModelBreakdownCard: View {
    @Binding var scope: IOSModelScope
    let periodLabel: String
    let todayItems: [IOSModelAmount]
    let todayTotal: Double
    let periodItems: [IOSModelAmount]
    let periodTotal: Double
    let colorMap: [String: Color]

    private var items: [IOSModelAmount] {
        scope == .today ? todayItems : periodItems
    }

    private var total: Double {
        scope == .today ? todayTotal : periodTotal
    }

    var body: some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Text("模型花费")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer(minLength: 6)
                    scopePicker
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(scope == .today ? "今日" : periodLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(String(format: "$%.2f", total))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }

                if items.isEmpty {
                    Text(scope == .today ? "今天还没有产生模型费用" : "当前时间窗口还没有产生费用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 11) {
                        ForEach(items) { item in
                            IOSModelShareRow(
                                item: item,
                                total: total,
                                tint: colorMap[item.model] ?? Color.secondary.opacity(0.45)
                            )
                        }
                    }
                }
            }
        }
    }

    private var scopePicker: some View {
        HStack(spacing: 2) {
            scopeOption("今日", .today)
            scopeOption(periodLabel, .period)
        }
        .padding(3)
        .background(IOSTheme.insetBackground)
        .clipShape(Capsule())
    }

    private func scopeOption(_ title: String, _ value: IOSModelScope) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                scope = value
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: scope == value ? .semibold : .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(scope == value ? IOSTheme.brandOn : Color.primary)
                .background(scope == value ? IOSTheme.brand : Color.clear)
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(scope == value ? .isSelected : [])
    }
}

private struct IOSLoadingState: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("正在同步额度与花费…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }
}

private struct IOSNotice: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: IOSTheme.Radius.tile, style: .continuous))
    }
}

struct IOSLoginExpiredBanner: View {
    let onRetry: () -> Void
    let onRelogin: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(IOSTheme.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text("控制台登录可能已失效")
                    .font(.subheadline.weight(.semibold))
                Text("额度接口返回 401；先重试，仍不行再重新登录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            VStack(spacing: 4) {
                Button("重试", action: onRetry)
                    .buttonStyle(IOSActionButtonStyle())
                Button("重新登录", action: onRelogin)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(IOSTheme.brandText)
            }
        }
        .padding(12)
        .background(IOSTheme.warning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: IOSTheme.Radius.tile, style: .continuous))
    }
}

struct IOSKeyDirectoryWarningBanner: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.slash")
                .foregroundStyle(IOSTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Key 列表同步失败")
                    .font(.subheadline.weight(.semibold))
                Text("登录没掉，额度和花费仍会更新；可能只是网络或地区限制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("重试", action: retry)
                .buttonStyle(IOSActionButtonStyle())
        }
        .padding(12)
        .background(IOSTheme.warning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: IOSTheme.Radius.tile, style: .continuous))
    }
}
