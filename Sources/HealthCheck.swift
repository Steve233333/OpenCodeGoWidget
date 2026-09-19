import Foundation

/// 一条体检结果
struct HealthItem: Identifiable {
    enum Level { case ok, warn, fail }
    let id = UUID()
    let level: Level
    let title: String
    let detail: String

    var symbol: String {
        switch level {
        case .ok: return "✅"
        case .warn: return "⚠️"
        case .fail: return "❌"
        }
    }
}

/// 「环境自检」：把「新机器上到底哪一步没配上」一次问清楚。
///
/// 覆盖：Go Key / DeepSeek Key 存在性 + **真实有效性**（各发一个最小请求）、
/// 本地代理进程与端口、自动发现任务、模型目录、双开副本、小组件共享通道。
/// 每项都带证据（状态码、文件路径、版本号），坏机器上点一下就能把报告贴出来。
enum HealthCheck {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let envFile = home.appendingPathComponent(".config/agent-vision-toolkit/env")
    static let codexHome = home.appendingPathComponent(".codex-deepseek")

    static func run() async -> [HealthItem] {
        var items: [HealthItem] = []

        // ---- 1. 本地代理：进程 + 端口 ----
        let proxyLoaded = launchctlHas("com.agent-vision-toolkit.proxy")
        let proxyAlive = await proxyResponds()
        if proxyLoaded && proxyAlive {
            items.append(HealthItem(level: .ok, title: "本地代理", detail: "已加载且 127.0.0.1:19100 有响应"))
        } else if proxyAlive {
            items.append(HealthItem(level: .warn, title: "本地代理", detail: "端口有响应，但 launchd 里没找到任务（重启后会消失，建议重跑一次「配置」）"))
        } else {
            items.append(HealthItem(level: .fail, title: "本地代理", detail: "127.0.0.1:19100 没响应；Codex 会报 502。点「配置」重建，或看 ~/Library/Logs/codex-oneclick-setup.log"))
        }

        // ---- 2. Go 模型自动发现任务 ----
        let discoveryLoaded = launchctlHas("com.steve233.go-model-discovery")
        let discoveryPlist = home.appendingPathComponent("Library/LaunchAgents/com.steve233.go-model-discovery.plist")
        if discoveryLoaded {
            items.append(HealthItem(level: .ok, title: "新模型自动发现", detail: "每 6 小时跑一次（launchd 已加载）"))
        } else if FileManager.default.fileExists(atPath: discoveryPlist.path) {
            items.append(HealthItem(level: .warn, title: "新模型自动发现", detail: "plist 在但没加载（重启/重登后会丢）→ 点一次「配置」"))
        } else {
            items.append(HealthItem(level: .fail, title: "新模型自动发现", detail: "没安装：官方上新模型不会被自动加进 Codex（点「配置」可装）"))
        }

        // ---- 3. Go Key：存在性 + 有效性 ----
        let envKey = readEnvKey()
        let keychainKey = KeychainStore.load()
        let goKey = (envKey?.isEmpty == false ? envKey : nil) ?? keychainKey
        if let k = goKey, !k.isEmpty {
            items.append(HealthItem(level: .ok, title: "Go Key 存在",
                                    detail: "env \(envKey?.isEmpty == false ? "有" : "无") · Keychain \(keychainKey?.isEmpty == false ? "有" : "无") · \(mask(k))"))
            let (level, detail) = await testGoKey(k)
            items.append(HealthItem(level: level, title: "Go Key 有效", detail: detail))
        } else {
            items.append(HealthItem(level: .fail, title: "Go Key 存在", detail: "env 和 Keychain 都没有 → Go 模型会 502/401。用「浏览器登录自动获取」或手填后再点「配置」"))
        }

        // ---- 4. DeepSeek Key：存在性 + 有效性 ----
        let dsKey = readDeepSeekKey()
        if let k = dsKey, !k.isEmpty {
            items.append(HealthItem(level: .ok, title: "DeepSeek Key 存在", detail: mask(k)))
            let (level, detail) = await testDeepSeekKey(k)
            items.append(HealthItem(level: level, title: "DeepSeek Key 有效", detail: detail))
        } else {
            items.append(HealthItem(level: .warn, title: "DeepSeek Key 存在",
                                    detail: "没配置（只影响官方 DeepSeek 模型；如果只用 Go 模型可以忽略）"))
        }

        // ---- 5. Codex 配置与模型目录 ----
        let configToml = codexHome.appendingPathComponent("config.toml")
        let modelsJSON = codexHome.appendingPathComponent("models.json")
        if FileManager.default.fileExists(atPath: configToml.path) {
            items.append(HealthItem(level: .ok, title: "Codex 配置", detail: configToml.path))
        } else {
            items.append(HealthItem(level: .fail, title: "Codex 配置", detail: "缺 \(configToml.path) → 点「配置」生成"))
        }
        if let data = try? Data(contentsOf: modelsJSON),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = obj["models"] as? [[String: Any]] {
            let goCount = models.filter { ($0["slug"] as? String)?.hasSuffix("-go") == true }.count
            let level: HealthItem.Level = models.count >= 30 ? .ok : .warn
            items.append(HealthItem(level: level, title: "模型目录",
                                    detail: "\(models.count) 个模型（其中 Go \(goCount) 个）"))
        } else {
            items.append(HealthItem(level: .fail, title: "模型目录", detail: "读不到 \(modelsJSON.path)"))
        }

        // ---- 6. 双开副本 ----
        // 官方 app 可能装在两处：/Applications（标准）或 ~/Applications（我这台就是）
        // —— 2026-09-19 修：以前只查 ~/Applications，装在 /Applications 的机器被误报"找不到官方 app"
        let officialCandidates = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/ChatGPT.app"),
        ]
        let official = officialCandidates.compactMap { versionOf($0) }.first
        let patched = versionOf(home.appendingPathComponent("Applications/ChatGPT-Patched.app"))
        switch (official, patched) {
        case let (o?, p?):
            items.append(HealthItem(level: o == p ? .ok : .warn, title: "双开副本",
                                    detail: "官方 \(o) · 副本 \(p)" + (o == p ? "" : "（不一致，点「配置」会按官方版重建副本）")))
        case (nil, _):
            items.append(HealthItem(level: .fail, title: "双开副本",
                                    detail: "找不到官方 app（/Applications/ChatGPT.app 和 ~/Applications/ChatGPT.app 都没有）→ 先装官方 Codex 再点「配置」"))
        default:
            items.append(HealthItem(level: .fail, title: "双开副本", detail: "官方版在，但没生成副本 → 点「配置」（会显示补丁日志）"))
        }

