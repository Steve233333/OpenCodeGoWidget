import Foundation

// 配额表解析的离线回归测试（不联网）。
// 编译运行：scripts/test-quota-parse.sh        （打包前自动跑）
//          scripts/test-quota-parse.sh --live  （额外抓一次真实页面做冒烟检查）
//
// 起因（2026-09-14）：官方给 DeepSeek V4.1 Flash 那行加了促销装饰，老解析要求单元格纯文本，
// 整行匹配失败 → widget 列表里少了这一行。下面用官方真实片段锁住行为。

/// 抄自 2026-09-14 opencode.ai/docs/zh-cn/go/ 的真实片段
let fixtureHTML = """
<table>
<tr><td>模型</td><td>每5小时</td><td>每周</td><td>每月</td></tr>
<tr><td>Kimi K3</td><td>110</td><td>250</td><td>490</td></tr>
<tr><td>Qwen3.8 Max</td><td>160</td><td>400</td><td>810</td></tr>
<tr><td>Grok 4.6</td><td>169</td><td>423</td><td>845</td></tr>
<tr><td>GLM-5.3</td><td>220</td><td>540</td><td>1,080</td></tr>
<tr><td>DeepSeek V4 Pro</td><td>1,050</td><td>2,600</td><td>5,200</td></tr>
<tr><td>DeepSeek V4.1 Flash<br><small>4x · 9 月 20 日结束</small></td><td><del>6,500</del><br><strong>26,000</strong></td><td><del>16,250</del><br><strong>65,000</strong></td><td><del>32,500</del><br><strong>130,000</strong></td></tr>
<tr><td>DeepSeek V4 Flash</td><td>13,000</td><td>32,500</td><td>65,000</td></tr>
<tr><td>DeepSeek V4 Flash Vision Exp</td><td>6,500</td><td>16,250</td><td>32,500</td></tr>
<tr><td>Hy4 preview</td><td>1,350</td><td>3,380</td><td>6,770</td></tr>
<tr><td>Hy3</td><td>4,300</td><td>10,750</td><td>21,500</td></tr>
<tr><td>LongCat-2.0</td><td>11,400</td><td>28,600</td><td>57,200</td></tr>
<tr><td>MiMo-V2.5</td><td>30,100</td><td>75,200</td><td>150,400</td></tr>
<tr><td>Short Model</td><td>2,000</td><td>5,000</td><td>10,000</td></tr>
<tr><td>Free Model</td><td>-</td><td>-</td><td>-</td></tr>
<!-- 2026-09-17 Union Alpha Free：官方给限时免费行写「无限制」，白名单漏了它 -> 整行消失 -->
<tr><td>Union Alpha Free</td><td>无限制</td><td>无限制</td><td>无限制</td></tr>
<!-- 价格表行：带 $ 必须被排除 -->
<tr><td>GLM-5.3 (Peak)</td><td>$0.30</td><td>$1.20</td><td>$0.006</td></tr>
<!-- 模型清单表行：模型 / id / Base URL / SDK，必须被排除 -->
<tr><td>DeepSeek V4.1 Flash</td><td>deepseek-v4.1-flash</td><td><code dir="auto">https://opencode.ai/zen/go/v1/chat/completions</code></td><td><code dir="auto">@ai-sdk/openai-compatible</code></td></tr>
</table>
"""

/// 只有 3 行的小表：解析器应返回 nil（继续用缓存，不许用残缺列表覆盖）
let tinyHTML = """
<table>
<tr><td>模型</td><td>每5小时</td><td>每周</td><td>每月</td></tr>
<tr><td>Kimi K3</td><td>110</td><td>250</td><td>490</td></tr>
<tr><td>Grok 4.6</td><td>169</td><td>423</td><td>845</td></tr>
</table>
"""

var failures: [String] = []

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("  PASS \(label)")
    } else {
        print("  FAIL \(label)")
        failures.append(label)
    }
}

