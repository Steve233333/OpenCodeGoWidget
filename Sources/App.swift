import SwiftUI
import WidgetKit

@main
struct OpenCodeGoWidgetApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}

struct ContentView: View {
    @State private var apiKey: String = KeychainStore.load() ?? ""
    @State private var snapshot: WidgetSnapshot? = WidgetDataStore.load()
    @State private var loading = false
    @State private var error: String?
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("OpenCode Go", systemImage: "chart.bar.fill")
                    .font(.headline)
                Spacer()
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if let snap = snapshot {
                VStack(spacing: 10) {
                    // Cost section (best-effort)
                    if snap.costTotal > 0 {
                        VStack(spacing: 4) {
                            HStack {
                                Text("今日花费").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "$%.2f", snap.costTotal)).font(.headline).monospacedDigit()
                            }
                            if !snap.costEntries.isEmpty {
                                CostBar(entries: snap.costEntries, total: snap.costTotal)
                            }
                        }
                        Divider()
                    }
                    QuotaRow(label: "5小时", percent: snap.rolling, reset: snap.rollingReset)
                    QuotaRow(label: "周", percent: snap.weekly, reset: snap.weeklyReset)
                    QuotaRow(label: "月", percent: snap.monthly, reset: snap.monthlyReset)
                    Text("更新于 \(snap.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let e = snap.error { Text(e).font(.caption2).foregroundStyle(.red) }
                }
            } else {
                Text("暂无数据，请先配置 API Key 并刷新")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            HStack(spacing: 12) {
                Button { Task { await refresh() } } label: {
                    if loading { ProgressView().scaleEffect(0.6) } else { Label("刷新", systemImage: "arrow.clockwise") }
                }
                .disabled(loading)
                .buttonStyle(.borderedProminent)

                Button("刷新小组件") { WidgetCenter.shared.reloadAllTimelines() }
                    .buttonStyle(.bordered)
            }

            if let e = error { Text(e).font(.caption).foregroundStyle(.red) }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 320)
        .sheet(isPresented: $showSettings) { SettingsView(apiKey: $apiKey) }
        .task { if snapshot == nil { await refresh() } }
    }

    private func refresh() async {
        loading = true; error = nil
        do {
            let usage = try await NetworkManager().fetchUsage()
            let cost = await NetworkManager().fetchCostToday()
            var entries: [String: Double] = [:]
            for e in cost.entries { entries[e.model] = e.cost }
            let snap = WidgetSnapshot(
                rolling: usage.rolling.percent, weekly: usage.weekly.percent, monthly: usage.monthly.percent,
                rollingReset: usage.rolling.resetsAt, weeklyReset: usage.weekly.resetsAt, monthlyReset: usage.monthly.resetsAt,
                costTotal: cost.total, costEntries: entries, updatedAt: Date(), error: nil
            )
            WidgetDataStore.save(snap)
            snapshot = snap
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.error = msg
            // preserve last snapshot but mark error
            if var s = snapshot { s.error = msg; WidgetDataStore.save(s); snapshot = s }
        }
        loading = false
    }
}

struct QuotaRow: View {
    let label: String
    let percent: Int
    let reset: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\(percent)%").font(.caption.monospacedDigit().bold()).foregroundStyle(color(percent))
                Text("· \(resetText(reset))").font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(color(percent)).frame(width: geo.size.width * CGFloat(percent) / 100)
                }
            }.frame(height: 6)
        }
    }
    func color(_ p: Int) -> Color {
        let used = 100 - p // remaining; if remaining low -> red
        // Actually percent is remaining? Server percent is remaining. Invert for level
        let remaining = p
        if remaining < 20 { return .red }
        if remaining < 50 { return .orange }
        return .green
    }
    func resetText(_ d: Date) -> String {
        let sec = max(0, Int(d.timeIntervalSinceNow))
        let h = sec / 3600; let m = (sec % 3600) / 60
        if h > 24 { return "\(h/24)天" }
        if h > 0 { return "\(h)小时\(m)分" }
        return "\(m)分"
    }
}

struct CostBar: View {
    let entries: [String: Double]
    let total: Double
    var sorted: [(String, Double)] {
        entries.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) } + (entries.count > 3 ? [("其他", entries.values.reduce(0,+)-entries.sorted{$0.value>$1.value}.prefix(3).map{$0.value}.reduce(0,+))] : [])
    }
    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(sorted, id: \.0) { (k,v) in
                        let w = total > 0 ? CGFloat(v/total) * geo.size.width : 0
                        Rectangle().fill(colorFor(k)).frame(width: max(0,w))
                    }
                }.clipShape(Capsule())
            }.frame(height: 8)
            HStack {
                ForEach(sorted.prefix(3), id: \.0) { (k,v) in
                    HStack(spacing: 4) {
                        Circle().fill(colorFor(k)).frame(width: 6, height: 6)
                        Text("\(short(k)) \(Int(v/total*100))%").font(.caption2).lineLimit(1)
                    }
                }
                Spacer()
            }
        }
    }
    func colorFor(_ k: String) -> Color {
        let palette: [Color] = [.blue, .purple, .orange, .gray]
        let idx = abs(k.hashValue) % palette.count
        return palette[idx]
    }
    func short(_ s: String) -> String {
        s.replacingOccurrences(of: " (go)", with: "").replacingOccurrences(of: "-go", with: "")
    }
}

struct SettingsView: View {
    @Binding var apiKey: String
    @Environment(\.dismiss) var dismiss
    @State private var draft: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置").font(.headline)
            Text("粘贴你的 OpenCode Go API Key（sk-...），可在 opencode.ai 的 Settings → API Keys 复制。Key 仅存本机钥匙串，也会尝试从 ~/.config/agent-vision-toolkit/env 的 ZEN_API_KEY 读取。")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("sk-...", text: $draft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("保存") {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        KeychainStore.save(t)
                        apiKey = t
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 420, height: 200)
        .onAppear { draft = apiKey }
    }
}
