import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WidgetKit
import Charts
import ServiceManagement

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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 默认开机启动：首次启动即注册，失败静默
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            if service.status != .enabled {
                do {
                    try service.register()
                } catch {
                    print("LoginItem register failed: \(error)")
                }
            }
        }
        // 非 SMAppService 回退（旧系统）由系统登录项手动添加
    }

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
    @State private var modelTick = 0 // 触发图例重算（ModelPalette.ordered 读 App Group 缓存）
    @State private var quotas: [GoQuota] = GoQuotaRegistry.cachedSync()
    @State private var quotaUpdatedAt: Date? = GoQuotaRegistry.cachedDate()

    var body: some View {
        VStack(spacing: 0) {
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
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
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
                                    // 图例：实时展示官方 Go 全量（已同步 29 项），不再仅按本月已用过滤，避免 19 vs 22 不一致
                                    let _ = modelTick
                                    let allModels = Set(snap.dailyCosts.flatMap { $0.entries.keys }.map { $0.lowercased() })
                                    let ordered = ModelPalette.ordered
                                    let orderedLower = Set(ordered.map { $0.lowercased() })
                                    let historicalExtra = allModels.filter { !orderedLower.contains($0) }.sorted()
                                    let legend = ordered + historicalExtra
                                    if !legend.isEmpty {
                                        WrappingLegendView(models: legend)
                                    }
                                }
                                // 今日模型：当日无使用显示占位，避免回退到昨日
                                VStack(spacing: 4) {
                                    HStack {
                                        Text("今日模型").font(.system(size: 9)).foregroundStyle(.secondary)
                                        Spacer()
                                        if snap.costEntries.isEmpty {
                                            Text("今日暂无使用 · $0.00 USD").font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                                        } else {
                                            Text(String(format: "$%.2f USD", snap.costTotal)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                                        }
                                    }
                                    if snap.costEntries.isEmpty {
                                        Capsule()
                                            .fill(Color.primary.opacity(0.08))
                                            .frame(height: 8)
                                            .overlay(Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
                                    } else {
                                        CostBar(entries: snap.costEntries, total: snap.costTotal)
                                    }
                                }
                                .padding(.top, 4)
                            }
                            Divider()
                            QuotaRow(label: "5小时", percent: snap.rolling, reset: snap.rollingReset)
                            QuotaRow(label: "周", percent: snap.weekly, reset: snap.weeklyReset)
                            QuotaRow(label: "月", percent: snap.monthly, reset: snap.monthlyReset)
                            Text("更新于 \(snap.updatedAt.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                            if let e = snap.error { Text(e).font(.caption2).foregroundStyle(.red) }

                            // Go 配额横条图（最底部，实时同步文档配额表，同一行三段分色）
                            Divider()
                            GoQuotaChart(quotas: quotas, updatedAt: quotaUpdatedAt)
                                .id(modelTick) // 随模型列表更新重绘
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
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 620, height: 860)
        .sheet(isPresented: $showSettings) { SettingsView(apiKey: $apiKey) }
        .task {
            // 后台同步 Go 模型列表与配额表
            Task {
                _ = await ModelRegistry.refreshIfNeeded()
                let q = await GoQuotaRegistry.refreshIfNeeded()
                await MainActor.run {
                    modelTick += 1
                    quotas = q
                    quotaUpdatedAt = GoQuotaRegistry.cachedDate()
                }
            }
            if snapshot == nil { await refresh() }
        }
        .onOpenURL { url in
            if url.scheme == "opencodego" {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true; error = nil
        // 刷新额度/费用前强制同步模型列表与配额表（用户主动刷新应立即体现官方新增，失败静默）
        async let modelRefresh: [String] = ModelRegistry.refreshIfNeeded(force: true)
        async let quotaRefresh: [GoQuota] = GoQuotaRegistry.refreshIfNeeded(force: true)
        do {
            let snap = try await WidgetSnapshotRefresher.fetch()
            let models = await modelRefresh
            let q = await quotaRefresh
            // 触发图例与配额图重算
            await MainActor.run {
                modelTick += 1; _ = models
                quotas = q
                quotaUpdatedAt = GoQuotaRegistry.cachedDate()
            }
            WidgetDataStore.save(snap)
            snapshot = snap
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
        } catch {
            let models = await modelRefresh
            let q = await quotaRefresh
            await MainActor.run {
                modelTick += 1; _ = models
                quotas = q
                quotaUpdatedAt = GoQuotaRegistry.cachedDate()
            }
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
        // p 为已用占比，越高越告警
        if p >= 80 { return .red }
        if p >= 50 { return .orange }
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
    @State private var showFileImporter = false
    @State private var launchAtLogin: Bool = {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }()
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
                    // 一劳永逸：优先 SwiftUI fileImporter（自动处理沙盒与 sheet 嵌套），失败回退到 AppKit
                    showFileImporter = true
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

            Divider()
            HStack {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, newValue in
                        if #available(macOS 13.0, *) {
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                // 回滚 UI
                                launchAtLogin = !newValue
                            }
                        }
                    }
                Spacer()
                Text("可在系统设置 → 通用 → 登录项管理").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
        .frame(width: 520, height: 400)
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
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "har") ?? .json,
                .json,
                .plainText,
                .data
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                // fileImporter 已授权，importHAR 内部仍会 startAccessing
                importHAR(from: url)
            case .failure(let err):
                harStatus = "选择失败：\(err.localizedDescription)"
                // 回退到 AppKit 以防 fileImporter 在极端 sheet 嵌套下不弹出
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    chooseHARFileFallback()
                }
            }
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
        // 保留兼容入口，内部转调一劳永逸的回退实现
        chooseHARFileFallback()
    }

    @MainActor
    private func chooseHARFileFallback() {
        let panel = NSOpenPanel()
        // 放宽类型：har 未在系统注册时回退到 .data/.json/.plainText，确保不过滤掉文件
        if let harType = UTType(filenameExtension: "har") {
            panel.allowedContentTypes = [harType, .json, .plainText, .data]
        } else {
            panel.allowedContentTypes = [.json, .plainText, .data]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.isExtensionHidden = false
        panel.prompt = "选择"
        panel.message = "选择浏览器导出的 OpenCode HAR 文件（.har 或 .json）"
        // 沙盒下用 FileManager.urls 更可靠，且不强制要求权限
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            panel.directoryURL = desktop
        }

        let handleResult: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                importHAR(from: url)
            }
        }

        // 一劳永逸的窗口查找：
        // Settings 处于 sheet 时，keyWindow.attachedSheet 即 Settings 本体，
        // 此时必须把面板挂到 attachedSheet，否则挂到主窗口会被静默拒绝（already has sheet）
        // 若无可用窗口则用独立模态 begin（不依赖父窗口），保证在任何层级都能弹出
        if let win = NSApp.keyWindow {
            if let sheet = win.attachedSheet {
                panel.beginSheetModal(for: sheet, completionHandler: handleResult)
                return
            }
            // keyWindow 无 sheet，正常挂载
            // 先检查是否已有 sheet，避免 duplicate sheet 错误
            if win.attachedSheet == nil {
                // 确认窗口可见且可作为 sheet 父窗口
                if win.isVisible {
                    panel.beginSheetModal(for: win, completionHandler: handleResult)
                    return
                }
            }
        }
        if let main = NSApp.mainWindow, main.isVisible, main.attachedSheet == nil {
            panel.beginSheetModal(for: main, completionHandler: handleResult)
            return
        }
        // 兜底：独立模态（不依赖父窗口），沙盒下最稳定，即使 sheet 嵌套也能置顶
        panel.center()
        panel.level = .modalPanel
        panel.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.begin(completionHandler: handleResult)
    }
}
