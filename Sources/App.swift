import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WidgetKit
import Charts

@main
struct OpenCodeGoWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        // This app has one dashboard. WindowGroup creates a new instance for
        // every external URL event, which is exactly what a widget tap sends.
        Window("OpenCode Go", id: "main") {
            ContentView()
                .frame(width: 620, height: 860)
                .fixedSize()
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "opencodego"))
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.keyWindow ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
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
                Label {
                    Text("OpenCode Go")
                } icon: {
                    BrandIconView(size: 16)
                }
                .font(.headline)
                Spacer()
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if let snap = snapshot {
                VStack(spacing: 12) {
                    // 月度堆叠柱状图（整月长度，如截图）
                    VStack(alignment: .leading, spacing: 6) {
                        let monthlyTotal = snap.dailyCosts.reduce(0) { $0 + $1.total }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("本月花费").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "$%.2f USD", monthlyTotal)).font(.headline).monospacedDigit()
                        }
                        if snap.dailyCosts.isEmpty {
                            VStack(spacing: 6) {
                                Text("暂无本月模型费用数据")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text("配置 workspace 后自动拉取按日堆叠真数据")
                                    .font(.system(size: 9)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }
                            .frame(height: 120)
                            .frame(maxWidth: .infinity)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            MonthChartView(dailyCosts: snap.dailyCosts)
                                .frame(height: 160)
                            // 图例
                            let allModels = Set(snap.dailyCosts.flatMap { $0.entries.keys })
                            let legend = ModelPalette.ordered.filter { allModels.contains($0) } + allModels.filter { !ModelPalette.ordered.contains($0) }.sorted()
                            if !legend.isEmpty {
                                WrappingLegendView(models: legend)
                            }
                        }
                        // 今日模型细分保留，便于对比
                        if !snap.costEntries.isEmpty {
                            VStack(spacing: 4) {
                                HStack {
                                    Text("今日模型").font(.system(size: 9)).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(String(format: "$%.2f USD", snap.costTotal)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                CostBar(entries: snap.costEntries, total: snap.costTotal)
                            }
                            .padding(.top, 4)
                        }
                    }
                    Divider()
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

            Button { Task { await refresh() } } label: {
                if loading {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .disabled(loading)
            .buttonStyle(.borderedProminent)

            if let e = error { Text(e).font(.caption).foregroundStyle(.red) }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 620, height: 860)
        .sheet(isPresented: $showSettings) { SettingsView(apiKey: $apiKey) }
        .task { if snapshot == nil { await refresh() } }
        .onOpenURL { url in
            if url.scheme == "opencodego" {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true; error = nil
        do {
            let snap = try await WidgetSnapshotRefresher.fetch()
            WidgetDataStore.save(snap)
            snapshot = snap
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
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
        if k == "其他" { return Color.gray.opacity(0.6) }
        return ModelPalette.color(for: k)
    }
    func short(_ s: String) -> String { ModelPalette.shortName(s) }
}

struct MonthChartView: View {
    let dailyCosts: [DailyCost]

    private var monthDates: [Date] {
        let cal = Calendar(identifier: .gregorian)
        let refDate: Date = {
            if let last = dailyCosts.last?.date,
               let d = ChartFormatters.day.date(from: last) { return d }
            return Date()
        }()
        guard let monthInterval = cal.dateInterval(of: .month, for: refDate),
              let days = cal.range(of: .day, in: .month, for: refDate) else { return [] }
        return days.compactMap { day -> Date? in
            cal.date(byAdding: .day, value: day - 1, to: monthInterval.start)
        }
    }

    private var flat: [DayModelCost] {
        let map: [String: DailyCost] = Dictionary(uniqueKeysWithValues: dailyCosts.map { ($0.date, $0) })
        var result: [DayModelCost] = []
        for date in monthDates {
            let key = ChartFormatters.day.string(from: date)
            if let dc = map[key] {
                for (model, cost) in dc.entries where cost > 0 {
                    result.append(DayModelCost(date: date, model: model, cost: cost))
                }
            }
        }
        return result
    }

    private var yDomain: ClosedRange<Double> {
        let maxDaily = dailyCosts.map { $0.total }.max() ?? 0
        let top = max(2.5, ceil(maxDaily * 1.2 * 10) / 10)
        let capped = min(max(top, 2.5), 6.0)
        return 0...capped
    }

    private var allMonthStrings: [String] {
        monthDates.map { ChartFormatters.monthLabel.string(from: $0) }
    }

    var body: some View {
        Chart(flat) { item in
            BarMark(
                x: .value("Date", ChartFormatters.monthLabel.string(from: item.date)),
                y: .value("Cost", item.cost),
                stacking: .standard
            )
            .foregroundStyle(by: .value("Model", item.model))
            .cornerRadius(1)
        }
        .chartForegroundStyleScale { (model: String) in
            if model == "__empty__" { return Color.clear }
            return ModelPalette.color(for: model)
        }
        .chartXScale(domain: allMonthStrings)
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { val in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2,2])).foregroundStyle(Color.primary.opacity(0.12))
                AxisValueLabel {
                    if let v = val.as(Double.self) {
                        Text(String(format: "$%.0f", v)).font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: allMonthStrings.enumerated().filter { $0.offset % 3 == 0 }.map { $0.element }) { val in
                AxisGridLine().foregroundStyle(Color.clear)
                AxisValueLabel(centered: true) {
                    if let s = val.as(String.self) {
                        Text(s).font(.system(size: 7)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot
                .background(Color.primary.opacity(0.03))
                .border(Color.primary.opacity(0.08), width: 0.5)
        }
        .chartLegend(.hidden)
        .padding(.top, 4)
    }
}

struct SettingsView: View {
    @Binding var apiKey: String
    @Environment(\.dismiss) var dismiss
    @State private var draft: String = ""
    @State private var workspaceID: String = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")?.string(forKey: "workspaceID") ?? ""
    @State private var authCookie: String = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")?.string(forKey: "authCookie") ?? ""
    @State private var harStatus: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置").font(.headline)
            Text("1. 粘贴 OpenCode Go API Key（sk-...），在 opencode.ai → Settings → API Keys 复制。")
                .font(.caption2).foregroundStyle(.secondary)
            SecureField("sk-...", text: $draft)
                .textFieldStyle(.roundedBorder)

            Divider()
            Text("2. 柱状图费用（可选）：粘贴你的 workspace 链接或 HAR，以启用按日按模型堆叠真数据")
                .font(.caption2).foregroundStyle(.secondary)
            TextField("https://opencode.ai/workspace/wrk_.../usage", text: $workspaceID)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)
            HStack {
                Button("选择 HAR 文件") {
                    chooseHARFile()
                }.controlSize(.small)
                if !harStatus.isEmpty { Text(harStatus).font(.caption2).foregroundStyle(.green) }
                Spacer()
            }
            TextField("auth Cookie（或直接选 HAR 自动填）", text: $authCookie)
                .textFieldStyle(.roundedBorder)
                .font(.caption2)

            HStack {
                Button("保存") {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        KeychainStore.save(t)
                        apiKey = t
                    }
                    var ws = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
                    var ac = authCookie.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Normalize ws if full URL https://opencode.ai/workspace/wrk_.../usage
                    if ws.contains("/workspace/"), let r = ws.range(of: "/workspace/") {
                        let rest = String(ws[r.upperBound...])
                        ws = rest.split(separator: "/").first.map(String.init) ?? ws
                    }
                    // If ac is a HAR file path or workspace full link pasted into auth field, extract real auth in host process
                    var harWS: String?
                    if ac.hasSuffix(".har") || ac.contains(".har") {
                        let expanded = NSString(string: ac).expandingTildeInPath
                        if let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)),
                           let har = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let log = har["log"] as? [String: Any], let entries = log["entries"] as? [[String: Any]] {
                            for e in entries {
                                if let req = e["request"] as? [String: Any], let cookies = req["cookies"] as? [[String: Any]] {
                                    for c in cookies where (c["name"] as? String) == "auth" {
                                        if let v = c["value"] as? String, !v.isEmpty { ac = v; break }
                                    }
                                }
                                if harWS == nil, let req = e["request"] as? [String: Any], let u = req["url"] as? String, u.contains("/workspace/") {
                                    if let r = u.range(of: "/workspace/") {
                                        let rest = String(u[r.upperBound...])
                                        if let id = rest.split(separator: "/").first.map(String.init), id.hasPrefix("wrk_") {
                                            harWS = id
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // If ws still empty but HAR contained workspace, fill it
                    if ws.isEmpty, let hw = harWS { ws = hw }
                    // Also handle case where auth field contains full workspace URL pasted by mistake
                    if ac.contains("/workspace/"), let r = ac.range(of: "/workspace/") {
                        let rest = String(ac[r.upperBound...])
                        if let id = rest.split(separator: "/").first.map(String.init), id.hasPrefix("wrk_") {
                            if ws.isEmpty { ws = id }
                            // auth was actually a URL, clear it to avoid storing URL as cookie
                            if ac.hasPrefix("https://") { ac = "" }
                        }
                    }
                    let d = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
                    d?.set(ws, forKey: "workspaceID")
                    // Only store real cookie (539B), never HAR path
                    if !ac.isEmpty && !ac.hasSuffix(".har") && !ac.contains(".har") {
                        d?.set(ac, forKey: "authCookie")
                    } else if ac.isEmpty {
                        // keep existing if new is empty
                    }
                    WidgetCenter.shared.reloadAllTimelines()
                    dismiss()
                }.buttonStyle(.borderedProminent)
                Button("取消", role: .cancel) { dismiss() }
                Spacer()
            }
            Text("提示：柱状图需要 workspace 裸ID (wrk_...) 与 539B auth Cookie；粘贴 .har 路径或 https://.../workspace/wrk_.../usage 全链路时会在保存时即时解析为真实 Cookie 存入 App Group，无需手动复制。")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(width: 520, height: 360)
        .onAppear {
            draft = apiKey
            let d = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
            var storedWS = d?.string(forKey: "workspaceID") ?? ""
            var storedAuth = d?.string(forKey: "authCookie") ?? ""
            // Legacy migration: if stored values are still HAR path or full URL, parse in host process now
            if storedWS.contains("/workspace/"), let r = storedWS.range(of: "/workspace/") {
                let rest = String(storedWS[r.upperBound...])
                storedWS = rest.split(separator: "/").first.map(String.init) ?? storedWS
                d?.set(storedWS, forKey: "workspaceID")
            }
            if storedAuth.hasSuffix(".har") || storedAuth.contains(".har") {
                let expanded = NSString(string: storedAuth).expandingTildeInPath
                if let data = try? Data(contentsOf: URL(fileURLWithPath: expanded)),
                   let har = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let log = har["log"] as? [String: Any],
                   let entries = log["entries"] as? [[String: Any]] {
                    for e in entries {
                        if let req = e["request"] as? [String: Any], let cookies = req["cookies"] as? [[String: Any]] {
                            for c in cookies where (c["name"] as? String) == "auth" {
                                if let v = c["value"] as? String, !v.isEmpty { storedAuth = v; break }
                            }
                        }
                    }
                    d?.set(storedAuth, forKey: "authCookie")
                    WidgetCenter.shared.reloadAllTimelines()
                } else {
                    // HAR path invalid, clear to avoid CostCrawler treating it as cookie
                    storedAuth = ""
                }
            }
            workspaceID = storedWS
            authCookie = storedAuth
        }
    }

    private func importHAR(from url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url),
              let har = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let log = har["log"] as? [String: Any],
              let entries = log["entries"] as? [[String: Any]] else {
            harStatus = "无法读取 HAR 文件，请确认选择的是浏览器导出的 .har"
            return
        }

        var foundAuth: String?
        var foundWorkspace: String?
        for entry in entries {
            if let request = entry["request"] as? [String: Any],
               let cookies = request["cookies"] as? [[String: Any]] {
                for cookie in cookies where (cookie["name"] as? String) == "auth" {
                    if let value = cookie["value"] as? String, !value.isEmpty {
                        foundAuth = value
                        break
                    }
                }
            }
            if let request = entry["request"] as? [String: Any],
               let url = request["url"] as? String,
               let range = url.range(of: "/workspace/") {
                let rest = String(url[range.upperBound...])
                if let id = rest.split(separator: "/").first.map(String.init), id.hasPrefix("wrk_") {
                    foundWorkspace = id
                }
            }
        }

        if let auth = foundAuth {
            authCookie = auth
            harStatus = "已从 HAR 提取 auth Cookie (\(auth.count)B)"
        }
        if let workspace = foundWorkspace { workspaceID = workspace }

        let defaults = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
        if let auth = foundAuth { defaults?.set(auth, forKey: "authCookie") }
        if let workspace = foundWorkspace { defaults?.set(workspace, forKey: "workspaceID") }
        defaults?.synchronize()

        if foundAuth != nil || foundWorkspace != nil {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
        } else {
            harStatus = "未在 HAR 中找到 OpenCode workspace 或 auth Cookie"
        }
    }

    @MainActor
    private func chooseHARFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "har") ?? .data, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "选择"
        panel.message = "选择浏览器导出的 OpenCode HAR 文件"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)

        let handleResult: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                importHAR(from: url)
            }
        }

        // Settings itself is a SwiftUI sheet. An asynchronous child sheet is
        // the supported way to present NSOpenPanel here; runModal() can leave
        // the panel behind the settings sheet with no visible response.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            panel.beginSheetModal(for: window, completionHandler: handleResult)
        } else {
            panel.begin(completionHandler: handleResult)
        }
    }
}
