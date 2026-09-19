import Foundation
import WebKit

/// 把 App 自己会话里的 opencode.ai cookie 同步到 App Group。
///
/// 需要同步两个：
///   - `auth`：老站 / 密钥页用
///   - `__Host-console_session`：**新控制台的会话**（2026-09-19 改版后 `/console/api/*`
///     全靠它；只发 auth 会 401 —— 这就是"费用不刷新"的真因）
///
/// 读取优先级：
///   1) 直接解析磁盘上的 `~/Library/HTTPStorages/<bundle>.binarycookies`
///      —— 实测这里两个 cookie 都在（WebKit 的 `httpCookieStore` 有时读不到 `__Host-` 前缀的）
///   2) 兜底再问 `WKWebsiteDataStore.default()`（必须在主线程调用，否则 WebKit 初始化断言崩溃）
enum CookieSync {
    static let suiteName = "2DC432GLL2.com.steve233.opencodego"
    static let authKey = "authCookie"
    static let sessionKey = "consoleSession"
    private static let wanted = ["auth", "__Host-console_session"]

    struct SyncResult {
        var authChanged = false
        var sessionChanged = false
        var found: [String: Int] = [:]   // cookie 名 -> 值长度（诊断用）
    }

    @discardableResult
    static func syncAuthCookie() async -> Bool {
        await syncAllCookies().authChanged
    }

    @discardableResult
    static func syncAllCookies() async -> SyncResult {
        var values = cookiesFromDisk()
        if values.isEmpty {
            values = await webkitCookies()
        }
        let defaults = UserDefaults(suiteName: suiteName)
        var result = SyncResult()
        for (name, key) in [("auth", authKey), ("__Host-console_session", sessionKey)] {
            guard let value = values[name], !value.isEmpty else { continue }
            result.found[name] = value.count
            let old = defaults?.string(forKey: key) ?? ""
            guard old != value else { continue }
            defaults?.set(value, forKey: key)
            if key == authKey { result.authChanged = true } else { result.sessionChanged = true }
        }
        defaults?.synchronize()
        return result
    }

    /// 直接解析 binarycookies（CFNetwork 的存储格式）
    static func cookiesFromDisk() -> [String: String] {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.steve233.opencodego"
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/HTTPStorages/\(bundleID).binarycookies")
        guard let data = FileManager.default.contents(atPath: path.path), data.count > 8 else { return [:] }
        guard Array(data.prefix(4)) == Array("cook".utf8) else { return [:] }

        func be32(_ i: Int) -> Int { (Int(data[i]) << 24) | (Int(data[i + 1]) << 16) | (Int(data[i + 2]) << 8) | Int(data[i + 3]) }
        func le32(_ i: Int) -> Int { Int(data[i]) | (Int(data[i + 1]) << 8) | (Int(data[i + 2]) << 16) | (Int(data[i + 3]) << 24) }
        func cstr(_ start: Int) -> String {
            var end = start
            while end < data.count && data[end] != 0 { end += 1 }
            return String(decoding: data[start..<end], as: UTF8.self)
        }

        let pages = be32(4)
        guard pages > 0, pages < 64 else { return [:] }
        var sizes: [Int] = []
        for i in 0..<pages { sizes.append(be32(8 + 4 * i)) }
        var cursor = 8 + 4 * pages
        var out: [String: String] = [:]
        for size in sizes {
            guard size > 8, cursor + size <= data.count else { break }
            let count = le32(cursor + 4)
            guard count > 0, count < 4096 else { cursor += size; continue }
            for i in 0..<count {
                let rec = cursor + le32(cursor + 8 + 4 * i)
                guard rec + 32 <= data.count else { continue }
                let urlOff = le32(rec + 16), nameOff = le32(rec + 20), valOff = le32(rec + 28)
                let domain = cstr(rec + urlOff), name = cstr(rec + nameOff), value = cstr(rec + valOff)
                // __Host- 前缀的 cookie 域是精确主机名，其它可能是 .opencode.ai
                if domain.contains("opencode.ai"), wanted.contains(name), !value.isEmpty {
                    out[name] = value
                }
            }
            cursor += size
        }
        return out
    }

    /// 兜底：问 WebKit 的 cookie 仓库（必须主线程）
    @MainActor
    static func webkitCookies() async -> [String: String] {
        await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                var out: [String: String] = [:]
                for c in cookies where c.domain.contains("opencode.ai") && wanted.contains(c.name) && !c.value.isEmpty {
                    out[c.name] = c.value
                }
                cont.resume(returning: out)
            }
        }
    }

    /// 诊断用：报 cookie 库里 opencode.ai 的 cookie 名字与长度（不泄露值）
    static func describeCookies() async -> String {
        var values = cookiesFromDisk()
        if values.isEmpty { values = await webkitCookies() }
        guard !values.isEmpty else { return "cookie 库里没有 opencode.ai 的登录 cookie" }
        return values.map { "\($0.key)(\($0.value.count)字符)" }.sorted().joined(separator: " · ")
    }
}
