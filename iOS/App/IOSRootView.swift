import SwiftUI
import WidgetKit

struct IOSRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var account = ConsoleAccountModel()
    @StateObject private var usage = IOSUsageController()
    @State private var showLogin = false
    @State private var forceFreshLogin = false
    @State private var selectedTab = 0

    var body: some View {
        Group {
            switch account.phase {
            case .checking:
                ProgressView("正在验证登录…")
            case .loggedOut, .expired:
                IOSLoginLandingView {
                    forceFreshLogin = account.phase == .expired
                    showLogin = true
                }
            case .loggingIn:
                ProgressView("正在保存登录…")
            case .loggedIn:
                IOSDashboardTabs(
                    account: account,
                    usage: usage,
                    selectedTab: $selectedTab,
                    onRelogin: {
                        forceFreshLogin = true
                        showLogin = true
                    }
                )
            case .error(let message):
                IOSLoginErrorView(message: message) {
                    forceFreshLogin = true
                    showLogin = true
                }
            }
        }
        .fullScreenCover(isPresented: $showLogin) {
            ConsoleLoginSheet(forceFreshLogin: forceFreshLogin) { detected in
                await account.receiveLogin(
                    sessionValue: detected.session,
                    authCookie: detected.authCookie,
                    workspaceHint: detected.workspaceID
                )
                if account.isLoggedIn {
                    await usage.refresh()
                }
            }
        }
        .task {
            await account.bootstrap()
            if account.isLoggedIn {
                await usage.refreshIfStale()
            }
        }
        .onChange(of: account.phase) { _, phase in
            if phase == .loggedIn {
                Task { await usage.refreshIfStale() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, account.isLoggedIn {
                Task { await usage.refreshIfStale(maxAge: 120) }
            } else if phase == .background {
                IOSBackgroundRefresh.schedule()
            }
        }
        .onOpenURL { url in
            guard url.scheme == "opencodego" else { return }
            selectedTab = 0
            Task { await usage.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            usage.reloadFromStorage()
        }
    }
}

private struct IOSLoginLandingView: View {
    let login: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 44)
                    BrandIconView(size: 78)
                    VStack(spacing: 8) {
                        Text("OpenCode Go").font(.largeTitle.bold())
                        Text("额度、花费、模型与 Key 用量")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        LoginFeature(icon: "gauge.with.dots.needle.50percent", title: "三档额度", detail: "5 小时、周、月与重置倒计时")
                        LoginFeature(icon: "chart.bar.xaxis", title: "完整用量", detail: "30 天历史、按模型和按 Key")
                        LoginFeature(icon: "square.grid.3x3.fill", title: "主屏与锁屏组件", detail: "不用输入 API Key")
                    }
                    .padding(18)
                    .background(Color.primary.opacity(0.045))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Button(action: login) {
                        Label("登录 OpenCode 账号", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Text("登录信息仅保存在本机 Keychain；小组件只读取 App Group 中的用量快照。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
            }
            .navigationTitle("OpenCode Go")
        }
    }
}

private struct LoginFeature: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct IOSLoginErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("无法验证登录", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("重新登录", action: retry)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct IOSDashboardTabs: View {
    @ObservedObject var account: ConsoleAccountModel
    @ObservedObject var usage: IOSUsageController
    @Binding var selectedTab: Int
    let onRelogin: () -> Void

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                IOSOverviewView(usage: usage, account: account, onRelogin: onRelogin)
            }
            .tabItem { Label("概览", systemImage: "gauge.with.dots.needle.50percent") }
            .tag(0)

            NavigationStack {
                IOSByKeyView(usage: usage)
            }
            .tabItem { Label("按 Key", systemImage: "key.fill") }
            .tag(1)

            NavigationStack {
                IOSModelsView(usage: usage)
            }
            .tabItem { Label("模型", systemImage: "chart.bar.doc.horizontal") }
            .tag(2)

            NavigationStack {
                IOSQuotaPage(usage: usage)
            }
            .tabItem { Label("配额", systemImage: "list.bullet.rectangle.portrait") }
            .tag(3)

            NavigationStack {
                IOSSettingsPage(account: account, usage: usage, onRelogin: onRelogin)
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(4)
        }
        .tint(.blue)
    }
}
