import Foundation

// MARK: - opencode.ai 控制台密钥拉取（2026-09-14）
//
// 浏览器登录后，用会话 Cookie 直接拉官方密钥页；页面 SSR 序列化数据里，
// 本人名下的 Key 会带完整 sk- 值（管理员看别人的 Key 只有 keyDisplay）。
// 只做 GET + 解析，不在本 App 里改官方数据（创建/删除请用内嵌浏览器打开官网操作）。

struct RemoteApiKey: Identifiable, Equatable {
    let id: String          // key_...
    let name: String        // 密钥名称
    let secret: String?     // 完整 sk-...（只有本人 Key 才拿得到）
    let display: String     // sk-9MrT...y7Dg

    var isUsable: Bool { !(secret ?? "").isEmpty }
}

enum OpenCodeKeyFetcher {
    enum FetchError: LocalizedError {
        case badResponse(Int)
        var errorDescription: String? {
            switch self {
            case .badResponse(let code):
                return "官网返回 \(code)，登录可能已过期，请在下方浏览器重新登录"
            }
        }
    }

    /// 与 Safari 对齐的 UA，降低登录页/风控把内嵌浏览器当机器人拦的概率
    static let safariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Safari/605.1.15"

    /// 拉取 workspace 密钥页 HTML
    static func fetchKeysHTML(workspaceID: String, authCookie: String) async throws -> String {
        guard let url = URL(string: "https://opencode.ai/workspace/\(workspaceID)/keys") else {
            throw FetchError.badResponse(0)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("oc_locale=zh; auth=\(authCookie)", forHTTPHeaderField: "Cookie")
        req.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code), let html = String(data: data, encoding: .utf8) else {
            throw FetchError.badResponse(code)
        }
        return html
    }

    /// 2026-10-07：新控制台页面已变成 SPA 空壳（实测 1565 字节、无内嵌数据），改走 JSON 接口。
    /// ⚠️ 接口只给 `tokenHint`（sk-9MrT…y7Dg），**拿不到完整密钥**——官方改成"创建时一次性展示"。
    static func fetchServiceAccounts(workspaceID: String, authCookie: String,
                                     consoleSession: String) async throws -> [RemoteApiKey] {
        guard let url = URL(string: "https://opencode.ai/console/api/service-accounts") else {
            throw FetchError.badResponse(0)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        var cookie = "oc_locale=zh"
        if !authCookie.isEmpty { cookie += "; auth=\(authCookie)" }
        if !consoleSession.isEmpty { cookie += "; __Host-console_session=\(consoleSession)" }
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(workspaceID, forHTTPHeaderField: "x-org-id")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(safariUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://opencode.ai/console/\(workspaceID)/service-accounts", forHTTPHeaderField: "Referer")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw FetchError.badResponse(code) }
        return parseServiceAccounts(data)
    }

    /// 新接口 JSON → RemoteApiKey（secret 恒为 nil：上游不再提供完整值）
    static func parseServiceAccounts(_ data: Data) -> [RemoteApiKey] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return [] }
        var out: [RemoteApiKey] = []
        for acct in items {
            for k in (acct["keys"] as? [[String: Any]]) ?? [] {
                guard (k["status"] as? String) == "active" else { continue }
                let id = k["id"] as? String ?? UUID().uuidString
                let name = k["name"] as? String ?? ""
                let hint = (k["tokenHint"] as? String) ?? ""
                out.append(RemoteApiKey(id: id, name: name, secret: nil, display: hint))
            }
        }
        return out
    }

    /// 解析 SSR 序列化数据里的密钥记录：
    /// {id:"key_...",name:"...",key:"sk-...",...,keyDisplay:"sk-9MrT...y7Dg"}
    /// 别人的 Key 没有完整值（key:void 0），secret 为 nil。
    static func parseKeys(from html: String) -> [RemoteApiKey] {
        var result: [RemoteApiKey] = []
        var seen = Set<String>()
        let pattern = #"id:"(key_[^"]+)"([\s\S]*?)keyDisplay:"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges == 4 {
            guard let idR = Range(m.range(at: 1), in: html),
                  let bodyR = Range(m.range(at: 2), in: html),
                  let dispR = Range(m.range(at: 3), in: html) else { continue }
            let id = String(html[idR])
            guard seen.insert(id).inserted else { continue }
            let body = String(html[bodyR])
            let name = Self.firstGroup(#"name:"([^"]*)""#, in: body) ?? ""
            let secret = Self.firstGroup(#"key:"(sk-[A-Za-z0-9]+)""#, in: body)
            result.append(RemoteApiKey(id: id, name: name, secret: secret, display: String(html[dispR])))
        }
        return result
    }

    /// 从 URL（如 https://opencode.ai/workspace/wrk_xxx/keys）里取 workspace ID
    static func workspaceID(fromURL url: String) -> String? {
        // 2026-10-07：上游新控制台地址是 /console/<wrk_…>/…（旧的是 /workspace/<wrk_…>/…）。
        // 只认 "/workspace/" 的老写法在新控制台下一律返回 nil → 登录后 workspace 与凭据都填不上。
        // 现在按 token 扫：URL 里任何一段以 wrk_ 开头的合法 ID 都认，上游再改前缀也不会失效。
        let tokens = url.split { !($0.isLetter || $0.isNumber || $0 == "_") }
        return tokens.first { $0.hasPrefix("wrk_") && $0.count > 8 }.map(String.init)
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
