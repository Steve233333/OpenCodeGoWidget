import Foundation

var failures: [String] = []

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  ✅ \(label)")
    } else {
        print("  ❌ \(label)")
        failures.append(label)
    }
}

@main
struct VersioningTestRunner {
    static func main() {
        print("— 版本比较 —")
        check(AppVersioning.isNewer("1.1.11.66", than: "1.1.11.65"), "补丁版本递增")
        check(AppVersioning.isNewer("1.2.0", than: "1.1.99"), "次版本优先")
        check(!AppVersioning.isNewer("1.1.11.65", than: "1.1.11.65"), "同版本不算更新")
        check(!AppVersioning.isNewer("v1.1.11.65", than: "1.1.11.65"), "v 前缀归一化")
        check(!AppVersioning.isNewer("1.1.11.65", than: "1.1.11.66"), "旧版本不算更新")

        print("— 下载包版本 —")
        check(AppVersioning.downloadedVersionMatches("1.1.11.66", expected: "1.1.11.66"), "正确 Release 必须接受（旧逻辑会误拒）")
        check(AppVersioning.downloadedVersionMatches("v1.1.11.66", expected: "1.1.11.66"), "v 前缀视为同一版本")
        check(AppVersioning.downloadedVersionMatches("1.1.11.066", expected: "1.1.11.66"), "数字段按整数比较")
        check(!AppVersioning.downloadedVersionMatches("1.1.11.65", expected: "1.1.11.66"), "旧包拒绝")
        check(!AppVersioning.downloadedVersionMatches("1.1.11.67", expected: "1.1.11.66"), "未来包也拒绝")
        check(!AppVersioning.downloadedVersionMatches("", expected: "1.1.11.66"), "空版本拒绝")

        if failures.isEmpty {
            print("全部通过 ✅")
            exit(0)
        }
        print("有失败项 ❌")
        exit(1)
    }
}
