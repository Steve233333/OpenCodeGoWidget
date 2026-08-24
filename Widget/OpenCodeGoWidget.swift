import SwiftUI
import WidgetKit
import AppIntents

struct GoUsageEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct RefreshIntent: AppIntent {
    static var title: LocalizedStringResource = "刷新 OpenCode Go"
    static var description = IntentDescription("立即刷新用量")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // 实时同步 Go 模型列表（不阻塞主刷新，失败静默）
        _ = await ModelRegistry.refreshIfNeeded()
        var didSave = false
        do {
            let snap = try await WidgetSnapshotRefresher.fetch()
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
        // save() synchronizes the App Group first; the provider now uses this
        // fresh snapshot instead of starting another network request.
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
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
        let cached = WidgetDataStore.load()
        let now = Date()
        let staleAfter: TimeInterval = 15 * 60

        // A manual RefreshIntent has just stored a fresh snapshot. Return it
        // directly so the widget changes as soon as WidgetKit reloads it.
        guard cached == nil || now.timeIntervalSince(cached!.updatedAt) >= staleAfter else {
            let next = cached!.updatedAt.addingTimeInterval(staleAfter)
            completion(Timeline(entries: [GoUsageEntry(date: now, snapshot: cached)], policy: .after(next)))
            return
        }

        Task {
            // 后台刷新 Go 模型列表（TTL 24h，轻量无鉴权）
            _ = await ModelRegistry.refreshIfNeeded()
            var snap = cached
            do {
                let refreshed = try await WidgetSnapshotRefresher.fetch()
                WidgetDataStore.save(refreshed)
                snap = refreshed
            } catch {
                // Keep the last successful data when a scheduled fetch fails.
            }
            let entry = GoUsageEntry(date: now, snapshot: snap)
            completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(staleAfter))))
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
                        .font(.system(size: 13, weight: .medium))
                        // WidgetKit shows this as waiting while the intent
                        // runs, then bounces it once when updated data arrives.
                        .invalidatableContent()
                        .symbolEffect(.bounce, options: .speed(1.25), value: snap?.updatedAt ?? entry.date)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.mini)
            }

            if let s = snap {
                if family == .systemSmall {
                    // 小尺寸：只显示三档额度，不显示堆叠柱
                    ForEach([("5小时", s.rolling, s.rollingReset), ("周", s.weekly, s.weeklyReset), ("月", s.monthly, s.monthlyReset)], id: \.0) { label, percent, reset in
                        QuotaMiniRow(label: label, percent: percent, reset: reset)
                    }
                } else {
                    // 中尺寸：左侧三档额度，右侧近7天堆叠（已对调）
                    HStack(alignment: .top, spacing: 14) {
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
                                Text(String(format: "$%.2f USD", weekTotal)).font(.caption2.monospacedDigit().bold())
                            }
                            if !s.dailyCosts.isEmpty {
                                Link(destination: URL(string: "opencodego://month")!) {
                                    WeekChartView(dailyCosts: s.dailyCosts)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 8)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
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
        // p 为已用占比，越高越红
        if p >= 80 { return .red }
        if p >= 50 { return .orange }
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
        return (0..<7).compactMap { cal.date(byAdding: .day, value: -6 + $0, to: today) }
    }

    private var yMax: Double {
        let maxDaily = last7Dates.map { dailyCost(for: $0).total }.max() ?? 0
        return max(1.5, ceil(maxDaily * 1.2 * 10) / 10)
    }

    private func dailyCost(for date: Date) -> DailyCost {
        let key = ChartFormatters.day.string(from: date)
        return dailyCosts.first(where: { $0.date == key }) ?? DailyCost(date: key, entries: [:])
    }

    var body: some View {
        if dailyCosts.isEmpty {
            Text("暂无近7天费用").font(.system(size: 8)).foregroundStyle(.secondary)
                .frame(height: 40)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            GeometryReader { geometry in
                let columnWidth = geometry.size.width / CGFloat(last7Dates.count)
                VStack(spacing: 3) {
                    HStack(alignment: .bottom, spacing: 0) {
                        ForEach(last7Dates, id: \.self) { date in
                            WeekBarColumn(
                                entries: dailyCost(for: date).entries,
                                maximum: yMax
                            )
                            .frame(width: columnWidth, height: 42)
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(last7Dates, id: \.self) { date in
                            Text(ChartFormatters.weekLabel.string(from: date))
                                .font(.system(size: 7))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(width: columnWidth)
                        }
                    }
                    .frame(height: 11)
                }
            }
            .frame(height: 56)
        }
    }
}

struct WeekBarColumn: View {
    let entries: [String: Double]
    let maximum: Double

    private var segments: [(model: String, cost: Double)] {
        entries
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in
                let left = ModelPalette.ordered.firstIndex(of: lhs.key) ?? Int.max
                let right = ModelPalette.ordered.firstIndex(of: rhs.key) ?? Int.max
                return left == right ? lhs.key < rhs.key : left < right
            }
            .map { (model: $0.key, cost: $0.value) }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(ModelPalette.color(for: segment.model))
                            .frame(height: max(1, geometry.size.height * CGFloat(segment.cost / maximum)))
                    }
                }
                .frame(width: min(22, geometry.size.width * 0.58))
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
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
                Text(String(format: "$%.2f USD", total)).font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
    }
    func colorFor(_ k: String) -> Color {
        if k == "其他" { return Color.gray.opacity(0.6) }
        return ModelPalette.color(for: k)
    }
    func short(_ s: String) -> String { ModelPalette.shortName(s) }
}

@main
struct OpenCodeGoWidgetBundle: WidgetBundle {
    var body: some Widget {
        OpenCodeGoWidget()
    }
}

struct OpenCodeGoWidget: Widget {
    let kind = WidgetConstants.kind
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            GoWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("OpenCode Go")
        .description("近7天堆叠 + 5h/周/月额度")
        .contentMarginsDisabled()
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
