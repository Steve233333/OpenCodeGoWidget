import Foundation

// 编译运行：scripts/test-quota-parse.sh
//          scripts/test-quota-parse.sh --live

private func grouped(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = ","
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

private func paidRow(
    _ slug: String,
    _ name: String,
    goRequests: Int,
    plusRequests: Int,
    goUSD: Int,
    plusUSD: Int,
    note: String? = nil
) -> String {
    let noteHTML = note.map { #"<span data-layer="model-note">\#($0)</span>"# } ?? ""
    return """
    <tr data-model="\(slug)">
      <th><span data-layer="model-name" title="\(name)">\(name)</span>\(noteHTML)</th>
      <td data-allowance-type="requests">
        <span data-plan="go"><span data-layer="current-value">\(grouped(goRequests))</span></span>
        <span data-plan="go-plus"><span data-layer="current-value">\(grouped(plusRequests))</span></span>
      </td>
      <td data-allowance-type="usage">
        <span data-plan="go"><span data-layer="current-value">$\(grouped(goUSD))</span></span>
        <span data-plan="go-plus"><span data-layer="current-value">$\(grouped(plusUSD))</span></span>
      </td>
    </tr>
    """
}

let consoleFixtureHTML = """
<table>
\(paidRow("kimi-k3", "Kimi K3", goRequests: 98, plusRequests: 392, goUSD: 15, plusUSD: 60))
\(paidRow("qwen3.8-max", "Qwen3.8 Max", goRequests: 162, plusRequests: 647, goUSD: 15, plusUSD: 60))
\(paidRow("glm-5.2", "GLM-5.2", goRequests: 792, plusRequests: 2_370, goUSD: 60, plusUSD: 180))
\(paidRow("hy4-preview", "Hy4 preview", goRequests: 1_350, plusRequests: 5_410, goUSD: 30, plusUSD: 120))
\(paidRow("minimax-m3", "MiniMax-M3", goRequests: 3_210, plusRequests: 9_620, goUSD: 60, plusUSD: 180))
\(paidRow("glm-5.3-flash", "GLM-5.3-Flash", goRequests: 6_320, plusRequests: 18_900, goUSD: 60, plusUSD: 180))
\(paidRow("glm-5.3", "GLM-5.3", goRequests: 6_600, plusRequests: 13_200, goUSD: 500, plusUSD: 1_000))
\(paidRow("longcat-2.0", "LongCat-2.0", goRequests: 11_400, plusRequests: 45_700, goUSD: 60, plusUSD: 240))
\(paidRow("deepseek-v4.1-flash", "DeepSeek V4.1 Flash 1017", goRequests: 43_300, plusRequests: 86_700, goUSD: 100, plusUSD: 200))
\(paidRow("muse-spark-1.3-contributor", "Muse Spark 1.3 Contributor", goRequests: 45_300, plusRequests: 90_600, goUSD: 60, plusUSD: 120, note: "Limited regions"))
<tr data-model="hy4-flash-free">
  <th><span data-layer="model-name" title="Hy4 flash Free">Hy4 flash Free</span><span data-layer="model-note">Limited time</span></th>
  <td data-allowance-type="requests">
    <span data-plan="go"><span data-layer="current-value">∞</span></span>
    <span data-plan="go-plus"><span data-layer="current-value">∞</span></span>
  </td>
  <td data-allowance-type="usage">
    <span data-plan="go"><span data-layer="current-value">∞</span></span>
    <span data-plan="go-plus"><span data-layer="current-value">∞</span></span>
  </td>
</tr>
</table>
"""

let tinyHTML = "<table><tr><td>Not a quota</td></tr></table>"
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
    print("— Console 双套餐 fixture —")
    guard let rows = GoQuotaRegistry.parse(html: consoleFixtureHTML) else {
        check(false, "fixture 应解析成功")
        return
    }
    check(rows.count == 11, "行数 = 11（实际 \(rows.count)）")

    guard let glm = rows.first(where: { $0.slug == "glm-5.3" }) else {
        check(false, "GLM-5.3 必须在结果里")
        return
    }
    check(glm.requests5h(for: .go) == 6_600, "GLM-5.3 Go 估算请求 = 6,600")
    check(glm.requests5h(for: .goPlus) == 13_200, "GLM-5.3 Plus 估算请求 = 13,200")
    check(glm.monthlyUSD(for: .go) == 500, "GLM-5.3 Go 月额度 = $500")
    check(glm.monthlyUSD(for: .goPlus) == 1_000, "GLM-5.3 Plus 月额度 = $1,000")

    let flash = rows.first(where: { $0.slug == "glm-5.3-flash" })
    check(flash?.monthlyUSD(for: .go) == 60, "GLM-5.3-Flash 保持自己的 $60，不跟随 GLM-5.3")
    check(flash?.monthlyUSD(for: .goPlus) == 180, "GLM-5.3-Flash Plus = $180")
    check(
        rows.first(where: { $0.slug == "muse-spark-1.3-contributor" })?.badge == "限区",
        "Limited regions 显示为「限区」"
    )

    let free = rows.first(where: { $0.slug == "hy4-flash-free" })
    check(free?.isUnlimited == true, "∞ 行识别为限时免费")
    check(free?.badge == "限免", "Limited time 显示为「限免」")
    check(rows.first?.slug == "kimi-k3", "按 Go 5h 请求数升序")
    check(!rows.contains(where: { $0.displayName.contains("$") }), "美元列不会混进模型名")
}

func testGate() {
    print("— 行数闸门 —")
    check(GoQuotaRegistry.parse(html: tinyHTML) == nil, "非 Console/旧 Docs 表返回 nil")
    check(GoQuotaRegistry.parse(html: "<html></html>") == nil, "空页面返回 nil")
}

func testHelpers() {
    print("— 单元格解析 —")
    let (name, note) = GoQuotaRegistry.splitNameCell(
        "DeepSeek V4.1 Flash<br><small>4x · 9 月 20 日结束</small>"
    )
    check(name == "DeepSeek V4.1 Flash", "splitNameCell 名字")
    check(note == "4x · 9 月 20 日结束", "splitNameCell 备注")
    check(
        GoQuotaRegistry.currentValue("<del>6,500</del><br><strong>26,000</strong>") == "26,000",
        "currentValue 取 <strong>"
    )
    check(GoQuotaRegistry.plainText("<code>@ai-sdk/x</code>") == "@ai-sdk/x", "plainText 剥标签")
    check(GoQuotaRegistry.decodeEntities("a&amp;b&nbsp;c") == "a&b c", "实体解码")
}

func testLive() {
    print("— 真实 Console 冒烟（--live）—")
    let sem = DispatchSemaphore(value: 0)
    var rows: [GoQuota]?
    var req = URLRequest(url: URL(string: "https://opencode.ai/console/go")!)
    req.timeoutInterval = 20
    req.setValue(
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
        forHTTPHeaderField: "User-Agent"
    )
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
    check(rows.count >= 30, "真实页面模型数 ≥ 30（实际 \(rows.count)）")
    check(
        rows.first(where: { $0.slug == "glm-5.3" })?.monthlyUSD(for: .go) == 500,
        "真实页面 GLM-5.3 Go = $500"
    )
    check(
        rows.first(where: { $0.slug == "glm-5.3" })?.monthlyUSD(for: .goPlus) == 1_000,
        "真实页面 GLM-5.3 Plus = $1,000"
    )
}

@main
struct QuotaParseTests {
    static func main() {
        testFixture()
        testGate()
        testHelpers()
        if CommandLine.arguments.contains("--live") {
            testLive()
        }

        print(failures.isEmpty ? "\n全部通过 ✅" : "\n\(failures.count) 项失败 ❌")
        if !failures.isEmpty {
            exit(1)
        }
    }
}
