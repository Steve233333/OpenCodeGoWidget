import Foundation

// 控制台密钥列表解析的离线回归测试（不联网）。
// 编译运行：scripts/test-key-parse.sh（打包前自动跑）
//
// 起因（2026-09-24）：下拉框"有缓存就永不刷新"、而「清除用量缓存」又没删密钥列表 →
// 控制台里新建的 Key 一直看不见。解析规则抽成 ApiKeyInfo.parseConsoleKeys 后，用真实结构锁住：
// 只留 active 且没过期的、账号名去掉 "Legacy: " 前缀、保持接口顺序、name 为空用 id 兜底。

/// 抄自 2026-09-24 控制台的真实结构（id/名字真实，不含任何 key 值）。
/// key_03 = 已吊销（就是你删掉的那把）；key_05 = 已过期；key_06 = 没名字。
let consoleKeysFixtureJSON = """
{"items":[{"account":{"id":"svcacct_01KT9VX0KZCD5SYNXH8D3EYJD8_01KT9VX0KZCYTT6YEX6127AK5S",
"name":"Legacy: steve23333@proton.me"},"keys":[
{"id":"key_01M0B525E7NNSV1EWC34FHSTYQ","name":"丁雁","status":"active","permissions":"inference-only","createdAt":"2026-08-18T19:20:07.000Z","revokedAt":null,"expiresAt":null},
{"id":"key_01M13VPQNY35W08DEVR6ZZN0GT","name":"方泽恩","status":"active","permissions":"inference-only","createdAt":"2026-08-28T09:37:36.000Z","revokedAt":null,"expiresAt":null},
{"id":"key_revoked","name":"临时","status":"revoked","permissions":"all","createdAt":"2026-09-23T16:59:47.000Z","revokedAt":"2026-09-23T17:03:55.000Z","expiresAt":null},
{"id":"key_active_new","name":"临时","status":"active","permissions":"inference-only","createdAt":"2026-09-23T17:04:13.000Z","revokedAt":null,"expiresAt":"2099-01-01T00:00:00.000Z"},
{"id":"key_expired","name":"过期钥匙","status":"active","createdAt":"2026-09-01T00:00:00.000Z","revokedAt":null,"expiresAt":"2026-09-10T00:00:00.000Z"},
{"id":"key_noname","status":"active","createdAt":"2026-09-01T00:00:00.000Z"}
]}]}
"""

var keyListFailures: [String] = []
func keyListCheck(_ cond: Bool, _ name: String) {
    if cond { print("  ✅ \(name)") } else { print("  ❌ \(name)"); keyListFailures.append(name) }
}

/// 固定"现在"，让过期判定可重复（真实 fixture 里的过期时间是写死的）
func fixedNow() -> Date {
    ApiKeyInfo.parseISO8601("2026-09-24T04:00:00.000Z")!
}

func testConsoleKeyListBasics() {
    print("— 控制台密钥列表解析 —")
    let data = consoleKeysFixtureJSON.data(using: .utf8)!
    guard let list = ApiKeyInfo.parseConsoleKeys(data, now: fixedNow()) else {
        keyListCheck(false, "真实样例应能解析（返回 nil 说明结构判定挂了）")
        return
    }
    keyListCheck(list.keys.count == 4, "6 把里只留 4 把有效的（实际 \(list.keys.count)）")
    keyListCheck(list.skipped == 2, "跳过 2 把（已吊销 1 + 已过期 1，实际 \(list.skipped)）")
    keyListCheck(list.keys.map(\.id) == ["key_01M0B525E7NNSV1EWC34FHSTYQ",
                                         "key_01M13VPQNY35W08DEVR6ZZN0GT",
                                         "key_active_new",
                                         "key_noname"],
                 "保持接口顺序，且吊销/过期的不在列表里")
    keyListCheck(list.keys.first?.displayName == "steve23333@proton.me - 丁雁",
                 "账号名去掉 Legacy: 前缀（实际 \(list.keys.first?.displayName ?? "nil")）")
    keyListCheck(list.keys[2].displayName == "steve23333@proton.me - 临时", "新建的「临时」带账号前缀")
    keyListCheck(list.keys[3].displayName == "steve23333@proton.me - key_noname",
                 "key 没有 name 时用 id 兜底")
    keyListCheck(!list.keys.contains { $0.id == "key_revoked" }, "已吊销的不进下拉框")
    keyListCheck(!list.keys.contains { $0.id == "key_expired" }, "已过期的不进下拉框")
}

