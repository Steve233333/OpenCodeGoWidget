import SwiftUI
import AppKit
import Charts
import WidgetKit

/// 主面板（仪表盘）：额度卡片 + 费用图 + 今日模型 + 图例。
/// 2026-09-23 Phase 2 从 App.swift 拆出（原来 1265 行一个文件装着整个界面）。
/// 改名：`ContentView` → `DashboardView`（小组件自己也叫 ContentView，两个同名类型容易看串）。
struct DashboardView: View {
    // 2026-09-20：这里以前直接 KeychainStore.load() —— 那是**读钥匙串**，重签后 macOS 会弹授权框，
    // 而且这行是视图属性初始化，弹框会把整个界面构造卡住（窗口画不出来、刷新也不跑）。
    // 改用 resolvedKey()（App Group → env 文件 → 钥匙串），并且真正读盘放到 .task 里。
    @State private var apiKey: String = ""
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
    // 代理看护：救不回来时在面板顶部给一行红字（不打扰、也不要通知权限）
    @ObservedObject private var watchdog = ProxyWatchdog.shared
    @State private var autoTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()
    /// 历史回填在跑时，每 5 秒把快照重读回界面 —— 否则进度条要等 5 分钟自动刷新才动一次
    @State private var liveTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var backfillRunning = false

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
                    if watchdog.status == .failed {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("本地代理没起来：Codex 会显示「Reconnecting… waiting for network」")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.red)
                                Text(watchdog.detail).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("修复") { Task { await watchdog.repairNow() } }
                                .controlSize(.mini)
                                .disabled(watchdog.busy)
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
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
                                    // 图例（2026-09-22 改）：**只有 Go 配额表里的模型有独立颜色**，
                                    // 表外的一律合并成灰色「其他」——用户要的就是这个口径，
                                    // 免得一堆"配额表里没有"的模型（omen-alpha / union-alpha / 免费 Zen…）
                                    // 各自占一个色块，还动不动被判成"已下架"。
                                    let _ = modelTick
                                    let allModels = Set(filteredDaily.flatMap { $0.entries.keys }.map { $0.lowercased() })
                                    let quotaOrdered = ModelPalette.quotaSlugs
                                    let quotaLower = Set(quotaOrdered.map { $0.lowercased() })
                                    let otherModels = allModels.subtracting(quotaLower)
                                        .filter { !$0.hasPrefix("(") }   // (total) 是内部占位，不算模型
                                        .sorted()
                                    let legend = quotaOrdered + (otherModels.isEmpty ? [] : [ModelPalette.otherName])
                                    if !legend.isEmpty {
                                        WrappingLegendView(models: legend)
                                    }
                                    if !otherModels.isEmpty {
                                        Text("灰色「其他」= 不在 Go 配额表里的模型（\(otherModels.count) 个：\(otherModels.prefix(4).joined(separator: "、"))\(otherModels.count > 4 ? " 等" : "")）")
                                            .font(.system(size: 8))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    // 历史明细回填进度（2026-09-19）：改成进度条。
                                    // 判断依据是"实际还差几天明细"，不看那个一次性闩锁 ——
                                    // 历史被粗数据冲掉时也要能提示、能补回来。
                                    let withDetail = filteredDaily.filter { $0.entries.contains { $0.key != "(total)" && $0.value > 0 } }.count
                                    if withDetail < filteredDaily.count {
                                        let frac = filteredDaily.isEmpty ? 0 : Double(withDetail) / Double(filteredDaily.count)
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 6) {
                                                Text(backfillRunning ? "历史明细补齐中（后台，可关窗口）" : "历史明细待补齐（下次刷新自动补）")
                                                    .font(.system(size: 8, weight: .medium))
                                                Spacer()
                                                Text("\(withDetail)/\(filteredDaily.count) 天")
                                                    .font(.system(size: 8).monospacedDigit())
                                            }
                                            .foregroundStyle(.orange)
                                            MiniProgressBar(fraction: frac, tint: .orange)
                                        }
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
                                        // 同样折叠成「配额表模型 + 其他」，和图例/柱子口径一致
                                        CostBar(entries: ModelPalette.foldedEntries(filteredCostEntries),
                                                total: filteredCostTotal)
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
        // 高度跟窗口走（窗口可拉伸），宽度锁 620
        .frame(minWidth: 620, maxWidth: 620, minHeight: 480, maxHeight: .infinity)
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
            // 登录态变化（含换账号 → 刚清过缓存）后立即拉一次数据；先清空内存里的旧快照，
            // 免得抹掉缓存后界面还挂着上一个账号的数字
            snapshot = nil
            Task { await refresh() }
        }
        .task {
            // 真正读 Key 放在这里（而不是属性初始化）：读钥匙串可能弹授权框，绝不能挡住界面构造
            if apiKey.isEmpty { apiKey = KeychainStore.resolvedKey() ?? "" }
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
            // 2026-09-20：以前只有"快照为空"才在启动时刷新 —— 结果打开 App 看到的是上一次的旧数据，
            // 要等 5 分钟自动那轮或手点「刷新」。现在快照超过 3 分钟就直接刷一次。
            let stale = snapshot.map { Date().timeIntervalSince($0.updatedAt) > 180 } ?? true
            if snapshot == nil || stale { await refresh() }
        }
        .onReceive(autoTimer) { _ in
            guard !loading else { return }
            Task { await refresh() }
        }
        // 回填在跑：每 5 秒把刚写到盘上的明细读回界面，进度条与柱子同步往前爬
        .onReceive(liveTimer) { _ in
            let running = BackfillProgress.isRunning()
            if running != backfillRunning { backfillRunning = running }
            if running, !loading, let s = WidgetDataStore.load() { snapshot = s }
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
        // 先把 WKWebView 里最新的 opencode.ai 登录态同步过来（改版后 SPA 路由不触发旧的检测回调），
        // 否则用的是过期 cookie，新控制台 API 会一直 401、费用不更新
        // 2026-09-20：CookieSync 里可能走 WKWebView（磁盘 cookie 缺失时），而 WebKit 没有超时 ——
        // 一旦 web 进程起不来/页面卡住，await 永不返回：界面停在 loading，5 分钟定时器被 `guard !loading`
        // 挡住，用户看到的就是"点了刷新没反应、数据再也不更新"。给这一步加 8 秒硬超时。
        let cookieSynced = await withTaskGroup(of: Bool?.self) { group -> Bool in
            group.addTask { await CookieSync.syncAuthCookie() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
        if cookieSynced {
            widgetStoreWarning = nil
        }
        // 刷新额度/费用前强制同步模型列表与配额表（用户主动刷新应立即体现官方新增，失败静默）
        async let modelRefresh: [String] = ModelRegistry.refreshIfNeeded(force: true)
        async let zenRefresh: [String] = ModelRegistry.refreshZenIfNeeded(force: true)
        async let quotaRefresh: [GoQuota] = GoQuotaRegistry.refreshIfNeeded(force: true)
        do {
            // 用户主动刷新（含每 5 分钟自动那轮）连带重拉一次密钥列表：
            // 控制台新建的 Key 应该立刻出现在下拉框里，而不是等缓存空掉（2026-09-24）
            let snap = try await WidgetSnapshotRefresher.fetch(forceKeys: true)
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
            // 后台补历史明细（改版前那几天只有总额、没有模型维度 → 图上纯色）；不阻塞界面，可续跑
            // 2026-09-19：补完直接把快照读回界面 + 通知小组件，不用用户再点一次「刷新」
            Task {
                let repaired = await CostCrawler.shared.backfillHistoryIfNeeded()
                if repaired, let s = WidgetDataStore.load() {
                    await MainActor.run { snapshot = s }
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
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

/// 细进度条（历史明细回填进度用）
struct MiniProgressBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(tint)
                    .frame(width: max(2, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 5)
    }
}
