import SwiftUI
import WebKit
import WidgetKit

// MARK: - 内嵌浏览器登录（2026-09-14）
//
// 目标：不用手填一堆东西。用户在弹窗里的真浏览器登录 opencode.ai 后：
//   1) 自动拿到 auth Cookie + workspace ID（柱状图费用立即有数据）
//   2) 自动拉取官方密钥页，回填完整 Go Key（Keychain + 两个设置栏）
// 注：Google 官方 OAuth 常拒绝内嵌浏览器，建议用 GitHub 登录。

extension Notification.Name {
    /// 拉取到新 Go Key（object = 完整 sk-...）→ 各输入框回填
    static let openCodeGoKeyFetched = Notification.Name("com.steve233.opencodego.keyFetched")
    /// Codex 页清除了已存 Go Key（object = "go"）
    static let openCodeGoStoredKeyCleared = Notification.Name("com.steve233.opencodego.storedKeyCleared")
    /// 登录态产生/清除（workspace 或 cookie 变化）→ 设置页刷新显示
    static let openCodeGoCredentialsChanged = Notification.Name("com.steve233.opencodego.credentialsChanged")
}

@MainActor
final class AccountSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loggedIn
        case fetching
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var remoteKeys: [RemoteApiKey] = []
    @Published var statusText: String = ""
    @Published var workspaceID: String = ""
    @Published var hasCookie = false

    private let defaults = UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")
    private var lastHandledCookie: String? = nil

    init() { reload() }

    func reload() {
        workspaceID = defaults?.string(forKey: "workspaceID") ?? ""
        hasCookie = !(defaults?.string(forKey: "authCookie") ?? "").isEmpty
        if hasCookie && !workspaceID.isEmpty, phase == .idle { phase = .loggedIn }
    }

    var cookieMasked: String {
        guard let c = defaults?.string(forKey: "authCookie"), !c.isEmpty else { return "未保存" }
        return "\(c.prefix(8))…（\(c.count) 字符）"
    }

    var workspaceMasked: String {
        guard !workspaceID.isEmpty else { return "未获取" }
        return workspaceID.count > 14 ? "\(workspaceID.prefix(10))…\(workspaceID.suffix(4))" : workspaceID
    }

    /// 登录 WebView 每次页面加载完成后回调；同一 Cookie 只自动处理一次
    func loginDetected(workspace: String?, cookie: String) {
        var cookieChanged = false
        var workspaceBecameAvailable = false
        if let ws = workspace, !ws.isEmpty, ws != workspaceID {
            workspaceID = ws
            workspaceBecameAvailable = true
            defaults?.set(ws, forKey: "workspaceID")
        }
        if (defaults?.string(forKey: "authCookie") ?? "") != cookie {
            defaults?.set(cookie, forKey: "authCookie")
            cookieChanged = true
        }
        hasCookie = true
        if phase != .fetching { phase = .loggedIn }
        NotificationCenter.default.post(name: .openCodeGoCredentialsChanged, object: nil)
        WidgetCenter.shared.reloadAllTimelines()
        // Cookie 先于 workspace 重定向可见时，等 workspace 到位再拉一次
        guard cookieChanged || workspaceBecameAvailable || lastHandledCookie == nil else { return }
        lastHandledCookie = cookie
        Task { await fetchKeys(autoApply: cookieChanged) }
    }

    func fetchKeys(autoApply: Bool = false) async {
        reload()
        guard hasCookie, !workspaceID.isEmpty,
              let cookie = defaults?.string(forKey: "authCookie"), !cookie.isEmpty else {
            phase = .error("还没有登录信息，请在下方浏览器里登录 opencode.ai")
            return
        }
        phase = .fetching
        statusText = "正在从 opencode.ai 拉取密钥…"
        do {
            let html = try await OpenCodeKeyFetcher.fetchKeysHTML(workspaceID: workspaceID, authCookie: cookie)
            let keys = OpenCodeKeyFetcher.parseKeys(from: html)
            remoteKeys = keys
            if keys.isEmpty {
                let expired = html.contains("/github/authorize") || html.contains("Continue with GitHub")
                phase = .error(expired ? "登录已过期，请在下方浏览器重新登录" : "没有解析到密钥，可在下方浏览器里创建")
                statusText = ""
            } else {
                statusText = "发现 \(keys.count) 个密钥"
                phase = .loggedIn
                if autoApply, let pick = autoPick(keys) {
                    applyKey(pick)
                }
            }
        } catch {
            phase = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            statusText = ""
        }
    }

    private func autoPick(_ keys: [RemoteApiKey]) -> RemoteApiKey? {
        let usable = keys.filter(\.isUsable)
        if usable.count == 1 { return usable[0] }
        if let def = usable.first(where: {
            $0.name.localizedCaseInsensitiveContains("default") || $0.name.contains("默认")
        }) {
            return def
        }
        return nil
    }

    /// 应用到所有需要的地方：Keychain + App Group（界面字段由通知回填）
    func applyKey(_ key: RemoteApiKey) {
        guard let secret = key.secret, !secret.isEmpty else { return }
        KeychainStore.save(secret)
        statusText = "已应用「\(key.name.isEmpty ? key.display : key.name)」到 Keychain，并回填配置栏"
        NotificationCenter.default.post(name: .openCodeGoKeyFetched, object: secret)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func clearLogin() {
        defaults?.removeObject(forKey: "authCookie")
        defaults?.removeObject(forKey: "workspaceID")
        defaults?.synchronize()
        workspaceID = ""
        hasCookie = false
        lastHandledCookie = nil
        remoteKeys = []
        phase = .idle
        statusText = "已清除登录凭据（可重新登录）"
        NotificationCenter.default.post(name: .openCodeGoCredentialsChanged, object: nil)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - WebView 句柄（供外部清 Cookie / 重载）

final class WebViewHandle: ObservableObject {
    weak var webView: WKWebView?

    /// 清掉内嵌浏览器里 opencode.ai 的 Cookie（退出登录时用）
    func clearCookies(completion: (() -> Void)? = nil) {
        guard let store = webView?.configuration.websiteDataStore else {
            DispatchQueue.main.async { completion?() }
            return
        }
        store.removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast) {
            DispatchQueue.main.async { completion?() }
        }
    }
}

// MARK: - WKWebView 包装

struct LoginWebView: NSViewRepresentable {
    let initialURL: URL
    let injectCookie: String?
    let handle: WebViewHandle
    let onLoginDetected: (_ workspace: String?, _ cookie: String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = OpenCodeKeyFetcher.safariUserAgent
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        handle.webView = web
        context.coordinator.load(into: web, cookie: injectCookie, url: initialURL)
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: LoginWebView
        private var lastNotified = ""

        init(_ parent: LoginWebView) { self.parent = parent }

        func load(into web: WKWebView, cookie: String?, url: URL) {
            let doLoad = { DispatchQueue.main.async { web.load(URLRequest(url: url)) } }
            // 2026-09-19：不再把 App 里存着的（可能已失效的）auth cookie 注入 WebView。
            // 老逻辑每次打开登录页都注入旧值，结果是：控制台改版后旧会话无效、页面又不让你重新登录，
            // 新 cookie（__Host-console_session）永远拿不到。WebView 自己就是持久化存储，
            // 之前登录过就直接是登录态；需要重新登录时也能正常走登录流程。
            _ = cookie
            return doLoad()
            /*
            guard let cookie, !cookie.isEmpty else { return doLoad() }
            let props: [HTTPCookiePropertyKey: Any] = [
                .domain: ".opencode.ai",
                .path: "/",
                .name: "auth",
                .value: cookie,
                .secure: "TRUE",
                .expires: Date().addingTimeInterval(30 * 24 * 3600)
            ]
            guard let c = HTTPCookie(properties: props) else { return doLoad() }
            web.configuration.websiteDataStore.httpCookieStore.setCookie(c, completionHandler: doLoad)
            */
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            detect(webView)
        }

        private func detect(_ webView: WKWebView) {
            let url = webView.url?.absoluteString ?? ""
            guard url.contains("opencode.ai") else { return }
            let ws = OpenCodeKeyFetcher.workspaceID(fromURL: url)
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                guard let auth = cookies.first(where: {
                    $0.name == "auth" && $0.domain.contains("opencode.ai") && !$0.value.isEmpty
                }) else { return }
                let token = "\(ws ?? "")|\(auth.value)"
                guard token != self.lastNotified else { return }
                self.lastNotified = token
                DispatchQueue.main.async { self.parent.onLoginDetected(ws, auth.value) }
            }
        }
    }
}