        // ---- 7. Python 的 CA 证书：新机器 502 的头号原因 ----
        let (certLevel, certDetail) = pythonCertCheck()
        items.append(HealthItem(level: certLevel, title: "Python 证书", detail: certDetail))

        // ---- 8. 费用凭据（workspace + cookie）：决定"费用/额度刷不刷新" ----
        let ws = groupValue("workspaceID")
        let cookie = groupValue("authCookie")
        if ws.isEmpty || cookie.isEmpty {
            items.append(HealthItem(level: .warn, title: "费用凭据",
                                    detail: "workspace \(ws.isEmpty ? "缺" : "有") · authCookie \(cookie.isEmpty ? "缺" : "有") → 费用图/额度不会更新；点「浏览器登录自动获取」"))
        } else {
            let (level, detail) = await testCostCredentials(ws, cookie)
            items.append(HealthItem(level: level, title: "费用凭据", detail: detail))
        }

        // ---- 9. 小组件共享通道（复用已有诊断） ----
        let widgetLoad = WidgetDataStore.loadDetailed()
        items.append(HealthItem(level: widgetLoad.snapshot == nil ? .warn : .ok, title: "小组件数据通道",
                                detail: widgetLoad.snapshot == nil
                                    ? "读不到快照（来源：\(widgetLoad.source)）；装完 App 刷新一次即可"
                                    : "来源：\(widgetLoad.source)"))

