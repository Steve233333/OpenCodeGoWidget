import Foundation
import Combine
import AppKit

// MARK: - 模型与常量

enum CodexInstallMode: String, CaseIterable, Identifiable {
    case install = "install"
    case update = "update"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .install: return "安装 / 重装"
        case .update: return "更新（复用旧 Key）"
        }
    }
    var cliFlag: String {
        switch self {
        case .install: return "--install"
        case .update: return "--update"
        }
    }
}

struct CodexStatus: Equatable {
    var isInstalled: Bool = false
    var configExists: Bool = false
    var modelsExists: Bool = false
    var modelCount: Int = 0
    var defaultModel: String = "-"
    var hasGo: Bool = false
    var hasDS: Bool = false
    var hasGLM: Bool = false
    var envExists: Bool = false
    var patchedExists: Bool = false
    var patchedVersion: String = "-"
    var proxyRunning: Bool = false
    var proxyPlistExists: Bool = false
    var passExists: Bool = false
    var goKeyLength: Int = 0
    var dsKeyMasked: String = "-"
    var logPath: String = ""
}

// MARK: - 安装器引擎

@MainActor
final class CodexInstaller: ObservableObject {
    @Published var logText: String = ""
    @Published var isRunning: Bool = false
    @Published var status: CodexStatus = CodexStatus()
    @Published var lastExitCode: Int32? = nil

    private var process: Process?

    // 路径常量
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    static var codexHome: String { (home as NSString).appendingPathComponent(".codex-deepseek") }
    static var envFile: String { (home as NSString).appendingPathComponent(".config/agent-vision-toolkit/env") }
    static var patchBase: String { (home as NSString).appendingPathComponent(".codex/picker-patch") }
    static var passFile: String { (patchBase as NSString).appendingPathComponent(".keychain-pass") }
    static var logFile: String { (home as NSString).appendingPathComponent("Library/Logs/codex-oneclick-setup.log") }
    static var proxyPlist: String { (home as NSString).appendingPathComponent("Library/LaunchAgents/com.agent-vision-toolkit.proxy.plist") }
    static var discoveryPlist: String { (home as NSString).appendingPathComponent("Library/LaunchAgents/com.steve233.go-model-discovery.plist") }

    // MARK: - 资源定位

    /// 优先取 App Bundle 内的 codex/codex-oneclick-setup.command，开发期回退到源码 Resources/codex
    static func bundledInstallerPath() -> String? {
        // 1. Bundle Resources/codex
        if let r = Bundle.main.resourceURL?.appendingPathComponent("codex/codex-oneclick-setup.command").path,
           FileManager.default.isExecutableFile(atPath: r) || FileManager.default.fileExists(atPath: r) {
            return r
        }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("codex-oneclick-setup.command").path,
           FileManager.default.fileExists(atPath: r) {
            return r
        }
        // 2. 相对于可执行文件 ../Resources/codex
        let execURL = Bundle.main.executableURL?.deletingLastPathComponent()
        if let exec = execURL?.appendingPathComponent("../Resources/codex/codex-oneclick-setup.command").standardized.path,
           FileManager.default.fileExists(atPath: exec) {
            return exec
        }
        // 3. 开发期源码路径
        let devCandidates = [
            "/Users/steve233/Desktop/OpenCodeGoWidget-main/Resources/codex/codex-oneclick-setup.command",
            FileManager.default.currentDirectoryPath + "/Resources/codex/codex-oneclick-setup.command"
        ]
        for p in devCandidates where FileManager.default.fileExists(atPath: p) { return p }
        return nil
    }

