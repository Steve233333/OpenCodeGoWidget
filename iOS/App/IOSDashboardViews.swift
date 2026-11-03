import SwiftUI
import Charts
import WidgetKit

struct IOSOverviewView: View {
    @ObservedObject var usage: IOSUsageController
    @ObservedObject var account: ConsoleAccountModel
    let onRelogin: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if usage.loading {
                    ProgressView("正在同步 OpenCode 用量…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                if usage.loginExpired || usage.keyDirectory?.status == .loginRequired {
                    IOSLoginExpiredBanner(onRelogin: onRelogin)
                }
                if let error = usage.error, !usage.loginExpired {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if let snapshot = usage.snapshot {
                    let recent = IOSCostWindow.recent(snapshot.dailyCosts, days: 30)
                    let recentTotal = recent.reduce(0) { $0 + $1.total }

                    HStack(spacing: 12) {
                        IOSMetricCard(
                            title: "今日花费",
                            value: String(format: "$%.2f", snapshot.costTotal),
                            caption: "USD"
                        )
                        IOSMetricCard(
                            title: "近 30 天",
                            value: String(format: "$%.2f", recentTotal),
                            caption: "USD"
                        )
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("额度").font(.headline)
                        QuotaRow(label: "5 小时", percent: snapshot.rolling, reset: snapshot.rollingReset)
                        QuotaRow(label: "周", percent: snapshot.weekly, reset: snapshot.weeklyReset)
                        QuotaRow(label: "月", percent: snapshot.monthly, reset: snapshot.monthlyReset)
                    }
                    .padding(16)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("近 30 天花费").font(.headline)
                            Spacer()
                            Text(recent.last?.date ?? "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        IOSRecentCostChart(dailyCosts: recent)
                            .frame(height: 210)
                        let models = Array(Set(recent.flatMap { $0.entries.keys }))
                            .sorted { ModelPalette.displayName($0) < ModelPalette.displayName($1) }
                        if !models.isEmpty {
                            WrappingLegendView(models: models)
                        }
                    }
                    .padding(16)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("今日模型").font(.headline)
                        if snapshot.costEntries.isEmpty {
                            Text("今天还没有产生费用")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            CostBar(entries: snapshot.costEntries, total: snapshot.costTotal)
                            ForEach(
                                snapshot.costEntries.sorted { $0.value > $1.value }.prefix(8),
                                id: \.key
                            ) { item in
                                IOSCostListRow(
                                    name: ModelPalette.displayName(item.key) + ModelPalette.channelSuffix(item.key),
                                    value: item.value,
                                    share: snapshot.costTotal > 0 ? item.value / snapshot.costTotal : 0
                                )
                            }
                        }
                    }
                    .padding(16)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Text("更新于 \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else if !usage.loading {
                    ContentUnavailableView(
                        "还没有用量数据",
                        systemImage: "chart.bar.xaxis",
                        description: Text("首次同步可能需要几十秒，请下拉刷新。")
                    )
                    .frame(minHeight: 360)
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("OpenCode Go")
        .refreshable { await usage.refresh() }
        .task { await usage.refreshIfStale() }
    }
}

struct IOSByKeyView: View {
    @ObservedObject var usage: IOSUsageController
    @State private var selectedKeyID: String? = UserDefaults(
        suiteName: PlatformConfig.appGroupID
    )?.string(forKey: "selectedCostKeyId")

    private var keys: [ApiKeyInfo] {
        usage.keyDirectory?.usableKeys ?? []
    }

    private var selectedDaily: [DailyCost] {
        guard let snapshot = usage.snapshot else { return [] }
        return IOSCostWindow.recent(snapshot.filteredDaily(for: selectedKeyID), days: 30)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if usage.keyDirectory?.status == .loginRequired {
                    Text("控制台登录已失效，旧 Key 已撤下；历史总量仍在概览中。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if keys.isEmpty {
                    ContentUnavailableView(
                        "没有可选的 Key",
                        systemImage: "key.slash",
                        description: Text(usage.keyDirectory?.detail ?? "刷新后会重新验证官网 Key 列表")
                    )
                } else {
                    Picker("Key", selection: $selectedKeyID) {
                        Text("所有密钥").tag(Optional<String>.none)
                        ForEach(keys) { key in
                            Text(key.displayName).tag(Optional(key.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedKeyID) { _, value in
                        let defaults = UserDefaults(suiteName: PlatformConfig.appGroupID)
                        if let value {
                            defaults?.set(value, forKey: "selectedCostKeyId")
                        } else {
                            defaults?.removeObject(forKey: "selectedCostKeyId")
                        }
                    }

                    let total = selectedDaily.reduce(0) { $0 + $1.total }
                    IOSMetricCard(
                        title: selectedKeyID == nil ? "所有密钥 · 近 30 天" : "该 Key · 近 30 天",
                        value: String(format: "$%.2f", total),
                        caption: "USD"
                    )

                    if selectedDaily.isEmpty {
                        ContentUnavailableView(
                            "暂无使用",
                            systemImage: "tray",
                            description: Text("这个 Key 在最近 30 天没有产生费用。")
                        )
                        .frame(minHeight: 280)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("每日花费").font(.headline)
                            IOSRecentCostChart(dailyCosts: selectedDaily)
                                .frame(height: 220)
                        }
                        .padding(16)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                        let byModel = IOSCostWindow.aggregateByModel(selectedDaily)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("按模型汇总").font(.headline)
                            ForEach(
                                byModel.sorted { $0.value > $1.value }.prefix(15),
                                id: \.key
                            ) { item in
                                IOSCostListRow(
                                    name: ModelPalette.displayName(item.key) + ModelPalette.channelSuffix(item.key),
                                    value: item.value,
                                    share: total > 0 ? item.value / total : 0
                                )
                            }
                        }
                        .padding(16)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("按 Key")
        .refreshable { await usage.refresh() }
        .task {
            reconcileSelectedKey()
            await usage.refreshIfStale()
        }
        .onChange(of: usage.keyDirectory) { _, _ in reconcileSelectedKey() }
    }

    private func reconcileSelectedKey() {
        guard !KeyDirectoryStore.selectedKeyIsAvailable(selectedKeyID, in: usage.keyDirectory) else {
            return
        }
        selectedKeyID = nil
        UserDefaults(suiteName: PlatformConfig.appGroupID)?.removeObject(forKey: "selectedCostKeyId")
    }
}

struct IOSModelsView: View {
    @ObservedObject var usage: IOSUsageController

    private var recent: [DailyCost] {
        IOSCostWindow.recent(usage.snapshot?.dailyCosts ?? [], days: 30)
    }

    private var thirtyDayModels: [String: Double] {
        IOSCostWindow.aggregateByModel(recent)
    }

    private var todayModels: [String: Double] {
        usage.snapshot?.costEntries ?? [:]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let snapshot = usage.snapshot {
                    HStack(spacing: 12) {
                        IOSMetricCard(
                            title: "今日模型",
                            value: "\(todayModels.count)",
                            caption: "个模型产生费用"
                        )
                        IOSMetricCard(
                            title: "30 天模型",
                            value: "\(thirtyDayModels.count)",
                            caption: "个模型产生费用"
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("今日占比").font(.headline)
                        if todayModels.isEmpty {
                            Text("今天暂无使用").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(
                                todayModels.sorted { $0.value > $1.value },
                                id: \.key
                            ) { item in
                                IOSCostListRow(
                                    name: ModelPalette.displayName(item.key) + ModelPalette.channelSuffix(item.key),
                                    value: item.value,
                                    share: snapshot.costTotal > 0 ? item.value / snapshot.costTotal : 0
                                )
                            }
                        }
                    }
                    .padding(16)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    let total = thirtyDayModels.values.reduce(0, +)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("近 30 天").font(.headline)
                            Spacer()
                            Text(String(format: "$%.2f", total))
                                .font(.subheadline.monospacedDigit().bold())
                        }
                        ForEach(
                            thirtyDayModels.sorted { $0.value > $1.value },
                            id: \.key
                        ) { item in
                            IOSCostListRow(
                                name: ModelPalette.displayName(item.key) + ModelPalette.channelSuffix(item.key),
                                value: item.value,
                                share: total > 0 ? item.value / total : 0
                            )
                        }
                    }
                    .padding(16)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    ContentUnavailableView(
                        "暂无模型数据",
                        systemImage: "chart.bar.doc.horizontal",
                        description: Text("下拉刷新后会显示按模型汇总。")
                    )
                    .frame(minHeight: 360)
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("模型")
        .refreshable { await usage.refresh() }
        .task { await usage.refreshIfStale() }
    }
}

struct IOSQuotaPage: View {
    @ObservedObject var usage: IOSUsageController

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            GoQuotaChart(quotas: usage.quotas, updatedAt: usage.quotaUpdatedAt)
                .frame(minWidth: 730)
                .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Go 全模型配额")
        .refreshable {
            _ = await GoQuotaRegistry.refreshIfNeeded(force: true)
            usage.reloadFromStorage()
        }
    }
}

struct IOSSettingsPage: View {
    @ObservedObject var account: ConsoleAccountModel
    @ObservedObject var usage: IOSUsageController
    let onRelogin: () -> Void
    @State private var confirmClear = false

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section("账号") {
                LabeledContent("状态", value: account.isLoggedIn ? "已登录" : "未登录")
                LabeledContent(
                    "Workspace",
                    value: account.workspaceID.isEmpty
                        ? "未获取"
                        : "\(account.workspaceID.prefix(12))…\(account.workspaceID.suffix(5))"
                )
                Button("重新登录") { onRelogin() }
                Button("退出登录", role: .destructive) {
                    account.signOut()
                }
            }

            Section("数据") {
                LabeledContent(
                    "最后同步",
                    value: usage.snapshot?.updatedAt.formatted(date: .abbreviated, time: .shortened) ?? "尚未同步"
                )
                if usage.backfillRunning {
                    Label("正在补齐 30 天历史明细", systemImage: "arrow.triangle.2.circlepath")
                }
                Button("清除登录与本地数据", role: .destructive) {
                    confirmClear = true
                }
            }

            Section("关于") {
                LabeledContent("版本", value: version)
                Text("iOS 版仅使用 OpenCode 账号会话读取额度与用量，不保存 Go API Key。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("主 App 负责同步；主屏和锁屏小组件只读取共享快照。系统决定后台刷新时机，不保证固定 5 分钟更新。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
        .confirmationDialog(
            "清除全部本地数据？",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("全部清除", role: .destructive) {
                account.clearAllLocalData()
                usage.clearLocalData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除 Keychain 登录信息和 30 天花费缓存，无法恢复。")
        }
    }
}

struct IOSLoginExpiredBanner: View {
    let onRelogin: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("控制台登录已失效").font(.subheadline.weight(.semibold))
                Text("旧 Key 已撤下，历史总额仍保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新登录", action: onRelogin)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct IOSMetricCard: View {
    let title: String
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().bold()).lineLimit(1)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct IOSCostListRow: View {
    let name: String
    let value: Double
    let share: Double

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(name).font(.caption).lineLimit(1)
                Spacer()
                Text(String(format: "$%.3f · %.1f%%", value, min(max(share, 0), 1) * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(share, 0), 1))
                .tint(.blue)
        }
    }
}

struct IOSRecentCostChart: View {
    let dailyCosts: [DailyCost]

    private struct ChartPoint: Identifiable {
        let id = UUID()
        let date: Date
        let model: String
        let cost: Double
    }

    private var chartRows: [ChartPoint] {
        let formatter = ChartFormatters.day
        var result: [ChartPoint] = []
        for day in dailyCosts {
            guard let date = formatter.date(from: day.date) else { continue }
            for (model, cost) in ModelPalette.foldedEntries(day.entries) where cost > 0 {
                result.append(ChartPoint(date: date, model: model, cost: cost))
            }
        }
        return result
    }

    private var yMax: Double {
        max(1, dailyCosts.map(\.total).max() ?? 0) * 1.2
    }

    var body: some View {
        if chartRows.isEmpty {
            ContentUnavailableView(
                "暂无花费",
                systemImage: "chart.bar",
                description: Text("这个时间窗口没有产生费用。")
            )
        } else {
            Chart(chartRows) { row in
                BarMark(
                    x: .value("日期", row.date, unit: .day),
                    y: .value("花费", row.cost)
                )
                .foregroundStyle(by: .value("模型", row.model))
                .cornerRadius(2)
            }
            .chartForegroundStyleScale { (model: String) in
                ModelPalette.color(for: model)
            }
            .chartYScale(domain: 0...max(yMax, 1))
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(String(format: "$%.0f", amount))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month().day())
                }
            }
            .chartLegend(.hidden)
        }
    }
}

enum IOSCostWindow {
    static func recent(_ daily: [DailyCost], days: Int) -> [DailyCost] {
        Array(daily.sorted { $0.date < $1.date }.suffix(days))
    }

    static func aggregateByModel(_ daily: [DailyCost]) -> [String: Double] {
        var result: [String: Double] = [:]
        for day in daily {
            for (model, cost) in day.entries where cost > 0 {
                result[model, default: 0] += cost
            }
        }
        return result
    }
}
