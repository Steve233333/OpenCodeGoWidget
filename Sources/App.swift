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

        // 菜单栏常驻：像 DeepSeekMonitor 一样即使用户关掉窗口也继续 5 分钟后台刷
        MenuBarExtra {
            Button("打开主面板") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.keyWindow ?? NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    // 兜底：通过 URL 唤起主窗口
                    if let url = URL(string: "opencodego://month") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .keyboardShortcut("o")
            Divider()
            Button("检查更新…") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.keyWindow ?? NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                }
                NotificationCenter.default.post(name: .openCodeGoOpenSettings, object: nil)
                UpdateChecker.shared.check(force: true)
            }
            Divider()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            MenuBarIconView()
        }
    }
}


struct MenuBarIconView: View {
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                let _ = img.isTemplate = true
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            } else if let nsImg = NSImage(named: "MenuBarIcon") {
                let _ = nsImg.isTemplate = true
                Image(nsImage: nsImg)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "chart.bar.fill")
            }
        }
        .frame(width: 16, height: 16)
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
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
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
    @State private var selectedKeyId: String? = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")?.string(forKey: "selectedCostKeyId")
    @State private var chartAlignment: ChartAlignment = BillingCycle.loadAlignment()
    /// 小组件共享通道的自检警告（写盘失败 / App Group 容器拿不到时置位，界面顶部显示）
    @State private var widgetStoreWarning: String?
    @State private var autoTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()

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

            if let warning = widgetStoreWarning {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text(warning).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    if let snap = snapshot {
                        VStack(spacing: 12) {
                            // 账期/自然月堆叠柱状图 — 账期默认对齐 Go 月重置日，解决月中开套餐被自然月切断
                            VStack(alignment: .leading, spacing: 6) {
                                let filteredDaily = snap.filteredDaily(for: selectedKeyId)
                                // 顶部总数必须跟图表用同一个窗口（2026-09-19 修）：
                                // 以前是"把快照里所有天加起来"，于是新账期刚开、图是空的，
                                // 数字却还挂着上一个自然月的钱（用户实拍：账期 9/19-10/18 显示 $24.11）
                                let monthlyTotal = ChartWindow.total(
                                    dailyCosts: filteredDaily,
                                    monthlyReset: snap.monthlyReset,
                                    alignment: chartAlignment)
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    let isBilling = chartAlignment == .billing
                                    Text(isBilling ? BillingCycle.titleRange(monthlyReset: snap.monthlyReset) : "本月花费").font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                }
                                HStack(spacing: 8) {
                                    if chartAlignment == .billing {
                                        Text(BillingCycle.subtitleDetail(monthlyReset: snap.monthlyReset)).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                                    } else {
                                        Text("自然月 1日—月末").font(.system(size: 8)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(String(format: "$%.2f USD", monthlyTotal)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                }
                                HStack(alignment: .center, spacing: 8) {
                                    // 自绘分段开关放左侧左对齐，密钥菜单放右侧右对齐
                                    HStack(spacing: 0) {
                                        Button { chartAlignment = .billing; BillingCycle.saveAlignment(.billing) } label: {
                                            Text("账期").font(.caption2.weight(chartAlignment == .billing ? .semibold : .regular))
                                                .padding(.horizontal, 10).padding(.vertical, 4)
                                                .background(chartAlignment == .billing ? Color.accentColor : Color.clear)
                                                .foregroundStyle(chartAlignment == .billing ? Color.white : Color.primary)
                                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                        }.buttonStyle(.plain)
                                        Button { chartAlignment = .calendar; BillingCycle.saveAlignment(.calendar) } label: {
                                            Text("自然月").font(.caption2.weight(chartAlignment == .calendar ? .semibold : .regular))
                                                .padding(.horizontal, 10).padding(.vertical, 4)
                                                .background(chartAlignment == .calendar ? Color.accentColor : Color.clear)
                                                .foregroundStyle(chartAlignment == .calendar ? Color.white : Color.primary)
                                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                        }.buttonStyle(.plain)
                                    }
                                    .padding(2)
                                    .background(Color.primary.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 7))
                                    Spacer()
                                    let keysForMenu: [ApiKeyInfo] = snap.availableKeys.isEmpty ? CostCrawler.shared.loadCachedKeys() : snap.availableKeys
                                    if !keysForMenu.isEmpty {
                                        Menu {
                                            Button("所有密钥") { selectedKeyId = nil; UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")?.removeObject(forKey: "selectedCostKeyId") }
                                            ForEach(keysForMenu) { k in
                                                Button(k.displayName) { selectedKeyId = k.id; UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")?.set(k.id, forKey: "selectedCostKeyId") }
                                            }
                                        } label: {
                                            HStack(spacing: 3) {
                                                Text(selectedKeyId == nil ? "所有密钥" : (keysForMenu.first(where: { $0.id == selectedKeyId })?.displayName ?? "未知"))
                                                    .font(.caption2).lineLimit(1)
                                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7))
                                            }
                                            .padding(.horizontal, 6).padding(.vertical, 4)
                                            .background(Color.primary.opacity(0.06))
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                        }
                                        .menuStyle(.borderlessButton)
                                        .fixedSize()
                                    }
                                }
                                if filteredDaily.isEmpty {
                                    VStack(spacing: 6) {
                                        Text(selectedKeyId == nil ? "暂无本月模型费用数据" : "该 Key 本月暂无使用")
                                            .font(.caption2).foregroundStyle(.secondary)
                                        Text(selectedKeyId == nil ? "配置 workspace 后自动拉取按日堆叠真数据" : "新建的 Key 在产生调用前费用为 $0.00")
                                            .font(.system(size: 9)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                    }
                                    .frame(height: 120)
                                    .frame(maxWidth: .infinity)
                                    .background(Color.primary.opacity(0.05))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    MonthChartView(dailyCosts: filteredDaily, monthlyReset: snap.monthlyReset, alignment: chartAlignment)
                                        .frame(height: 160)
                                    // 图例：只列「当前在架」的模型（Go 实时 + Zen 免费实时），
                                    // 已下架但历史里有用量的不再占格子（只留一行统计），避免"下架还列着"
                                    let _ = modelTick
                                    let allModels = Set(filteredDaily.flatMap { $0.entries.keys }.map { $0.lowercased() })
                                    let liveGo = ModelPalette.ordered
                                    let liveGoLower = Set(liveGo.map { $0.lowercased() })
                                    let liveZen = ModelRegistry.cachedZenOrderedSync()
                                        .filter { !liveGoLower.contains($0.lowercased()) }
                                    let liveLower = liveGoLower.union(Set(liveZen.map { $0.lowercased() }))
                                    let legend = liveGo + liveZen.filter { allModels.contains($0.lowercased()) }
                                    let delisted = allModels.subtracting(liveLower).sorted()
                                    if !legend.isEmpty {
                                        WrappingLegendView(models: legend)
                                    }
                                    if !delisted.isEmpty {
                                        Text("另有 \(delisted.count) 个已下架模型仍出现在历史柱里（\(delisted.prefix(4).joined(separator: "、"))\(delisted.count > 4 ? " 等" : "")），不再列入图例")
                                            .font(.system(size: 8))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                // 今日模型：跟随 Key 筛选
                                let filteredCostEntries = snap.filteredCostEntries(for: selectedKeyId)
                                let filteredCostTotal = snap.filteredCostTotal(for: selectedKeyId)
                                VStack(spacing: 4) {
                                    HStack {
                                        Text("今日模型").font(.system(size: 9)).foregroundStyle(.secondary)
                                        Spacer()
                                        if filteredCostEntries.isEmpty {
                                            Text("今日暂无使用 · $0.00 USD").font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                                        } else {
                                            Text(String(format: "$%.2f USD", filteredCostTotal)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                                        }
                                    }
                                    if filteredCostEntries.isEmpty {
                                        Capsule()
                                            .fill(Color.primary.opacity(0.08))
                                            .frame(height: 8)
                                            .overlay(Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
                                    } else {
                                        CostBar(entries: filteredCostEntries, total: filteredCostTotal)
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
        .onReceive(NotificationCenter.default.publisher(for: .openCodeGoOpenSettings)) { _ in
            showSettings = true
        }
        // 浏览器登录自动获取的 Go Key 同步到主界面状态（供设置页与刷新使用）
        .onReceive(NotificationCenter.default.publisher(for: .openCodeGoKeyFetched)) { note in
            if let key = note.object as? String, !key.isEmpty { apiKey = key }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCodeGoStoredKeyCleared)) { _ in
            apiKey = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCodeGoCredentialsChanged)) { _ in
            // 登录态变化后立即拉一次数据，费用图马上有内容
            Task { await refresh() }
        }
        .task {
            // 启动即自检共享通道：App Group 拿不到就先提醒（不依赖这次有没有刷新）
            if WidgetDataStore.groupContainerURL == nil {
                widgetStoreWarning = "App Group 容器不可用：小组件会读不到数据，已改走备用通道（齿轮 → 小组件自检）"
            }
            // 后台同步 Go 模型列表与配额表
            Task {
                _ = await ModelRegistry.refreshIfNeeded()
                _ = await ModelRegistry.refreshZenIfNeeded()
                let q = await GoQuotaRegistry.refreshIfNeeded()
                await MainActor.run {
                    modelTick += 1
                    quotas = q
                    quotaUpdatedAt = GoQuotaRegistry.cachedDate()
                }
            }
            if snapshot == nil { await refresh() }
        }
        .onReceive(autoTimer) { _ in
            guard !loading else { return }
            Task { await refresh() }
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
        async let zenRefresh: [String] = ModelRegistry.refreshZenIfNeeded(force: true)
        async let quotaRefresh: [GoQuota] = GoQuotaRegistry.refreshIfNeeded(force: true)
        do {
            let snap = try await WidgetSnapshotRefresher.fetch()
            let models = await modelRefresh
            _ = await zenRefresh
            let q = await quotaRefresh
            // 触发图例与配额图重算
            await MainActor.run {
                modelTick += 1; _ = models
                quotas = q
                quotaUpdatedAt = GoQuotaRegistry.cachedDate()
            }
            // 写快照：三条通道都试一遍；一条都没写成说明小组件必然空白，界面上要说出来而不是静默
            let savedOK = WidgetDataStore.save(snap)
            await MainActor.run {
                if !savedOK {
                    widgetStoreWarning = "小组件数据写盘失败：三条通道都不可用（点右上角齿轮 → 小组件自检看详情）"
                } else if WidgetDataStore.groupContainerURL == nil {
                    widgetStoreWarning = "App Group 容器不可用：已改走备用通道，小组件需重开 App 后再看（齿轮 → 小组件自检）"
                } else {
                    widgetStoreWarning = nil
                }
            }
            snapshot = snap
            // 文件已原子写入，UserDefaults 也已同步，稍作延迟确保 Widget 扩展的 containerURL 可见
            try? await Task.sleep(nanoseconds: 200_000_000)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
            WidgetCenter.shared.reloadAllTimelines()
            // 再补一次，规避 WidgetKit 节流对单次 reload 的限频
            try? await Task.sleep(nanoseconds: 300_000_000)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind)
        } catch {
            let models = await modelRefresh
            _ = await zenRefresh
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
                        Text("\(short(k)) \(total > 0 ? Int(v / total * 100) : 0)%").font(.caption2).lineLimit(1)
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
    let monthlyReset: Date?
    let alignment: ChartAlignment

    init(dailyCosts: [DailyCost], monthlyReset: Date? = nil, alignment: ChartAlignment = .billing) {
        self.dailyCosts = dailyCosts
        self.monthlyReset = monthlyReset
        self.alignment = alignment
    }

    private var effectiveDates: [Date] {
        ChartWindow.dates(dailyCosts: dailyCosts, monthlyReset: monthlyReset, alignment: alignment)
    }

    private var flat: [DayModelCost] {
        let map: [String: DailyCost] = Dictionary(uniqueKeysWithValues: dailyCosts.map { ($0.date, $0) })
        var result: [DayModelCost] = []
        for date in effectiveDates {
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

    private var allXStrings: [String] {
        if alignment == .billing {
            return effectiveDates.map { ChartFormatters.billingLabel.string(from: $0) }
        }
        return effectiveDates.map { ChartFormatters.monthLabel.string(from: $0) }
    }

    private func xString(for date: Date) -> String {
        if alignment == .billing { return ChartFormatters.billingLabel.string(from: date) }
        return ChartFormatters.monthLabel.string(from: date)
    }

    var body: some View {
        Chart(flat) { item in
            BarMark(
                x: .value("Date", xString(for: item.date)),
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
        .chartXScale(domain: allXStrings)
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
            // billing: ~31 ticks, subsample every ~5d; calendar: every 3d
            let stride = alignment == .billing ? 5 : 3
            let ticks = allXStrings.enumerated().filter { $0.offset % stride == 0 }.map { $0.element }
            AxisMarks(values: ticks) { val in
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


/// 小组件自检：一键看清共享通道卡在哪（App Group 容器 / 备用通道 / 偏好域），
/// 顺便提供「重写快照」把三条通道重新灌一遍。坏机器上用户点一下就能把结论贴出来。
struct WidgetSelfCheckRow: View {
    @State private var report: String?
    @State private var actionNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("小组件自检").font(.system(size: 9)).foregroundStyle(.secondary)
                if let note = actionNote {
                    Text(note).font(.system(size: 9)).foregroundStyle(note.contains("失败") ? .red : .green)
                }
                Spacer()
                Button("重写快照") {
                    guard let snap = WidgetDataStore.load() else {
                        actionNote = "没有快照可写，请先点主界面刷新"
                        return
                    }
                    actionNote = WidgetDataStore.save(snap) ? "三条通道已重写 ✅" : "写盘失败 ❌"
                    if report != nil { report = WidgetDataStore.diagnose() }
                }
                .controlSize(.mini)
                Button(report == nil ? "自检" : "收起") {
                    report = report == nil ? WidgetDataStore.diagnose() : nil
                }
                .controlSize(.mini)
            }
            if let report {
                ScrollView {
                    Text(report)
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 130)
                .padding(6)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

struct SettingsView: View {
    @Binding var apiKey: String
    @Environment(\.dismiss) var dismiss
    @StateObject private var session = AccountSession()
    @State private var showLoginSheet = false
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    GoSettingsContent(apiKey: $apiKey, dismiss: dismiss, onOpenLogin: { showLoginSheet = true })
                    Divider()
                    CodexSetupView(onOpenLogin: { showLoginSheet = true })
                    // 底部统一退出
                    HStack {
                        Spacer()
                        Button("关闭") { dismiss() }
                            .buttonStyle(.bordered)
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 680)
        .sheet(isPresented: $showLoginSheet) {
            LoginSheetView(session: session)
        }
    }
}

struct GoSettingsContent: View {
    @Binding var apiKey: String
    var dismiss: DismissAction
    var onOpenLogin: () -> Void = {}
    @Environment(\.dismiss) var envDismiss
    @State private var draft: String = ""
    @State private var showKey = false
    @State private var storedKeyMask: String = ""
    @State private var confirmClearKey = false
    @State private var confirmClearWS = false
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
    private var effectiveDismiss: DismissAction { dismiss }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Go 额度设置").font(.headline)
                Spacer()
                Button {
                    onOpenLogin()
                } label: {
                    Label("浏览器登录自动获取", systemImage: "globe")
                        .font(.caption2)
                }
                .controlSize(.small)
                .help("登录 opencode.ai 后自动获取 API Key、workspace 与 Cookie")
            }
            Text("1. OpenCode Go API Key（sk-...，存 Keychain 用于额度查询；Codex 用的 Key 在下方「Codex 一键配置」填写）")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Group {
                    if showKey {
                        TextField("sk-...", text: $draft).textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("sk-...", text: $draft).textFieldStyle(.roundedBorder)
                    }
                }
                if !draft.isEmpty {
                    Button(showKey ? "隐藏" : "显示") { showKey.toggle() }
                        .controlSize(.small).buttonStyle(.plain).font(.caption2)
                }
            }
            HStack(spacing: 6) {
                if storedKeyMask.isEmpty {
                    Text("未保存 Key").font(.system(size: 9)).foregroundStyle(.orange)
                } else {
                    Text("已存 \(storedKeyMask)").font(.system(size: 9)).foregroundStyle(.green)
                }
                Spacer()
                if !storedKeyMask.isEmpty {
                    Button("清除已存 Key") { confirmClearKey = true }
                        .controlSize(.mini).buttonStyle(.plain).font(.caption2).foregroundStyle(.red)
                }
            }
            Text("填新值点「保存」= 替换；点「清除已存 Key」= 删除（留空保存不会清空）")
                .font(.system(size: 9)).foregroundStyle(.secondary)

            Divider()
            Text("2. 柱状图费用（可选）：粘贴你的 workspace 链接或 HAR，以启用按日按模型堆叠真数据（浏览器登录后自动填）")
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
            HStack(spacing: 6) {
                if workspaceID.isEmpty && authCookie.isEmpty {
                    Text("未配置 workspace 凭据").font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text("已配置 workspace 凭据（费用图已启用）").font(.system(size: 9)).foregroundStyle(.green)
                }
                Spacer()
                if !workspaceID.isEmpty || !authCookie.isEmpty {
                    Button("清除 workspace 凭据") { confirmClearWS = true }
                        .controlSize(.mini).buttonStyle(.plain).font(.caption2).foregroundStyle(.red)
                }
            }

            HStack {
                Button("保存") {
                    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        KeychainStore.save(t)
                        apiKey = t
                        refreshStoredKeyMask()
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
            Text("提示：柱状图需要 workspace 裸ID (wrk_...) 与 539B auth Cookie；粘贴 .har 路径或 https://.../workspace/wrk_.../usage 全链路时会在保存时即时解析为真实 Cookie 存入 App Group，无需手动复制。点上方「浏览器登录自动获取」可一步完成。")
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
            Divider()
            UpdateStatusRow()
            Divider()
            WidgetSelfCheckRow()
            HStack {
                Spacer()
                Text("OpenCode 小组件").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .onAppear {
            draft = KeychainStore.resolvedKey() ?? apiKey
            refreshStoredKeyMask()
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
        .onReceive(NotificationCenter.default.publisher(for: .openCodeGoKeyFetched)) { note in
            if let key = note.object as? String, !key.isEmpty {
                draft = key
                refreshStoredKeyMask()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCodeGoStoredKeyCleared)) { _ in
            // Codex 页清除了 Keychain 里的 Go Key，这里同步显示
            draft = ""
            apiKey = ""
            refreshStoredKeyMask()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCodeGoCredentialsChanged)) { _ in
            let d = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
            workspaceID = d?.string(forKey: "workspaceID") ?? ""
            authCookie = d?.string(forKey: "authCookie") ?? ""
        }
        .alert("清除已存 Key？", isPresented: $confirmClearKey) {
            Button("清除", role: .destructive) { clearStoredKey() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 Keychain 与 App Group 里的 Key（影响额度查询）；「Codex 一键配置」里的 Go Key 需到那里单独清除。")
        }
        .alert("清除 workspace 凭据？", isPresented: $confirmClearWS) {
            Button("清除", role: .destructive) { clearWorkspaceCredentials() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除已存的 workspace ID 与 auth Cookie，柱状图费用会停止更新，可随时重新登录或粘贴。")
        }
    }

    private func refreshStoredKeyMask() {
        storedKeyMask = KeychainStore.resolvedKey().map { masked($0) } ?? ""
    }

    private func masked(_ s: String) -> String {
        guard s.count > 8 else { return "****" }
        return String(s.prefix(4)) + "****" + String(s.suffix(4))
    }

    private func clearStoredKey() {
        _ = KeychainStore.delete()
        draft = ""
        apiKey = ""
        refreshStoredKeyMask()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func clearWorkspaceCredentials() {
        let d = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
        d?.removeObject(forKey: "workspaceID")
        d?.removeObject(forKey: "authCookie")
        d?.synchronize()
        workspaceID = ""
        authCookie = ""
        harStatus = ""
        WidgetCenter.shared.reloadAllTimelines()
        NotificationCenter.default.post(name: .openCodeGoCredentialsChanged, object: nil)
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