func testFixture() {
    print("— fixture 解析 —")
    guard let rows = GoQuotaRegistry.parse(html: fixtureHTML) else {
        check(false, "fixture 应解析成功")
        return
    }
    check(rows.count == 15, "行数 = 15（实际 \(rows.count)）")

    guard let v41 = rows.first(where: { $0.slug == "deepseek-v4.1-flash" }) else {
        check(false, "V4.1 Flash 必须在结果里")
        return
    }
    check(v41.displayName == "DeepSeek V4.1 Flash", "名字剥掉促销备注：\(v41.displayName)")
    check(v41.h5 == 26000, "h5 取 <strong> 当前值 26,000（实际 \(v41.h5.map(String.init) ?? "nil")）")
    check(v41.weekly == 65000, "weekly = 65,000")
    check(v41.monthly == 130000, "monthly = 130,000")
    check(v41.note == "4x · 9 月 20 日结束", "备注解析：\(v41.note ?? "nil")")
    check(v41.badge == "4x", "行内标签 = 4x（实际 \(v41.badge ?? "nil")）")

    check(rows.contains(where: { $0.slug == "deepseek-v4-flash" && $0.h5 == 13000 }), "普通行照旧解析")
    check(!rows.contains(where: { $0.displayName.contains("$") }), "价格表行被排除")
    check(!rows.contains(where: { $0.slug.contains("chat/completions") }), "模型清单表行被排除")
    check(rows.first(where: { $0.slug == "free-model" })?.h5 == nil, "免费行保留且配额为空")
    check(rows.contains(where: { $0.slug == "union-alpha" }), "「无限制」行必须保留（Union Alpha Free）")
    check(rows.first(where: { $0.slug == "union-alpha" })?.monthly == nil, "无限制行配额为空 -> 界面画金条")
    check(rows.first?.h5 == 110, "按 h5 升序排列")
}

func testGate() {
    print("— 行数闸门 —")
    check(GoQuotaRegistry.parse(html: tinyHTML) == nil, "不足 10 行返回 nil（不许覆盖缓存）")
    check(GoQuotaRegistry.parse(html: "<html></html>") == nil, "空页面返回 nil")
}

func testHelpers() {
    print("— 单元格解析 —")
    let (name, note) = GoQuotaRegistry.splitNameCell("DeepSeek V4.1 Flash<br><small>4x · 9 月 20 日结束</small>")
    check(name == "DeepSeek V4.1 Flash", "splitNameCell 名字")
    check(note == "4x · 9 月 20 日结束", "splitNameCell 备注")
    check(GoQuotaRegistry.currentValue("<del>6,500</del><br><strong>26,000</strong>") == "26,000", "currentValue 取 <strong>")
    check(GoQuotaRegistry.currentValue("13,000") == "13,000", "currentValue 普通文本")
    check(GoQuotaRegistry.plainText("<code dir=\"auto\">@ai-sdk/x</code>") == "@ai-sdk/x", "plainText 剥标签")
    check(GoQuotaRegistry.decodeEntities("a&amp;b&nbsp;c") == "a&b c", "实体解码")
    let noBadge = GoQuota(slug: "x", displayName: "X", h5: 1, weekly: 2, monthly: 3)
    check(noBadge.badge == nil, "没有备注时 badge 为 nil")
}

func testLive() {
    print("— 真实页面冒烟（--live）—")
    let sem = DispatchSemaphore(value: 0)
    var rows: [GoQuota]?
    var req = URLRequest(url: URL(string: "https://opencode.ai/docs/zh-cn/go/")!)
    req.timeoutInterval = 20
    req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        guard let data, let html = String(data: data, encoding: .utf8) else { return }
        rows = GoQuotaRegistry.parse(html: html)
    }.resume()
    _ = sem.wait(timeout: .now() + 25)

    guard let rows else {
        check(false, "抓取或解析失败（网络问题不算解析 bug）")
        return
    }
    check(rows.count >= 25, "真实页面行数 ≥ 25（实际 \(rows.count)）")
    check(rows.contains(where: { $0.slug == "deepseek-v4.1-flash" && ($0.h5 ?? 0) > 0 }),
          "真实页面含 deepseek-v4.1-flash 且有配额值")
    check(rows.contains(where: { $0.slug == "union-alpha" }),
          "真实页面含 union-alpha（限时免费行，slug 不能猜成 union-alpha-free）")
}

// swiftc 多文件编译时只有 main.swift 允许顶层语句，所以这里用 @main 包一层
@main
struct QuotaParseTestRunner {
    static func main() {
        testFixture()
        testGate()
        testHelpers()
        if CommandLine.arguments.contains("--live") {
            testLive()
        }

        if failures.isEmpty {
            print("\n全部通过 ✅")
            exit(0)
        } else {
            print("\n失败 \(failures.count) 项 ❌")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
    }
}
