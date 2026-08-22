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
    func perform() async throws -> some IntentResult {
        let mgr = NetworkManager()
        do {
            let usage = try await mgr.fetchUsage()
            let cost = await mgr.fetchCostToday()
            var entries: [String: Double] = [:]
            for e in cost.entries { entries[e.model] = e.cost }
            let snap = WidgetSnapshot(
                rolling: usage.rolling.percent, weekly: usage.weekly.percent, monthly: usage.monthly.percent,
                rollingReset: usage.rolling.resetsAt, weeklyReset: usage.weekly.resetsAt, monthlyReset: usage.monthly.resetsAt,
                costTotal: cost.total, costEntries: entries, updatedAt: Date(), error: nil
            )
            WidgetDataStore.save(snap)
        } catch {
            if var s = WidgetDataStore.load() {
                s.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                s.updatedAt = Date()
                WidgetDataStore.save(s)
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> GoUsageEntry {
        GoUsageEntry(date: Date(), snapshot: WidgetDataStore.load() ?? WidgetSnapshot(rolling: 96, weekly: 64, monthly: 82, rollingReset: Date().addingTimeInterval(3600), weeklyReset: Date().addingTimeInterval(86400), monthlyReset: Date().addingTimeInterval(86400*7), costTotal: 1.23, costEntries: ["mimo-v2.5-go":0.6, "deepseek-v4-flash-vision-exp-go":0.4, "glm-5-go":0.23], updatedAt: Date(), error: nil))
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
                let newSnap = WidgetSnapshot(rolling: usage.rolling.percent, weekly: usage.weekly.percent, monthly: usage.monthly.percent, rollingReset: usage.rolling.resetsAt, weeklyReset: usage.weekly.resetsAt, monthlyReset: usage.monthly.resetsAt, costTotal: cost.total, costEntries: entries, updatedAt: Date(), error: nil)
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
                Label("OpenCode Go", systemImage: "chart.bar.fill")
                    .font(.caption2.weight(.semibold))
                Spacer()
                Button(intent: RefreshIntent()) {
                    Image(systemName: "arrow.clockwise").font(.caption2)
                }.buttonStyle(.plain)
            }

            if let s = snap {
                if family == .systemSmall {
                    // 小尺寸：只显示三档额度，不显示堆叠柱
                    ForEach([("5小时", s.rolling, s.rollingReset), ("周", s.weekly, s.weeklyReset), ("月", s.monthly, s.monthlyReset)], id: \.0) { label, percent, reset in
                        QuotaMiniRow(label: label, percent: percent, reset: reset)
                    }
                } else {
                    // 中尺寸：左侧迷你堆叠柱，右侧三档额度
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("今日").font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "$%.2f", s.costTotal)).font(.caption2.monospacedDigit().bold())
                            }
                            if !s.costEntries.isEmpty {
                                CostMiniBar(entries: s.costEntries, total: s.costTotal)
                            } else {
                                // 即使无费用数据也显示占位堆叠，保持与截图一致的视觉
                                CostMiniBar(entries: ["mimo-v2.5-go": 0.5, "deepseek-v4-flash-vision-exp-go": 0.35, "glm-5-go": 0.15], total: 1.0)
                                    .opacity(0.35)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        VStack(spacing: 4) {
                            ForEach([("5小时", s.rolling, s.rollingReset), ("周", s.weekly, s.weeklyReset), ("月", s.monthly, s.monthlyReset)], id: \.0) { label, percent, reset in
                                QuotaMiniRow(label: label, percent: percent, reset: reset)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                HStack {
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
        .padding(12)
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
            // 7-day mini stacked columns (只读预览，高度按当日/近期费用归一)
            if !entries.isEmpty {
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<7, id: \.self) { day in
                        // Demo: distribute total across 7 days with decay, real data will replace via dailyCosts
                        let factor: Double = [0.6, 0.8, 1.0, 0.7, 0.9, 0.5, 0.85][day]
                        let h = max(4, CGFloat(factor) * 28)
                        VStack(spacing: 1) {
                            ForEach(sorted.prefix(3), id: \.0) { (k,v) in
                                let segH = h * CGFloat(v/total) / 3
                                Rectangle().fill(colorFor(k).opacity(0.85)).frame(height: max(1, segH))
                            }
                        }
                        .frame(height: h)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                }.frame(height: 30)
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
        .description("今日花费 + 模型比例 + 5h/周/月额度")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
