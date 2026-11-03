import SwiftUI
import Charts

struct IOSDashboardView: View {
    @ObservedObject var usage: IOSUsageController
    @Binding var chartAlignment: ChartAlignment
    @Binding var selectedKeyID: String?
    let onRelogin: () -> Void

    private var usableKeys: [ApiKeyInfo] {
        usage.keyDirectory?.usableKeys ?? []
    }

    private var selectedKeyName: String {
        guard let selectedKeyID else { return "所有密钥" }
        return usableKeys.first(where: { $0.id == selectedKeyID })?.displayName ?? "所有密钥"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                IOSPageHeader(
                    title: "OpenCode Go",
                    subtitle: usage.snapshot.map {
                        "总览 · 更新于 \($0.updatedAt.formatted(date: .omitted, time: .shortened))"
                    } ?? "总览"
                ) {
                    Button {
                        Task { await usage.refresh() }
                    } label: {
                        if usage.loading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .buttonStyle(IOSActionButtonStyle())
                    .disabled(usage.loading)
                    .accessibilityLabel("刷新用量")
                }

                if usage.loginExpired || usage.keyDirectory?.status == .loginRequired {
                    IOSLoginExpiredBanner(onRelogin: onRelogin)
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

                    IOSDashboardFilterCard(
                        alignment: $chartAlignment,
                        selectedKeyID: $selectedKeyID,
                        selectedKeyName: selectedKeyName,
                        keys: usableKeys
                    )

                    IOSPeriodSummaryCard(
                        periodTitle: periodTitle,
                        periodTotal: periodTotal,
                        todayTotal: todayTotal,
                        selectedKeyName: selectedKeyName
                    )

                    IOSUsageLimitsCard(snapshot: snapshot)

                    IOSSpendChartCard(
                        snapshot: snapshot,
                        daily: daily,
                        alignment: chartAlignment
                    )

                    IOSModelBreakdownCard(
                        title: "今日模型",
                        detail: String(format: "$%.2f", todayTotal),
                        items: folded(todayEntries, topCount: 5),
                        total: todayTotal,
                        emptyDetail: "今天还没有产生模型费用"
                    )

                    IOSModelBreakdownCard(
                        title: chartAlignment == .billing ? "账期模型" : "自然月模型",
                        detail: String(format: "$%.2f", periodTotal),
                        items: IOSDashboardData.foldedModelTotals(daily),
                        total: periodTotal,
                        emptyDetail: "当前时间窗口还没有产生费用"
                    )
                } else if !usage.loading {
                    IOSEmptyState(
                        icon: "chart.bar.xaxis",
                        title: "还没有用量数据",
                        detail: "首次同步可能需要几十秒，请下拉刷新。"
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 88)
        }
        .background(IOSTheme.pageBackground)
        .scrollIndicators(.hidden)
        .refreshable { await usage.refresh() }
        .task { await usage.refreshIfStale() }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func folded(_ items: [IOSModelAmount], topCount: Int) -> [IOSModelAmount] {
        guard items.count > topCount else { return items }
        let top = Array(items.prefix(topCount))
        let other = items.dropFirst(topCount).reduce(0) { $0 + $1.amount }
        return top + [IOSModelAmount(model: ModelPalette.otherName, amount: other)]
    }
}

private struct IOSDashboardFilterCard: View {
    @Binding var alignment: ChartAlignment
    @Binding var selectedKeyID: String?
    let selectedKeyName: String
    let keys: [ApiKeyInfo]

    var body: some View {
        IOSCard(padding: 12) {
            HStack(spacing: 10) {
                IOSPeriodPicker(selection: $alignment)
                Spacer(minLength: 4)
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
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 11, weight: .semibold))
                        Text(selectedKeyName)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(IOSTheme.insetBackground)
                    .clipShape(Capsule())
                }
                .disabled(keys.isEmpty)
            }
        }
    }
}

private struct IOSPeriodSummaryCard: View {
    let periodTitle: String
    let periodTotal: Double
    let todayTotal: Double
    let selectedKeyName: String

    var body: some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(periodTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(selectedKeyName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "$%.2f", periodTotal))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.8)
                    Text("USD")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(spacing: 7) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(IOSTheme.brand)
                    Text("今日")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "$%.2f", todayTotal))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(IOSTheme.brandSoft)
                .clipShape(Capsule())
            }
        }
    }
}

private struct IOSUsageLimitsCard: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 14) {
                IOSSectionTitle(title: "套餐额度", detail: "已用比例")
                QuotaRow(label: "5 小时", percent: snapshot.rolling, reset: snapshot.rollingReset)
                QuotaRow(label: "周", percent: snapshot.weekly, reset: snapshot.weeklyReset)
                QuotaRow(label: "月", percent: snapshot.monthly, reset: snapshot.monthlyReset)
            }
        }
    }
}

private struct IOSSpendChartCard: View {
    let snapshot: WidgetSnapshot
    let daily: [DailyCost]
    let alignment: ChartAlignment

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
                        alignment: alignment
                    )
                    .frame(height: 210)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 132), spacing: 8)],
                        alignment: .leading,
                        spacing: 7
                    ) {
                        ForEach(folded.legend) { item in
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(modelColor(item.model))
                                    .frame(width: 12, height: 8)
                                Text(ModelPalette.displayName(item.model))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func modelColor(_ model: String) -> Color {
        model == ModelPalette.otherName
            ? Color.secondary.opacity(0.45)
            : ModelPalette.color(for: model)
    }
}

private struct IOSSpendChart: View {
    let rows: [IOSChartRow]
    let dates: [Date]
    let alignment: ChartAlignment

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
            model == ModelPalette.otherName
                ? Color.secondary.opacity(0.45)
                : ModelPalette.color(for: model)
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: ChartAxis.yDomain(maxDaily: maxDaily))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(IOSTheme.stroke)
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(String(format: "$%.0f", amount))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: alignment == .billing ? 6 : 5)) { _ in
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel(format: .dateTime.month().day())
                    .font(.system(size: 9))
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

private struct IOSModelBreakdownCard: View {
    let title: String
    let detail: String
    let items: [IOSModelAmount]
    let total: Double
    let emptyDetail: String

    var body: some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 14) {
                IOSSectionTitle(title: title, detail: detail)
                if items.isEmpty {
                    Text(emptyDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    ForEach(items) { item in
                        IOSModelShareRow(item: item, total: total)
                    }
                }
            }
        }
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
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct IOSLoginExpiredBanner: View {
    let onRelogin: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(IOSTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("控制台登录已失效")
                    .font(.subheadline.weight(.semibold))
                Text("旧 Key 已撤下，历史总额仍保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新登录", action: onRelogin)
                .buttonStyle(IOSActionButtonStyle())
        }
        .padding(12)
        .background(IOSTheme.warning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
