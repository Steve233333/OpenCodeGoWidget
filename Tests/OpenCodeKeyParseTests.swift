import Foundation

// opencode.ai 密钥页解析的离线回归测试（不联网）。
// 编译运行：scripts/test-key-parse.sh（打包前自动跑）
//
// 起因（2026-09-14）：设置页新增"浏览器登录自动获取"，靠解析密钥页 SSR 里
// {id:"key_...",name:"...",key:"sk-...",...,keyDisplay:"..."} 序列化数据。
// 下面用真实页面片段锁住行为：本人 Key 拿完整值、他人 Key 只有 keyDisplay、
// 重复记录要去重。

/// 抄自 2026-09-14 opencode.ai/workspace/<wrk>/keys 的真实结构（Key 值已替换为假值）
let keyFixtureHTML = """
$R[2]($R[18]={p:0,s:0,f:0});$R[20]($R[14],$R[23]=[$R[24]={id:"key_01M13VPQNY35W08DEVR6ZZN0GT",name:"方泽恩",key:"sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",timeUsed:null,userID:"usr_01KT9VX0KZCYTT6YEX6127AK5S",email:"Steve23333@proton.me",keyDisplay:"sk-AAAAAAA...AAAA"},$R[25]={id:"key_01M0B525E7NNSV1EWC34FHSTYQ",name:"丁雁",key:void 0,timeUsed:null,userID:"usr_01KT9VX0KZCYTT6YEX6127AK5T",email:"other@example.com",keyDisplay:"sk-BBBBBBB...BBBB"}]);$R[20]($R[12],$R[19]);
$R[26]={id:"key_01M13VPQNY35W08DEVR6ZZN0GT",name:"方泽恩",key:"sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",timeUsed:null,userID:"usr_01KT9VX0KZCYTT6YEX6127AK5S",email:"Steve23333@proton.me",keyDisplay:"sk-AAAAAAA...AAAA"}
"""

var keyFailures: [String] = []
func keyCheck(_ cond: Bool, _ name: String) {
    if cond { print("  ✅ \(name)") } else { print("  ❌ \(name)"); keyFailures.append(name) }
}

func testKeyParse() {
    print("— 密钥页解析 —")
    let keys = OpenCodeKeyFetcher.parseKeys(from: keyFixtureHTML)
    keyCheck(keys.count == 2, "重复序列化去重后 2 条（实际 \(keys.count)）")
    keyCheck(keys.first?.id == "key_01M13VPQNY35W08DEVR6ZZN0GT", "第 1 条 id 正确")
    keyCheck(keys.first?.name == "方泽恩", "第 1 条 name 正确")
    keyCheck(keys.first?.secret?.count == 67, "本人 Key 拿到 67 字符完整值")
    keyCheck(keys.first?.secret?.hasPrefix("sk-") == true, "完整值以 sk- 开头")
    keyCheck(keys.first?.display == "sk-AAAAAAA...AAAA", "keyDisplay 解析正确")
    keyCheck(keys.count == 2 && keys[1].secret == nil, "他人 Key（key:void 0）无完整值")
    keyCheck(keys.count == 2 && keys[1].isUsable == false, "他人 Key 标记为不可用")
    keyCheck(OpenCodeKeyFetcher.parseKeys(from: "<html>没有密钥</html>").isEmpty, "无记录返回空数组")
}

func testWorkspaceID() {
    print("— workspace ID 提取 —")
    keyCheck(OpenCodeKeyFetcher.workspaceID(fromURL: "https://opencode.ai/workspace/wrk_01KT9VX0KZCD5SYNXH8D3EYJD8/keys") == "wrk_01KT9VX0KZCD5SYNXH8D3EYJD8", "/workspace/wrk_.../keys 提取")
    keyCheck(OpenCodeKeyFetcher.workspaceID(fromURL: "https://opencode.ai/workspace/wrk_01KT9VX0KZCD5SYNXH8D3EYJD8/usage?tab=1") == "wrk_01KT9VX0KZCD5SYNXH8D3EYJD8", "带查询参数提取")
    keyCheck(OpenCodeKeyFetcher.workspaceID(fromURL: "https://opencode.ai/auth") == nil, "登录页返回 nil")
    keyCheck(OpenCodeKeyFetcher.workspaceID(fromURL: "https://opencode.ai/workspace/not_a_wrk/keys") == nil, "非 wrk_ 前缀返回 nil")
}