    static func bundledCodexResourcesDir() -> String? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("codex").path,
           FileManager.default.fileExists(atPath: r) { return r }
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent()
        if let e = execDir?.appendingPathComponent("../Resources/codex").standardized.path,
           FileManager.default.fileExists(atPath: e) { return e }
        let dev = "/Users/steve233/Desktop/OpenCodeGoWidget-main/Resources/codex"
        if FileManager.default.fileExists(atPath: dev) { return dev }
        return nil
    }

    // MARK: - 状态检测

    static func detectStatus() -> CodexStatus {
        var s = CodexStatus()
        let fm = FileManager.default
        let codexHome = codexHome
        let configPath = (codexHome as NSString).appendingPathComponent("config.toml")
        let modelsPath = (codexHome as NSString).appendingPathComponent("models.json")
        let envPath = envFile
        let patchedPath = (home as NSString).appendingPathComponent("Applications/ChatGPT-Patched.app")
        let patchedAlt = "/Applications/ChatGPT-Patched.app"
        s.configExists = fm.fileExists(atPath: configPath)
        s.modelsExists = fm.fileExists(atPath: modelsPath)
        s.envExists = fm.fileExists(atPath: envPath)
        s.passExists = fm.fileExists(atPath: passFile)
        s.proxyPlistExists = fm.fileExists(atPath: proxyPlist)
        s.patchedExists = fm.fileExists(atPath: patchedPath) || fm.fileExists(atPath: patchedAlt)
        s.isInstalled = s.configExists || s.envExists
        s.logPath = logFile

        // model count + default
        if s.modelsExists, let data = try? Data(contentsOf: URL(fileURLWithPath: modelsPath)),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = j["models"] as? [[String: Any]] {
            s.modelCount = arr.count
        }
        if s.configExists, let txt = try? String(contentsOfFile: configPath, encoding: .utf8) {
            // 安全提取 model = "..."（用捕获组，避免手动下标越界）
            if let regex = try? NSRegularExpression(pattern: #"model\s*=\s*"([^"]+)""#),
               let m = regex.firstMatch(in: txt, range: NSRange(txt.startIndex..., in: txt)),
               let r = Range(m.range(at: 1), in: txt) {
                let v = String(txt[r])
                if !v.isEmpty { s.defaultModel = v }
            }
            // bearer
            if txt.contains("experimental_bearer_token") { s.hasDS = true }
        }
        // env 解析
        if let env = try? String(contentsOfFile: envPath, encoding: .utf8) {
            for line in env.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("ZEN_API_KEY=") {
                    let v = String(t.dropFirst("ZEN_API_KEY=".count)).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !v.isEmpty { s.hasGo = true; s.goKeyLength = v.count }
                }
                if t.hasPrefix("VISION_API_KEY=") {
                    let v = String(t.dropFirst("VISION_API_KEY=".count)).trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty && !v.hasPrefix("#") { s.hasGLM = true }
                }
            }
        }
        // 如果 env 没有 Go，尝试从 models.json 判断
        if !s.hasGo && s.modelCount > 0, let data = try? Data(contentsOf: URL(fileURLWithPath: modelsPath)),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = j["models"] as? [[String: Any]] {
            s.hasGo = arr.contains { ($0["slug"] as? String ?? "").hasSuffix("-go") || ($0["slug"] as? String ?? "").hasSuffix("-zen") }
        }
        // patched version — 修复：原先 String(m[r]) 对 m 越界导致 EXC_BREAKPOINT
        let marker = (patchBase as NSString).appendingPathComponent("patch-state.json")
        if let txt = try? String(contentsOfFile: marker, encoding: .utf8) {
            if let regex = try? NSRegularExpression(pattern: #""sourceVersion"\s*:\s*"([^"]+)""#),
               let match = regex.firstMatch(in: txt, range: NSRange(txt.startIndex..., in: txt)),
               let range = Range(match.range(at: 1), in: txt) {
                let v = String(txt[range])
                if !v.isEmpty { s.patchedVersion = v }
            }
        }
        if s.patchedVersion == "-" || s.patchedVersion.isEmpty {
            // 回退读原版 ChatGPT 版本
            let plistCandidates = [
                "/Applications/ChatGPT.app/Contents/Info.plist",
                (home as NSString).appendingPathComponent("Applications/ChatGPT.app/Contents/Info.plist")
            ]
            for p in plistCandidates {
                if let v = Bundle(path: (p as NSString).deletingLastPathComponent.replacingOccurrences(of: "/Contents/Info.plist", with: ""))?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    s.patchedVersion = v; break
                }
                if let dict = NSDictionary(contentsOfFile: p) as? [String: Any], let v = dict["CFBundleShortVersionString"] as? String {
                    s.patchedVersion = v; break
                }
            }
        }
        // 代理是否监听 19100
        s.proxyRunning = isPortListening(19100)

        // ds masked
        if let ds = existingDSKey(), !ds.isEmpty {
            s.dsKeyMasked = maskedKey(ds)
            if !s.hasDS { s.hasDS = true }
        }
        // go masked length already
        return s
    }

    static func existingGoKey() -> String {
        let envPath = envFile
        guard let content = try? String(contentsOfFile: envPath, encoding: .utf8) else { return "" }
        for line in content.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("ZEN_API_KEY=") {
                let v = String(t.dropFirst("ZEN_API_KEY=".count)).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !v.isEmpty { return v }
            }
        }
        // fallback to KeychainStore
        return KeychainStore.resolvedKey() ?? ""
    }

    static func existingDSKey() -> String? {
        let configPath = (codexHome as NSString).appendingPathComponent("config.toml")
        guard let txt = try? String(contentsOfFile: configPath, encoding: .utf8) else { return nil }
        // experimental_bearer_token = "..."
        guard let regex = try? NSRegularExpression(pattern: #"experimental_bearer_token\s*=\s*"([^"]+)""#) else { return nil }
        let ns = txt as NSString
        guard let m = regex.firstMatch(in: txt, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        let r = m.range(at: 1)
        let v = ns.substring(with: r)
        return v.isEmpty ? nil : v
    }

    static func existingGLMKey() -> String {
        let envPath = envFile
        guard let content = try? String(contentsOfFile: envPath, encoding: .utf8) else { return "" }
        for line in content.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("VISION_API_KEY=") {
                let v = String(t.dropFirst("VISION_API_KEY=".count)).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !v.isEmpty && !v.hasPrefix("#") { return v }
            }
        }
        return ""
    }

    static func existingPass() -> String {
        let p = passFile
        guard let v = try? String(contentsOfFile: p, encoding: .utf8) else { return "" }
        return v.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func maskedKey(_ k: String) -> String {
        guard k.count > 8 else { return "****" }
        return String(k.prefix(6)) + "****" + String(k.suffix(4))
    }

    private static func isPortListening(_ port: Int) -> Bool {
        // 用 URLSession 探活 127.0.0.1:19100，比 lsof 更沙盒友好
        // 同步探活：尝试连一个 TCP socket
        let host = "127.0.0.1"
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let portStr = "\(port)"
        guard getaddrinfo(host, portStr, &hints, &res) == 0, let r = res else { return false }
        defer { freeaddrinfo(res) }
        let fd = socket(r.pointee.ai_family, r.pointee.ai_socktype, r.pointee.ai_protocol)
        if fd < 0 { return false }
        defer { close(fd) }
        // 1 秒超时
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let rc = connect(fd, r.pointee.ai_addr, r.pointee.ai_addrlen)
        return rc == 0
    }

    // MARK: - 刷新状态

    func refreshStatus() {
        status = Self.detectStatus()
    }

    // MARK: - 执行安装

    /// 非交互执行安装器（走 --noninteractive），日志流式回到 logText
    func run(mode: CodexInstallMode,
             goKey: String,
             dsKey: String,
             glmKey: String,
             pass: String,
             skipPatch: Bool = false,
             skipProxyStart: Bool = false) {
        guard !isRunning else { return }
        guard let installer = Self.bundledInstallerPath() else {
            logText += "\n[错误] 未找到 codex-oneclick-setup.command（Bundle Resources/codex 缺失）\n"
            return
        }
        isRunning = true
        logText = "[\(Self.timestamp())] 准备执行 \(mode.rawValue) 模式...\n"
        logText += "安装器: \(installer)\n"
        if let resDir = Self.bundledCodexResourcesDir() {
            logText += "资源目录: \(resDir)\n"
        }
        lastExitCode = nil

        // 去空格
        let go = goKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let ds = dsKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let glm = glmKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let pwd = pass.trimmingCharacters(in: .whitespacesAndNewlines)

        // 统一校验：Go 必填（留空时需有旧 Go），密码必填（留空时需有旧密码）
        let existingGo = Self.existingGoKey()
        let existingDS = Self.existingDSKey() ?? ""
        _ = Self.existingGLMKey()
        let existingPass = Self.existingPass()
        let effectiveGo = go.isEmpty ? existingGo : go
        let effectiveDS = ds.isEmpty ? existingDS : ds
        let effectivePass = pwd.isEmpty ? existingPass : pwd
        if effectiveGo.isEmpty {
            logText += "\n[错误] OpenCode Go Key 为必填项（首次配置必须填写，更新时留空可复用旧值）\n"
            isRunning = false; return
        }
        if effectivePass.isEmpty {
            logText += "\n[错误] 签名密码为必填项，请填写\n"
            isRunning = false; return
        }
        // DeepSeek / GLM 可选，不校验；Go/密码之外的有效性由安装器进一步检查
        _ = effectiveDS

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        var args: [String] = [installer, "--noninteractive", mode.cliFlag]
        if skipPatch { args.append("--skip-patch") }
        if skipProxyStart { args.append("--skip-proxy-start") }
        proc.arguments = args

        // 环境变量
        var env = ProcessInfo.processInfo.environment
        env["ONECLICK_GO_KEY"] = go
        env["ONECLICK_DS_KEY"] = ds
        env["ONECLICK_GLM_KEY"] = glm
        env["ONECLICK_PASS"] = pwd
        // 兼容：部分旧安装器读 ZEN_API_KEY
        if !go.isEmpty { env["ZEN_API_KEY"] = go }
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: (installer as NSString).deletingLastPathComponent)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // 异步读输出
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.logText += s }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.logText += s }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // 兜底把剩余缓冲读完
                if let d = try? outPipe.fileHandleForReading.readToEnd(), let s = String(data: d, encoding: .utf8), !s.isEmpty { self?.logText += s }
                if let d = try? errPipe.fileHandleForReading.readToEnd(), let s = String(data: d, encoding: .utf8), !s.isEmpty { self?.logText += s }
                self?.lastExitCode = p.terminationStatus
                if p.terminationStatus == 0 {
                    self?.logText += "\n[完成] 退出码 0 ✅\n"
                    // 同步 Keychain：Go Key 存入 Keychain 供 Widget 直接用
                    if !go.isEmpty { KeychainStore.save(go) }
                } else {
                    self?.logText += "\n[失败] 退出码 \(p.terminationStatus) ❌\n"
                }
                self?.isRunning = false
                self?.refreshStatus()
            }
        }

        do {
            try proc.run()
            self.process = proc
            logText += "[\(Self.timestamp())] 已启动 PID \(proc.processIdentifier)\n\n"
        } catch {
            logText += "\n[错误] 启动失败: \(error.localizedDescription)\n"
            isRunning = false
        }
    }

    /// 极简单按钮入口：安装/更新已合并，调用方只需传 4 栏（留空自动复用旧值）
    func configure(goKey: String, dsKey: String, glmKey: String, pass: String) {
        // 根据是否已安装自动选模式：已安装走 --update（保留 models.json 逻辑），全新走 --install
        let mode: CodexInstallMode = status.isInstalled ? .update : .install
        run(mode: mode, goKey: goKey, dsKey: dsKey, glmKey: glmKey, pass: pass)
    }

    func cancel() {
        process?.terminate()
        // 也尝试 kill 整个进程组
        if let pid = process?.processIdentifier {
            kill(pid, SIGTERM)
        }
    }

    func openLogFile() {
        let p = Self.logFile
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }
    func openConfigFolder() {
        let p = Self.codexHome
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }
    func openPatchedApp() {
        let candidates = [
            NSHomeDirectory() + "/Applications/ChatGPT-Patched.app",
            "/Applications/ChatGPT-Patched.app"
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            NSWorkspace.shared.open(URL(fileURLWithPath: c)); return
        }
        NSSound.beep()
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
