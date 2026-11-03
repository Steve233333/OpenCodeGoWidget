import SwiftUI
import WebKit

struct DetectedConsoleLogin: Equatable {
    let session: String
    let authCookie: String?
    let workspaceID: String?
}

struct ConsoleLoginWebView: UIViewRepresentable {
    let clearExistingCookies: Bool
    let onDetected: (DetectedConsoleLogin) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDetected: onDetected)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = OpenCodeKeyFetcher.safariUserAgent
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        let url = URL(string: "https://opencode.ai/console/login")!
        if clearExistingCookies {
            let types: Set<String> = [
                WKWebsiteDataTypeCookies,
                WKWebsiteDataTypeLocalStorage,
                WKWebsiteDataTypeSessionStorage,
            ]
            WKWebsiteDataStore.default().removeData(
                ofTypes: types,
                modifiedSince: .distantPast
            ) {
                webView.load(URLRequest(url: url))
            }
        } else {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onDetected: (DetectedConsoleLogin) -> Void
        private var lastToken = ""

        init(onDetected: @escaping (DetectedConsoleLogin) -> Void) {
            self.onDetected = onDetected
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let workspace = OpenCodeKeyFetcher.workspaceID(
                fromURL: webView.url?.absoluteString ?? ""
            )
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                let openCodeCookies = cookies.filter { $0.domain.contains("opencode.ai") }
                guard let session = openCodeCookies.first(where: {
                    $0.name == "__Host-console_session" && !$0.value.isEmpty
                })?.value else { return }
                let auth = openCodeCookies.first(where: {
                    $0.name == "auth" && !$0.value.isEmpty
                })?.value
                let token = "\(session)|\(auth ?? "")|\(workspace ?? "")"
                guard token != self.lastToken else { return }
                self.lastToken = token
                DispatchQueue.main.async {
                    self.onDetected(DetectedConsoleLogin(
                        session: session,
                        authCookie: auth,
                        workspaceID: workspace
                    ))
                }
            }
        }
    }
}

struct ConsoleLoginSheet: View {
    let forceFreshLogin: Bool
    let onLogin: (DetectedConsoleLogin) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hasHandledLogin = false

    var body: some View {
        NavigationStack {
            ConsoleLoginWebView(clearExistingCookies: forceFreshLogin) { detected in
                guard !hasHandledLogin else { return }
                hasHandledLogin = true
                Task {
                    await onLogin(detected)
                    dismiss()
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("登录 OpenCode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
