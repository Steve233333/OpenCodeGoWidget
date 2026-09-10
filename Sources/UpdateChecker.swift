import Foundation
import AppKit
import SwiftUI

// MARK: - 应用内更新（2026-09-10）
//
// 设计：打开设置页时自动查一次 GitHub 最新 Release（24 小时节流），菜单栏也有入口。
// 只有用户点「更新」才下载安装，不做后台静默更新。
// 流程：下载 ZIP -> ditto 解包 -> 校验 bundle id/版本 -> 脱离脚本等本 App 退出
//      -> 旧版改名 .bak-旧版本 -> 拷入新版 -> 去隔离属性 -> 重新打开。

struct UpdateInfo: Equatable {
    var version: String
    var tag: String
    var notes: String
    var zipURL: URL?
    var pageURL: URL
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(String)
    case available(UpdateInfo)
    case downloading(Double)
    case preparing
    case failed(String)
}

extension Notification.Name {
    /// 菜单栏「检查更新…」-> 主窗口打开设置页
    static let openCodeGoOpenSettings = Notification.Name("com.steve233.opencodego.openSettings")
}

final class UpdateChecker: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = UpdateChecker()
    static let repo = "Steve233333/OpenCodeGoWidget"
    private static let lastCheckKey = "lastUpdateCheckAt"
    private static let checkInterval: TimeInterval = 24 * 3600

    @Published var state: UpdateState = .idle
    private var session: URLSession?
    private var pendingInfo: UpdateInfo?

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
    }
    static var currentBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "-"
    }

    /// 打开设置页时调用：24 小时内只自动查一次
    func checkIfNeeded() {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if last > 0, Date().timeIntervalSince1970 - last < Self.checkInterval { return }
        check(force: false)
    }

    func check(force: Bool) {
        if case .checking = state { return }
        state = .checking
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else {
            state = .failed("更新地址不合法"); return
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("OpenCodeGoWidget-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self else { return }
            if let error {
                self.checkViaRedirect(reason: "接口不通：\(error.localizedDescription)")
                return
            }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                // 最常见的是未登录接口被限流（403 rate limit），换不需要 API 的方式
                self.checkViaRedirect(reason: "GitHub 接口不可用（多为未登录限流）")
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let notes = (obj["body"] as? String) ?? ""
            let page = (obj["html_url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/\(Self.repo)/releases/latest")!
            var zip: URL?
            if let assets = obj["assets"] as? [[String: Any]] {
                for a in assets {
                    guard let name = a["name"] as? String,
                          let dl = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { continue }
                    if name.lowercased().hasSuffix(".zip") { zip = dl; break }
                }
            }
            let info = UpdateInfo(version: version, tag: tag, notes: notes, zipURL: zip, pageURL: page)
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                self.state = Self.isNewer(version, than: Self.currentVersion) ? .available(info) : .upToDate(Self.currentVersion)
            }
        }.resume()
    }

    /// 备用检查：直接请求 releases/latest，跟着 302 跳到 /releases/tag/vX.Y.Z 拿版本号。
    /// 不走 api.github.com，所以不吃未登录限流（VPN/共享出口很常见）。
    private func checkViaRedirect(reason: String) {
        guard let url = URL(string: "https://github.com/\(Self.repo)/releases/latest") else {
            return fail("检查失败：\(reason)")
        }
        var req = URLRequest(url: url)
        req.setValue("OpenCodeGoWidget-Updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                return self.fail("检查失败：\(reason)；备用方式也不通（\(error.localizedDescription)）")
            }
            let finalURL = response?.url ?? url
            let tag = finalURL.pathComponents.last(where: { $0.hasPrefix("v") }) ?? ""
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard !version.isEmpty, version.first?.isNumber == true else {
                return self.fail("检查失败：\(reason)")
            }
            let zipURL = URL(string: "https://github.com/\(Self.repo)/releases/download/\(tag)/OpenCodeGoWidget-\(version).zip")
            let pageURL = URL(string: "https://github.com/\(Self.repo)/releases/tag/\(tag)")!
            let info = UpdateInfo(version: version, tag: tag,
                                  notes: "（走备用检查，说明见 Release 页面）",
                                  zipURL: zipURL, pageURL: pageURL)
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                self.state = Self.isNewer(version, than: Self.currentVersion) ? .available(info) : .upToDate(Self.currentVersion)
            }
        }.resume()
    }

    // MARK: - 版本比较（1.1.8.10 > 1.1.8.9）
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// 用户点「更新」：下载 + 解包 + 校验，然后交给脱离脚本替换并重启
    func install() {
        guard case .available(let info) = state else { return }
        guard let zip = info.zipURL else {
            state = .failed("这个版本没有 ZIP 包，请到 Release 页面手动下载")
            NSWorkspace.shared.open(info.pageURL)
            return
        }
        pendingInfo = info
        state = .downloading(-1)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        var req = URLRequest(url: zip)
        req.setValue("OpenCodeGoWidget-Updater", forHTTPHeaderField: "User-Agent")
        s.downloadTask(with: req).resume()
    }

    // MARK: - URLSessionDownloadDelegate
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.state = .downloading(p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 系统会在本回调返回后删掉 location，必须先搬走
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocgw-update-\(UUID().uuidString)", isDirectory: true)
        let zipPath = tmp.appendingPathComponent("update.zip")
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: zipPath)
        } catch {
            return fail("下载文件保存失败：\(error.localizedDescription)")
        }
        DispatchQueue.main.async { self.state = .preparing }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.unpackAndInstall(zipPath: zipPath, workDir: tmp)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        fail("下载失败：\(error.localizedDescription)")
    }

    private func fail(_ msg: String) {
        DispatchQueue.main.async { self.state = .failed(msg) }
    }

    private func unpackAndInstall(zipPath: URL, workDir: URL) {
        let fm = FileManager.default
        let extractDir = workDir.appendingPathComponent("extract", isDirectory: true)
        try? fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipPath.path, extractDir.path]
        do { try ditto.run() } catch { return fail("解压失败：\(error.localizedDescription)") }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            return fail("解压失败（ditto 退出码 \(ditto.terminationStatus)）")
        }
        guard let enumerator = fm.enumerator(at: extractDir, includingPropertiesForKeys: nil) else {
            return fail("解压后找不到应用")
        }
        var newApp: URL?
        for case let item as URL in enumerator where item.pathExtension == "app" {
            newApp = item; break
        }
        guard let newApp else { return fail("下载包里没有 .app") }

        let plist = newApp.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) as? [String: Any] else {
            return fail("新版本 Info.plist 读不到，已放弃安装")
        }
        let bid = dict["CFBundleIdentifier"] as? String ?? ""
        let ver = dict["CFBundleShortVersionString"] as? String ?? ""
        let want = pendingInfo?.version ?? ""
        guard bid == Bundle.main.bundleIdentifier else {
            return fail("下载包的 bundle id（\(bid)）不对，已放弃安装")
        }
        guard !want.isEmpty, !Self.isNewer(ver, than: want) else {
            return fail("下载包版本（\(ver)）与目标（\(want)）不符，已放弃安装")
        }

        let appPath = Bundle.main.bundlePath
        let parent = (appPath as NSString).deletingLastPathComponent
        guard fm.isWritableFile(atPath: parent) else {
            let page = pendingInfo?.pageURL ?? URL(string: "https://github.com/\(Self.repo)/releases/latest")!
            DispatchQueue.main.async {
                self.state = .failed("没有权限更新 \(parent)，请到 Release 页面手动下载")
                NSWorkspace.shared.open(page)
            }
            return
        }
        launchSwapScript(newApp: newApp.path, appPath: appPath, oldVersion: Self.currentVersion)
    }

    private func launchSwapScript(newApp: String, appPath: String, oldVersion: String) {
        let script = """
        #!/bin/bash
        # OpenCodeGoWidget 自动更新：等本 App 退出后替换旧版
        APP="$1"; NEW="$2"; PID="$3"; OLD="$4"
        # 先等 App 自己优雅退出（设置面板开着时 AppKit 可能拖几秒）
        for _ in $(seq 1 20); do
          kill -0 "$PID" 2>/dev/null || break
          sleep 0.5
        done
        # 还没退就兜底结束它：替换/重启已在进行，不能一直等下去
        if kill -0 "$PID" 2>/dev/null; then
          kill -TERM "$PID" 2>/dev/null || true
          sleep 2
          kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
        fi
        sleep 0.5
        BAK="${APP}.bak-${OLD}"
        rm -rf "$BAK"
        mv "$APP" "$BAK" 2>/dev/null || true
        if /usr/bin/ditto "$NEW" "$APP"; then
          /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
          /usr/bin/open "$APP"
        else
          rm -rf "$APP"
          mv "$BAK" "$APP" 2>/dev/null || true
          /usr/bin/open "$APP"
        fi
        rm -rf "$(dirname "$NEW")"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocgw-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            return fail("更新脚本写入失败：\(error.localizedDescription)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path, appPath, newApp,
                          String(ProcessInfo.processInfo.processIdentifier), oldVersion]
        do { try proc.run() } catch { return fail("更新脚本启动失败：\(error.localizedDescription)") }
        DispatchQueue.main.async {
            self.state = .preparing
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.terminate(nil)
                // 兜底：设置面板还开着时 AppKit 可能把退出往后拖，替换脚本在等本进程消失。
                // 3 秒还没走就强制退出——此时该保存的都已落盘，没有可丢的状态。
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { exit(0) }
            }
        }
    }
}

// MARK: - 设置页里的更新一行

struct UpdateStatusRow: View {
    @ObservedObject private var updater = UpdateChecker.shared

    var body: some View {
        HStack(spacing: 8) {
            Text("版本 \(UpdateChecker.currentVersion) (\(UpdateChecker.currentBuild))")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            statusText
            Spacer()
            actionButton
        }
        .onAppear { updater.checkIfNeeded() }
    }

    @ViewBuilder private var statusText: some View {
        switch updater.state {
        case .checking:
            Text("检查中…").font(.system(size: 9)).foregroundStyle(.secondary)
        case .upToDate:
            Text("已是最新").font(.system(size: 9)).foregroundStyle(.secondary)
        case .available(let info):
            Text("发现新版 \(info.version)").font(.system(size: 9)).foregroundStyle(.orange)
        case .downloading(let p):
            Text(p < 0 ? "下载中…" : String(format: "下载中 %.0f%%", p * 100))
                .font(.system(size: 9)).foregroundStyle(.orange)
        case .preparing:
            Text("正在安装并重启…").font(.system(size: 9)).foregroundStyle(.orange)
        case .failed(let msg):
            Text(msg).font(.system(size: 9)).foregroundStyle(.red).lineLimit(2)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch updater.state {
        case .available(let info):
            Button("更新") { updater.install() }
                .controlSize(.mini)
                .help("下载 \(info.tag) 并自动替换当前版本后重启")
        case .downloading, .preparing, .checking:
            ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
        default:
            Button("检查更新") { updater.check(force: true) }
                .controlSize(.mini)
        }
    }
}