func testConsoleKeyListEdgeCases() {
    print("— 账号名与过期边界 —")
    // 没有 Legacy 前缀的账号名原样保留
    let plain = """
    {"items":[{"account":{"name":"Team A"},"keys":[{"id":"k1","name":"小子","status":"active"}]}]}
    """.data(using: .utf8)!
    let plainList = ApiKeyInfo.parseConsoleKeys(plain, now: fixedNow())
    keyListCheck(plainList?.keys.first?.displayName == "Team A - 小子", "非 Legacy 账号名原样保留")
    // 账号名缺失 → 只显示 key 名
    let noAccount = """
    {"items":[{"keys":[{"id":"k2","name":"孤零零","status":"active"}]}]}
    """.data(using: .utf8)!
    keyListCheck(ApiKeyInfo.parseConsoleKeys(noAccount, now: fixedNow())?.keys.first?.displayName == "孤零零",
                 "账号名缺失时只显示 key 名")
    // 过期时间写着边界（正好等于 now）→ 视为已过期
    let boundary = """
    {"items":[{"keys":[{"id":"k3","name":"刚好到期","status":"active","expiresAt":"2026-09-24T04:00:00.000Z"}]}]}
    """.data(using: .utf8)!
    keyListCheck(ApiKeyInfo.parseConsoleKeys(boundary, now: fixedNow())?.keys.isEmpty == true,
                 "expiresAt 正好等于现在 → 已过期")
    // 过期时间解析不出来 → 宁可多留（不误删能用的钥匙）
    let brokenExpiry = """
    {"items":[{"keys":[{"id":"k4","name":"日期坏了","status":"active","expiresAt":"not-a-date"}]}]}
    """.data(using: .utf8)!
    keyListCheck(ApiKeyInfo.parseConsoleKeys(brokenExpiry, now: fixedNow())?.keys.count == 1,
                 "expiresAt 解析不出来 → 保留（不误删）")
    // 不带毫秒的时间也要认得
    keyListCheck(ApiKeyInfo.parseISO8601("2026-09-23T17:03:55Z") != nil, "不带毫秒的 ISO 时间也能解析")
}

func testConsoleKeyListMalformed() {
    print("— 畸形输入 —")
    keyListCheck(ApiKeyInfo.parseConsoleKeys("这不是 JSON".data(using: .utf8)!, now: fixedNow()) == nil,
                 "非 JSON → nil（调用方沿用缓存）")
    keyListCheck(ApiKeyInfo.parseConsoleKeys("{\"foo\":1}".data(using: .utf8)!, now: fixedNow()) == nil,
                 "没有 items → nil")
    let empty = ApiKeyInfo.parseConsoleKeys("{\"items\":[]}".data(using: .utf8)!, now: fixedNow())
    keyListCheck(empty?.keys.isEmpty == true && empty?.skipped == 0, "items 为空数组 → 0 把、不崩")
    let notAnArray = ApiKeyInfo.parseConsoleKeys("{\"items\":[{\"keys\":\"nope\"}]}".data(using: .utf8)!,
                                                 now: fixedNow())
    keyListCheck(notAnArray?.keys.isEmpty == true, "keys 不是数组 → 0 把、不崩")
    // item 里有 null：数组整体转不成字典数组 → nil（退回缓存，比当成"0 把"更安全）
    let withNull = ApiKeyInfo.parseConsoleKeys("{\"items\":[{\"keys\":[]},null]}".data(using: .utf8)!,
                                               now: fixedNow())
    keyListCheck(withNull?.keys.isEmpty ?? true, "item 里混了 null → 返回空或 nil（都能退回缓存）")
    let noID = ApiKeyInfo.parseConsoleKeys("{\"items\":[{\"keys\":[{\"name\":\"没有 id\",\"status\":\"active\"}]}]}".data(using: .utf8)!,
                                           now: fixedNow())
    keyListCheck(noID?.keys.isEmpty == true, "缺少 id 的条目直接跳过")
}

// swiftc 多文件编译时只有 main.swift 允许顶层语句，所以这里用 @main 包一层
@main
struct KeyListParseTestRunner {
    static func main() {
        testConsoleKeyListBasics()
        testConsoleKeyListEdgeCases()
        testConsoleKeyListMalformed()
        print("")
        if keyListFailures.isEmpty {
            print("✅ 密钥列表解析全部通过")
        } else {
            print("❌ 失败 \(keyListFailures.count) 项：")
            for f in keyListFailures { print("   - \(f)") }
            exit(1)
        }
    }
}
