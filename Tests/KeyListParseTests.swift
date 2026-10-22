import Foundation

// 控制台密钥列表解析的离线回归测试（不联网）。
// 编译运行：scripts/test-key-parse.sh（打包前自动跑）
//
// 起因（2026-09-24）：下拉框"有缓存就永不刷新"、而「清除用量缓存」又没删密钥列表 →
// 控制台里新建的 Key 一直看不见。解析规则抽成 ApiKeyInfo.parseConsoleKeys 后，用真实结构锁住：
// 只留 active 且没过期的、账号名去掉 "Legacy: " 前缀、保持接口顺序、name 为空用 id 兜底。

/// 2026-10-22 控制台真实结构：Legacy 账号 7 把全部吊销；新服务账户 2 把 active。
/// id/名字来自接口，不含任何完整 Key 值。
let consoleKeysFixtureJSON = """
{"items":[{"account":{"id":"svcacct_01KT9VX0KZCD5SYNXH8D3EYJD8_01KT9VX0KZCYTT6YEX6127AK5S",
"name":"Legacy: steve23333@proton.me"},"keys":[
{"id":"key_01M0B525E7NNSV1EWC34FHSTYQ","name":"丁雁_过期了","status":"revoked","createdAt":"2026-08-18T19:20:07.000Z","expiresAt":"2026-10-17T16:42:08.000Z"},
{"id":"key_01M13VPQNY35W08DEVR6ZZN0GT","name":"方泽恩_过期了","status":"revoked","createdAt":"2026-08-28T09:37:36.000Z","expiresAt":"2026-10-17T16:42:08.000Z"},
{"id":"sk_01M37KB2CW9V1G51TG47R1B72A","name":"临时","status":"revoked","createdAt":"2026-09-23T16:59:47.000Z","expiresAt":null},
{"id":"sk_01M37KK5Y36V5TFQBVQYC97MXP","name":"临时","status":"revoked","createdAt":"2026-09-23T17:04:13.000Z","expiresAt":null},
{"id":"sk_0aa2def4-737a-4c26-a3be-4b60cb0102be","name":"方泽恩","status":"revoked","createdAt":"2026-10-18T14:34:15.000Z","expiresAt":null},
{"id":"sk_d2abf559-8cad-4c3b-a5d8-ce7768434ff9","name":"丁雁","status":"revoked","createdAt":"2026-10-18T14:34:54.000Z","expiresAt":null},
{"id":"sk_9147b799-40aa-4b3f-8e04-31dd48ddcbd6","name":"丁雁","status":"revoked","createdAt":"2026-10-19T11:33:00.000Z","expiresAt":null}
]},
{"account":{"id":"svcacct_dc58b0de-f168-4ed4-9c1b-b46d5ba55d6d","name":"方泽恩"},"keys":[
{"id":"sk_f7379ae5-ca0c-4a5f-a44c-a711854d7983","name":"方泽恩","status":"active","createdAt":"2026-10-22T03:53:06.000Z","expiresAt":null},
{"id":"sk_0d92ba10-7957-47aa-8043-5cd188db052b","name":"丁雁","status":"active","createdAt":"2026-10-22T03:53:30.000Z","expiresAt":null}
]}]}
"""

var keyListFailures: [String] = []
func keyListCheck(_ cond: Bool, _ name: String) {
    if cond { print("  ✅ \(name)") } else { print("  ❌ \(name)"); keyListFailures.append(name) }
}

/// 固定"现在"，让过期判定可重复（真实 fixture 里的过期时间是写死的）
func fixedNow() -> Date {
    ApiKeyInfo.parseISO8601("2026-10-22T09:00:00.000Z")!
}

func testConsoleKeyListBasics() {
    print("— 控制台密钥列表解析 —")
    let data = consoleKeysFixtureJSON.data(using: .utf8)!
    guard let list = ApiKeyInfo.parseConsoleKeys(data, now: fixedNow()) else {
        keyListCheck(false, "真实样例应能解析（返回 nil 说明结构判定挂了）")
        return
    }
    keyListCheck(list.keys.count == 2, "9 把里只留 2 把有效的（实际 \(list.keys.count)）")
    keyListCheck(list.skipped == 7, "跳过 Legacy 下 7 把已吊销 Key（实际 \(list.skipped)）")
    keyListCheck(list.keys.map(\.id) == [
        "sk_f7379ae5-ca0c-4a5f-a44c-a711854d7983",
        "sk_0d92ba10-7957-47aa-8043-5cd188db052b"
    ], "保持接口顺序，Legacy/临时全部不进列表")
    keyListCheck(list.keys.first?.displayName == "方泽恩 - 方泽恩",
                 "账号名去掉 Legacy: 前缀且显示新服务账户（实际 \(list.keys.first?.displayName ?? "nil")）")
    keyListCheck(list.keys[1].displayName == "方泽恩 - 丁雁", "第二把有效 Key 显示正确")
    keyListCheck(!list.keys.contains { $0.displayName.contains("临时") }, "已吊销的临时不进下拉框")
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