func testInactiveServiceAccount() {
    print("— 服务账号过滤 —")
    let obj: [String: Any] = [
        "items": [
            ["id": "svc_old", "status": "disabled", "keys": [
                ["id": "key_old", "name": "旧 Key", "status": "active", "tokenHint": "sk-old…"]
            ]],
            ["id": "svc_new", "status": "active", "keys": [
                ["id": "key_new", "name": "新 Key", "status": "active", "tokenHint": "sk-new…"]
            ]]
        ]
    ]
    let keys = OpenCodeKeyFetcher.parseServiceAccountsJSON(obj)
    keyCheck(keys.count == 1, "停用服务账号下的 active Key 不列入可用（实际 \(keys.count) 条）")
    keyCheck(keys.first?.id == "key_new", "只保留 active 服务账号的 Key")
}

func testCredentialClassification() {
    print("— 登录凭据归类 —")
    let session = OpenCodeKeyFetcher.classifyPastedCredential("st_297524e3-c5d5-4843-8dcc-86b9cac4d9d1")
    keyCheck(session.session == "st_297524e3-c5d5-4843-8dcc-86b9cac4d9d1" && session.auth == nil,
             "st_ 会话归到 consoleSession，不会塞进 authCookie")
    let auth = OpenCodeKeyFetcher.classifyPastedCredential("Fe26.2**abc*def")
    keyCheck(auth.auth == "Fe26.2**abc*def" && auth.session == nil, "Fe26 旧 auth 仍可识别")
    let header = OpenCodeKeyFetcher.classifyPastedCredential(
        "oc_locale=zh; auth=Fe26.2**abc; __Host-console_session=st_123")
    keyCheck(header.auth == "Fe26.2**abc" && header.session == "st_123", "完整 Cookie 头拆分正确")
    let ws = OpenCodeKeyFetcher.classifyPastedCredential(
        "https://opencode.ai/console/wrk_01KT9VX0KZCD5SYNXH8D3EYJD8/usage")
    keyCheck(ws.workspaceID == "wrk_01KT9VX0KZCD5SYNXH8D3EYJD8", "workspace 链接可提取 wrk_")
    keyCheck(OpenCodeKeyFetcher.consoleCookieHeader(auth: "", session: "st_123")
             == "oc_locale=zh; __Host-console_session=st_123", "缺 auth 时不产生 auth= 空值")
}

func testWorkspaceListParse() {
    let data = #"[{"id":"wrk_01KT9VX0KZCD5SYNXH8D3EYJD8","name":"Steve233"},{"id":"bad"}]"#.data(using: .utf8)!
    keyCheck(OpenCodeKeyFetcher.parseWorkspaceIDs(data) == ["wrk_01KT9VX0KZCD5SYNXH8D3EYJD8"],
             "console/api/orgs 只取 wrk_ 工作区")
}

// swiftc 多文件编译时只有 main.swift 允许顶层语句，所以这里用 @main 包一层
@main
struct KeyParseTestRunner {
    static func main() {
        testKeyParse()
        testWorkspaceID()
        testInactiveServiceAccount()
        testCredentialClassification()
        testWorkspaceListParse()

        if keyFailures.isEmpty {
            print("\n全部通过 ✅")
            exit(0)
        } else {
            print("\n失败 \(keyFailures.count) 项 ❌")
            for f in keyFailures { print("  - \(f)") }
            exit(1)
        }
    }
}
