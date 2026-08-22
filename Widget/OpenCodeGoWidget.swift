import SwiftUI
import WidgetKit
import AppIntents
import Charts

struct GoUsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct RefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新 OpenCode Go"
    static var description = IntentDescription("立即刷新用量")
    func perform() async throws -> some IntentResult {
        let mgr = NetworkManager()
        var didSave = false
        do {
            let usage = try await mgr.fetchUsage()
            let cost = await mgr.fetchCostToday()
            var entries: [String: Double] = [:]
            for e in cost.entries { entries[e.model] = e.cost }
            let snap = WidgetSnapshot(
                rolling: usage.rolling.percent, weekly: usage.weekly.percent, monthly: usage.monthly.percent,
                rollingReset: usage.rolling.resetsAt, weeklyReset: usage.weekly.resetsAt, monthlyReset: usage.monthly.resetsAt,
                costTotal: cost.total, costEntries: entries, dailyCosts: cost.daily, updatedAt: Date(), error: nil as String?
            )
            WidgetDataStore.save(snap)
            didSave = true
        } catch {
            if var s = WidgetDataStore.load() {
                s.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                s.updatedAt = Date()
                WidgetDataStore.save(s)
                didSave = true
            }
        }
        // Always bump updatedAt even on total failure so user sees refresh happened
        if !didSave {
            var snap = WidgetDataStore.load() ?? WidgetSnapshot(rolling: 0, weekly: 0, monthly: 0, rollingReset: Date(), weeklyReset: Date(), monthlyReset: Date(), costTotal: 0, costEntries: [:], dailyCosts: [], updatedAt: Date(), error: "刷新失败")
            snap.updatedAt = Date()
            WidgetDataStore.save(snap)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> GoUsageEntry {
        GoUsageEntry(date: Date(), snapshot: WidgetDataStore.load() ?? WidgetSnapshot(rolling: 96, weekly: 64, monthly: 82, rollingReset: Date().addingTimeInterval(3600), weeklyReset: Date().addingTimeInterval(86400), monthlyReset: Date().addingTimeInterval(86400*7), costTotal: 1.23, costEntries: ["mimo-v2.5-go":0.6, "deepseek-v4-flash-vision-exp-go":0.4, "glm-5-go":0.23], dailyCosts: [], updatedAt: Date(), error: nil))
    }
    func getSnapshot(in context: Context, completion: @escaping (GoUsageEntry) -> Void) {
        completion(GoUsageEntry(date: Date(), snapshot: WidgetDataStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<GoUsageEntry>) -> Void) {
        Task {
            var snap = WidgetDataStore.load()
            // Try background fetch
            do {
                let usage = try await NetworkManager().fetchUsage()
                let cost = await NetworkManager().fetchCostToday()
                var entries: [String: Double] = [:]
                for e in cost.entries { entries[e.model] = e.cost }
                let newSnap = WidgetSnapshot(rolling: usage.rolling.percent, weekly: usage.weekly.percent, monthly: usage.monthly.percent, rollingReset: usage.rolling.resetsAt, weeklyReset: usage.weekly.resetsAt, monthlyReset: usage.monthly.resetsAt, costTotal: cost.total, costEntries: entries, dailyCosts: cost.daily, updatedAt: Date(), error: nil as String?)
                WidgetDataStore.save(newSnap)
                snap = newSnap
            } catch {
                // keep last snapshot, mark error
            }
            let entry = GoUsageEntry(date: Date(), snapshot: snap)
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

struct GoWidgetView: View {
    let entry: GoUsageEntry
    var snap: WidgetSnapshot? { entry.snapshot }

    @Environment(\.widgetFamily) var family
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label {
                    Text("OpenCode Go")
                } icon: {
                    BrandIconView(size: 13)
                }
                .font(.caption2.weight(.semibold))
                Spacer()
                Button(intent: RefreshIntent()) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .symbolEffect(.bounce, value: snap?.updatedAt)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .invalidatableContent()
                .sensoryFeedback(.impact, trigger: snap?.updatedAt)
            }

            if let s = snap {
                if family == .systemSmall {
                    // 小尺寸：只显示三档额度，不显示堆叠柱
                    ForEach([("5小时", s.rolling, s.rollingReset), ("周", s.weekly, s.weeklyReset), ("月", s.monthly, s.monthlyReset)], id: \.0) { label, percent, reset in
                        QuotaMiniRow(label: label, percent: percent, reset: reset)
                    }
                } else {
                    // 中尺寸：左侧三档额度，右侧近7天堆叠（已对调）
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 5) {
                            ForEach([("5小时", s.rolling, s.rollingReset), ("周", s.weekly, s.weeklyReset), ("月", s.monthly, s.monthlyReset)], id: \.0) { label, percent, reset in
                                QuotaMiniRow(label: label, percent: percent, reset: reset)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 4) {
                            let weekTotal = s.dailyCosts.suffix(7).reduce(0) { $0 + $1.total }
                            HStack(spacing: 4) {
                                Text("近7天").font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "$%.2f", weekTotal)).font(.caption2.monospacedDigit().bold())
                            }
                            if !s.dailyCosts.isEmpty {
                                Link(destination: URL(string: "opencodego://month")!) {
                                    WeekChartView(dailyCosts: s.dailyCosts)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text("暂无近7天费用").font(.system(size: 8)).foregroundStyle(.secondary)
                                    .frame(height: 48)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.primary.opacity(0.04))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                HStack(spacing: 4) {
                    Text("更新于 \(s.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer()
                    if let e = s.error { Text(e).font(.system(size: 9)).foregroundStyle(.red).lineLimit(1) }
                }
            } else {
                Spacer()
                Text("未配置 ZEN_API_KEY").font(.caption2).foregroundStyle(.secondary)
                Text("打开 App 粘贴").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct QuotaMiniRow: View {
    let label: String; let percent: Int; let reset: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption2)
                Spacer()
                Text("\(percent)%").font(.caption2.monospacedDigit().bold()).foregroundStyle(remainingColor(percent))
                Text("· \(shortReset(reset))").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(remainingColor(percent)).frame(width: geo.size.width * CGFloat(percent)/100)
                }
            }.frame(height: 4)
        }
    }
    func remainingColor(_ p: Int) -> Color {
        if p < 20 { return .red }
        if p < 50 { return .orange }
        return .green
    }
    func shortReset(_ d: Date) -> String {
        let sec = max(0, Int(d.timeIntervalSinceNow))
        let h = sec/3600; let m = (sec%3600)/60
        if h >= 24 { return "\(h/24)d" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }
}

struct WeekChartView: View {
    let dailyCosts: [DailyCost]

    private var last7Dates: [Date] {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        let ref: Date = {
            if let last = dailyCosts.last?.date, let d = ChartFormatters.day.date(from: last) { return d }
            return today
        }()
        let end = cal.startOfDay(for: ref)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: -6 + $0, to: end) }
    }

    private var flat: [DayModelCost] {
        var map = Dictionary(uniqueKeysWithValues: dailyCosts.map { ($0.date, $0) })
        var result: [DayModelCost] = []
        for date in last7Dates {
            let key = ChartFormatters.day.string(from: date)
            if let dc = map[key] {
                for (m, c) in dc.entries where c > 0 {
                    result.append(DayModelCost(date: date, model: m, cost: c))
                }
            }
        }
        return result
    }

    private var yMax: Double {
        let maxDaily = dailyCosts.map { $0.total }.max() ?? 0
        return max(1.5, ceil(maxDaily * 1.2 * 10) / 10)
    }

    private var xDomain: ClosedRange<Date> {
        guard let first = last7Dates.first, let last = last7Dates.last else {
            let now = Date()
            return now...now
        }
        return first...last
    }

    var body: some View {
        if dailyCosts.isEmpty {
            Text("暂无近7天费用").font(.system(size: 8)).foregroundStyle(.secondary)
                .frame(height: 40)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Chart(flat) { item in
                BarMark(x: .value("Date", item.date, unit: .day), y: .value("Cost", item.cost), stacking: .standard)
                    .foregroundStyle(by: .value("Model", item.model))
                    .cornerRadius(1)
            }
            .chartForegroundStyleScale { (model: String) in
                if model == "__empty__" { return Color.clear }
                return ModelPalette.color(for: model)
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: 0...yMax)
            .chartXAxis {
                AxisMarks(preset: .aligned, position: .bottom, values: last7Dates) { val in
                    AxisGridLine(centered: true, stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.clear)
                    AxisValueLabel(anchor: .top) {
                        if let d = val.as(Date.self) {
                            Text(ChartFormatters.weekLabel.string(from: d))
                                .font(.system(size: 6))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartPlotStyle { plot in
                plot.padding(.horizontal, 2).padding(.bottom, 2)
            }
            .frame(height: 52)
        }
    }
}

struct CostMiniBar: View {
    let entries: [String: Double]; let total: Double
    var sorted: [(String, Double)] {
        let s = entries.sorted { $0.value > $1.value }
        let top = Array(s.prefix(3))
        let other = s.dropFirst(3).reduce(0) { $0 + $1.value }
        var r = top
        if other > 0 { r.append(("其他", other)) }
        return r
    }
    var body: some View {
        VStack(spacing: 4) {
            // Stacked horizontal bar (今日模型比例) — mirrors dashboard stacked bar
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(sorted, id: \.0) { (k,v) in
                        let w = total > 0 ? CGFloat(v/total) * geo.size.width : 0
                        Rectangle().fill(colorFor(k)).frame(width: max(0,w))
                    }
                }.clipShape(Capsule())
            }.frame(height: 6)
            if !entries.isEmpty {
                Text("\(sorted.count) 个模型 · \(sorted.prefix(3).map{ short($0.0) }.joined(separator: " · "))")
                    .font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                ForEach(sorted.prefix(3), id: \.0) { (k,v) in
                    HStack(spacing: 2) {
                        Circle().fill(colorFor(k)).frame(width: 5, height: 5)
                        Text("\(short(k)) \(Int(v/total*100))%").font(.system(size: 8)).lineLimit(1)
                    }
                }
                Spacer()
                Text(String(format: "$%.2f", total)).font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
    }
    func colorFor(_ k: String) -> Color {
        // Match dashboard palette loosely: deepseek blue, mimo purple, glm orange, others gray
        if k.contains("deepseek") { return Color(red: 0.2, green: 0.5, blue: 0.95) }
        if k.contains("mimo") { return Color(red: 0.6, green: 0.35, blue: 0.95) }
        if k.contains("glm") { return Color(red: 0.95, green: 0.55, blue: 0.2) }
        if k.contains("gpt") || k.contains("luna") { return Color(red: 0.1, green: 0.7, blue: 0.4) }
        let p: [Color] = [.blue, .purple, .orange, .gray]
        return p[abs(k.hashValue) % p.count]
    }
    func short(_ s: String) -> String { s.replacingOccurrences(of: " (go)", with: "").replacingOccurrences(of: "-go", with: "") }
}

@main
struct OpenCodeGoWidgetBundle: WidgetBundle {
    var body: some Widget {
        OpenCodeGoWidget()
    }
}

struct OpenCodeGoWidget: Widget {
    let kind = "OpenCodeGoWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            GoWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("OpenCode Go")
        .description("近7天堆叠 + 5h/周/月额度")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
