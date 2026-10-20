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
struct KeychainParseTestRunner {
    static func main() {
        let nested = #"{"deepseek":{"key":"ds-key","type":"api"},"opencode-go":{"key":"new-go-key","type":"api"}}"#
        check(KeychainStore.parseAuthJSON(Data(nested.utf8)) == "new-go-key", "新版嵌套 opencode-go.key")

        let legacyZen = #"{"zen":{"key":"zen-key","type":"api"}}"#
        check(KeychainStore.parseAuthJSON(Data(legacyZen.utf8)) == "zen-key", "兼容 zen provider")

        let flat = #"{"api_key":"flat-key"}"#
        check(KeychainStore.parseAuthJSON(Data(flat.utf8)) == "flat-key", "兼容旧版扁平字段")

        check(KeychainStore.parseAuthJSON(Data("{}".utf8)) == nil, "空对象返回 nil")
        check(KeychainStore.parseAuthJSON(Data("not-json".utf8)) == nil, "畸形 JSON 不崩")

        if failures.isEmpty {
            print("全部通过 ✅")
            exit(0)
        }
        print("有失败项 ❌")
        exit(1)
    }
}
