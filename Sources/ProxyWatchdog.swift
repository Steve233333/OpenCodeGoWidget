import Foundation
import AppKit

/// 本地代理的看护（2026-09-23）。
///
/// 为什么有它：macOS 27 升级后 App 点「配置」时 PATH 很干净，`command -v python3` 命中了
/// Xcode 自带的 Python 3.9，它一时起不来 → launchd 任务挂着但没监听 → Codex 侧表现成
/// "Reconnecting… waiting for network"，用户只能自己再点一次「配置」。
///
/// 这里只负责"什么时候叫修"：启动后 10 秒、每 5 分钟、系统唤醒时先探活（端口有响应就立刻返回，
/// 平时零开销），没响应才去调 `ensure-proxy.sh`。**挑解释器 / 写 plist / 起服务 / 探活验证
/// 全在那一个脚本里**（安装器也调它），这边不复制任何规则。
@MainActor
final class ProxyWatchdog: ObservableObject {
    static let shared = ProxyWatchdog()

    enum Status: Equatable {
        case unknown      // 还没体检
        case ok           // 端口有响应
        case repaired     // 刚才死了，这次救回来了
        case failed       // 救不回来（要用户点「配置」）
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var detail: String = "还没体检"
    @Published private(set) var interpreter: String = ""
    @Published private(set) var version: String = ""
    @Published private(set) var lastRepairAt: String = ""
    @Published private(set) var busy = false

    private var timer: Timer?
    private var started = false

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var visionDir: URL { home.appendingPathComponent(".local/share/agent-vision-toolkit") }
    private static var ensureScript: URL { visionDir.appendingPathComponent("ensure-proxy.sh") }
    private static var runtimeFile: URL { visionDir.appendingPathComponent("proxy-runtime") }
    private static var logFile: URL { home.appendingPathComponent("Library/Logs/opencodego-watchdog.log") }
    private static let discoveryLabel = "com.steve233.go-model-discovery"

    // MARK: - 调度

    func start() {
        guard !started else { return }
        started = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.check(reason: "唤醒") }
        }
        Task {
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            await check(reason: "启动")
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.check(reason: "定时") }
        }
        timer?.tolerance = 30
    }

    // MARK: - 体检 / 修复

    /// 先探活：活着就只刷新状态（读 proxy-runtime），死了才动手修。
    func check(reason: String) async {
        if await HealthCheck.proxyResponds() {
            refreshFromRuntime()
            status = .ok
            detail = "本地代理在跑" + (interpreter.isEmpty ? "" : "（\(version.isEmpty ? "Python" : version)）")
            return
        }
        await repair(reason: reason)
    }

    /// 手动按钮走这条：不管端口活不活，都让 ensure-proxy 跑一次（它就是幂等的）。
    func repairNow() async {
        await repair(reason: "手动")
    }

    private func repair(reason: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        let script = ensureScriptForRun()
        guard let script else {
            status = .failed
            detail = "找不到 ensure-proxy.sh（点「配置」重装一次）"
            appendLog("\(reason)：找不到 \(Self.ensureScript.path)")
            return
        }

        appendLog("\(reason)：代理没响应 → 调 ensure-proxy.sh")
        let (rc, output) = await runProcess("/bin/bash", [script.path, "--trigger", "watchdog", "--quiet"], timeout: 120)
        let alive = await HealthCheck.proxyResponds()
        refreshFromRuntime()

        if alive {
            status = .repaired
            detail = "刚才代理没在跑，已自动修好" + (interpreter.isEmpty ? "" : "（\(interpreter.split(separator: "/").last ?? "")）")
            appendLog("\(reason)：✅ 已修复（rc=\(rc)）\(output.suffix(200))")
        } else {
            status = .failed
            detail = "代理没起来（rc=\(rc)）：\(output.split(separator: "\n").last.map(String.init) ?? "详情见 ~/Library/Logs/opencodego-watchdog.log")"
            appendLog("\(reason)：❌ 修复失败（rc=\(rc)）：\(output)")
        }
        ensureDiscoveryJobLoaded(reason: reason)
    }

    // MARK: - 细节

    /// 脚本优先用 home 里的那份（launchd 用的就是它）；没有就从 App 包里拷一份过去。
    private func ensureScriptForRun() -> URL? {
        if FileManager.default.isExecutableFile(atPath: Self.ensureScript.path) { return Self.ensureScript }
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("codex/vision/ensure-proxy.sh"),
           FileManager.default.fileExists(atPath: bundled.path) {
            try? FileManager.default.createDirectory(at: Self.visionDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: Self.ensureScript)
            try? FileManager.default.copyItem(at: bundled, to: Self.ensureScript)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Self.ensureScript.path)
            if FileManager.default.isExecutableFile(atPath: Self.ensureScript.path) { return Self.ensureScript }
        }
        return nil
    }

    /// "新模型自动发现"也是我们的服务：plist 在但没挂上时就重新挂（同一个责任，顺手看住）
    private func ensureDiscoveryJobLoaded(reason: String) {
        let plist = Self.home.appendingPathComponent("Library/LaunchAgents/\(Self.discoveryLabel).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return }
        let rc = runSync("/bin/launchctl", ["print", "gui/\(getuid())/\(Self.discoveryLabel)"])
        if rc != 0 {
            _ = runSync("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path])
            appendLog("\(reason)：重新挂上 \(Self.discoveryLabel)")
        }
    }

    private func refreshFromRuntime() {
        guard let text = try? String(contentsOf: Self.runtimeFile, encoding: .utf8) else { return }
        var map: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { map[String(parts[0])] = String(parts[1]) }
        }
        interpreter = map["interpreter"] ?? ""
        version = map["version"] ?? ""
        lastRepairAt = map["last_repair_at"] ?? ""
    }

    private func appendLog(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(text)\n"
        try? FileManager.default.createDirectory(at: Self.logFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: Self.logFile) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: Self.logFile)
        }
    }

    private func runSync(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// 跑外部命令并等结果；超时就掐掉（看护绝不能自己卡住）
    private func runProcess(_ path: String, _ args: [String], timeout: TimeInterval) async -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return (-1, "启动失败：\(error.localizedDescription)") }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if proc.isRunning {
            proc.terminate()
            return (-9, "ensure-proxy.sh 超时（\(Int(timeout)) 秒）")
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
