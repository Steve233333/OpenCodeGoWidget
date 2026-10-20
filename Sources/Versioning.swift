import Foundation

/// App 版本号的唯一比较规则。下载更新和“发现新版”共用，避免两处各写一份后再次分叉。
enum AppVersioning {
    static func components(_ raw: String) -> [Int] {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return cleaned.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = components(a)
        let y = components(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// 下载包必须正好是 Release 指向的版本；旧版、未来版和空版本都拒绝。
    static func downloadedVersionMatches(_ downloaded: String, expected: String) -> Bool {
        guard !downloaded.isEmpty, !expected.isEmpty else { return false }
        return components(downloaded) == components(expected)
    }
}