        // ---- 10. 代理最近一次报错：502 的真正原因就写在这儿 ----
        let logPath = home.appendingPathComponent(".local/share/agent-vision-toolkit/proxy.err.log")
        if let text = try? String(contentsOf: logPath, encoding: .utf8) {
            let recent = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(600).filter {
                $0.contains("handler error") || $0.contains("Upstream network error")
                    || $0.contains("fallback FAILED") || $0.contains("not set in env")
            }
            if let last = recent.last {
                items.append(HealthItem(level: .warn, title: "代理最近一次报错",
                                        detail: String(last.trimmingCharacters(in: .whitespaces).prefix(260))))
            } else {
                items.append(HealthItem(level: .ok, title: "代理错误日志", detail: "最近 600 行里没有报错"))
            }
        } else {
            items.append(HealthItem(level: .warn, title: "代理错误日志", detail: "读不到 \(logPath.path)"))
        }

        return items
    }

    // MARK: - 具体检查

    static func launchctlHas(_ label: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["list"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.split(separator: "\n").contains { $0.contains(label) }
    }

    static func proxyResponds() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:19100/v1/models")!)
        req.timeoutInterval = 4
        return await withCheckedContinuation { cont in
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                cont.resume(returning: resp is HTTPURLResponse)
            }.resume()
        }
    }

    /// Go Key 有效性：发一个最小的 chat 请求（max_tokens=1，几乎不耗额度）
    static func testGoKey(_ key: String) async -> (HealthItem.Level, String) {
        // 上游 5xx 是网关自己的事（经常抽风），不能算 Key 无效 —— 重试一次再判
        var lastDetail = ""
        for attempt in 0..<2 {
            let (level, detail) = await goKeyProbe(key)
            if level != .warn || attempt == 1 { return (level, detail) }
            lastDetail = detail
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        return (.warn, lastDetail)
    }

    private static func goKeyProbe(_ key: String) async -> (HealthItem.Level, String) {
        var req = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("opencodego-selftest/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "x-opencode-session")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            // 用 kimi-k3 而不是 deepseek-v4-flash：后者的 chat 适配层时不时整段 530/503
            // （2026-09-19 实测：deepseek-v4-flash chat 530，kimi-k3/glm-5.3 同一时刻 200），
            // 拿它探活会把"网关抽风"误报成"你的 Key/网络有问题"。
            "model": "kimi-k3",
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1,
        ])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else {
            return (.warn, "请求发不出去（网络/DNS 问题）—— 试试关掉 VPN 再自检")
        }
        switch http.statusCode {
        case 200...299: return (.ok, "实测可用（发了一次 max_tokens=1 的最小请求）")
        case 401, 403: return (.fail, "HTTP \(http.statusCode)：Key 无效或已失效 → 重新获取后再点「配置」")
        case 429: return (.ok, "HTTP 429：Key 有效，但当前被限流")
        case 500...599:
            let body = String(data: data, encoding: .utf8)?.prefix(110) ?? ""
            return (.warn, "HTTP \(http.statusCode)：上游网关报错（不是 Key 的问题，常见于网关抽风，过会儿再试）\(body)")
        default:
            let body = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
            return (.fail, "HTTP \(http.statusCode)：\(body)")
        }
    }

    /// DeepSeek Key 有效性：GET /models 是免费接口
    static func testDeepSeekKey(_ key: String) async -> (HealthItem.Level, String) {
        var req = URLRequest(url: URL(string: "https://api.deepseek.com/models")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else {
            return (.warn, "请求发不出去（网络/DNS 问题）")
        }
        if (200...299).contains(http.statusCode) { return (.ok, "实测可用（/models 返回 \(http.statusCode)）") }
        if http.statusCode == 401 { return (.fail, "HTTP 401：Key 无效") }
        if (500...599).contains(http.statusCode) { return (.warn, "HTTP \(http.statusCode)：上游报错，稍后再试") }
        let body = String(data: data, encoding: .utf8)?.prefix(120) ?? ""
        return (.fail, "HTTP \(http.statusCode)：\(body)")
    }

    // MARK: - 小工具

    /// 跑一次 python3 的 HTTPS 请求，专门抓 python.org 缺 CA 的经典错误

    /// 读 App Group 里的值时，UserDefaults 在非沙盒/无 entitlement 的进程里可能读不到，
    /// 直接兜底读容器里的 plist（组套件在容器内有自己的一份）。避免自检误报「没配置」。
    static func groupValue(_ key: String) -> String {
        if let v = UserDefaults(suiteName: WidgetDataStore.suiteName)?.string(forKey: key), !v.isEmpty { return v }
        let plist = home.appendingPathComponent(
            "Library/Group Containers/\(WidgetDataStore.suiteName)/Library/Preferences/\(WidgetDataStore.suiteName).plist")
        if let data = try? Data(contentsOf: plist),
           let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let v = obj[key] as? String {
            return v
        }
        return ""
    }

    static func pythonCertCheck() -> (HealthItem.Level, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c",
                       "import urllib.request; urllib.request.urlopen('https://opencode.ai', timeout=8)"]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        do { try p.run() } catch { return (.warn, "跑不了 python3（\(error.localizedDescription)）") }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        if errText.contains("CERTIFICATE_VERIFY_FAILED") {
            return (.fail, "python3 缺 CA 证书（代理会因此全部 502）→ 双击 /Applications/Python 3.x/ 里的 "
                           + "Install Certificates.command，或重新点一次「配置」（1.1.10.3 起会自动兜底 /etc/ssl/cert.pem）")
        }
        // 403/404 之类是服务器正常回话，说明 TLS 没问题
        if p.terminationStatus == 0 || errText.contains("HTTP Error") { return (.ok, "python3 能正常验证 HTTPS 证书") }
        return (.warn, "python3 请求异常：\(errText.split(separator: "\n").last.map(String.init) ?? "未知")")
    }

    /// 费用凭据实测：复刻 CostCrawler 的 `_server` 请求，只判断"能不能拿到数据"
    static func testCostCredentials(_ ws: String, _ cookie: String) async -> (HealthItem.Level, String) {
        // 2026-09-19 改版：改测新控制台 API（老 /_server 已下线，测它只会误报）
        var comps = URLComponents(string: "https://opencode.ai/console/api/usage/cost-by-day")!
        comps.queryItems = [URLQueryItem(name: "range", value: "30d")]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 20
        req.setValue("oc_locale=zh; auth=\(cookie)", forHTTPHeaderField: "Cookie")
        req.setValue(ws, forHTTPHeaderField: "x-org-id")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("https://opencode.ai/console/\(ws)/usage", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else {
            return (.warn, "请求发不出去（网络/DNS 问题）")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if (200...299).contains(http.statusCode) {
            return (.ok, "新控制台接口可用（HTTP \(http.statusCode)，\(text.count) 字节）样本：\(text.prefix(220))")
        }
        if http.statusCode == 401 {
            return (.fail, "HTTP 401：cookie 已失效（改版后新控制台要用新登录态）→ 重新点「浏览器登录自动获取」"
                           + "（必要时先「清除登录」）")
        }
        if text.contains("OrgRequired") || text.contains("org_required") {
            return (.warn, "HTTP \(http.statusCode)：缺 x-org-id（App 会带 workspace 值，正常不该出现）：\(text.prefix(120))")
        }
        return (.warn, "HTTP \(http.statusCode)：\(text.prefix(90))")
    }

    static func readEnvKey() -> String? {
        guard let text = try? String(contentsOf: envFile, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("ZEN_API_KEY=") {
            return String(line.dropFirst("ZEN_API_KEY=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\r"))
        }
        return nil
    }

    static func readDeepSeekKey() -> String? {
        let url = codexHome.appendingPathComponent("config.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("experimental_bearer_token") else { continue }
            let parts = t.split(separator: "\"")
            if parts.count >= 2 { return String(parts[1]) }
        }
        return nil
    }

    static func mask(_ key: String) -> String {
        guard key.count > 12 else { return "****" }
        return "\(key.prefix(6))…\(key.suffix(4))（\(key.count) 字符）"
    }

    static func versionOf(_ app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let v = obj["CFBundleShortVersionString"] as? String else { return nil }
        return v
    }
}
