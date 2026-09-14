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
        guard let r = url.range(of: "/workspace/") else { return nil }
        let rest = url[r.upperBound...]
        let id = rest.split(separator: "/").first.map(String.init) ?? ""
        return id.hasPrefix("wrk_") ? id : nil
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
