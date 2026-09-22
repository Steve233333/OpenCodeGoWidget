import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WidgetKit
import Charts
import ServiceManagement

// 设置面板（含 Go 额度设置、Codex 安装、自检入口、清除缓存）。2026-09-23 Phase 2 从 App.swift 拆出。

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
            Divider()
            HealthCheckRow()
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