// MARK: - 登录弹窗

struct LoginSheetView: View {
    @ObservedObject var session: AccountSession
    @Environment(\.dismiss) var dismiss
    @StateObject private var webHandle = WebViewHandle()

    // 2026-09-19：OpenCode 换成新控制台，老 /auth 已下线 → 直接开新控制台的登录页，
    // 否则用户在这个 WebView 里登录完也拿不到新控制台的会话 cookie。
    private let authURL = URL(string: "https://opencode.ai/console/login")!

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            keysSection
            Divider()
            LoginWebView(
                initialURL: authURL,
                injectCookie: UserDefaults(suiteName: "2DC432GLL2.com.steve233.opencodego")?.string(forKey: "authCookie"),
                handle: webHandle,
                onLoginDetected: { ws, cookie in
                    session.loginDetected(workspace: ws, cookie: cookie)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 820, height: 660)
        .onAppear { session.reload() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: session.hasCookie ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                .foregroundStyle(session.hasCookie ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.hasCookie ? "已登录 opencode.ai（登录态自动保存）" : "请在下方浏览器里登录 opencode.ai")
                    .font(.caption.weight(.semibold))
                Text("workspace：\(session.workspaceMasked) · Cookie：\(session.cookieMasked) · \(session.statusText)")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if case .fetching = session.phase {
                ProgressView().scaleEffect(0.6)
            }
            Button("拉取密钥") { Task { await session.fetchKeys() } }
                .controlSize(.small)
                .disabled(!session.hasCookie)
            Button("清除登录") {
                session.clearLogin()
                webHandle.clearCookies {
                    webHandle.webView?.load(URLRequest(url: authURL))
                }
            }
            .controlSize(.small)
            .disabled(!session.hasCookie)
        }
        .padding(12)
    }

    @ViewBuilder
    private var keysSection: some View {
        if !session.remoteKeys.isEmpty {
            VStack(spacing: 0) {
                ForEach(session.remoteKeys) { key in
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(key.name.isEmpty ? "未命名" : key.name).font(.caption)
                        Text(key.display).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        if !key.isUsable {
                            Text("（他人密钥，只能看到缩写；可在官网删除/新建）")
                                .font(.system(size: 9)).foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("使用此 Key") { session.applyKey(key) }
                            .controlSize(.small)
                            .disabled(!key.isUsable)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    if key.id != session.remoteKeys.last?.id { Divider().padding(.leading, 32) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("登录后自动获取：Go Key（本人密钥才有完整值）、workspace、Cookie。推荐用 GitHub 登录；Google 可能拒绝内嵌浏览器。DeepSeek Key 官方只在创建时展示一次，请到 DeepSeek 控制台创建后复制。")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer()
            Button("打开 DeepSeek 控制台") {
                if let u = URL(string: "https://platform.deepseek.com/api_keys") {
                    NSWorkspace.shared.open(u)
                }
            }
            .controlSize(.small)
            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
    }
}
