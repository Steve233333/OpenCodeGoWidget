# OpenCode Go 套餐小组件

> 把 OpenCode Go 的额度、花费和全模型配额表，钉在 macOS 桌面上的原生小组件。

<p align="center">
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest">
    <img src="https://img.shields.io/github/v/release/Steve233333/OpenCodeGoWidget?label=最新版本&color=0A84FF" alt="release">
  </a>
  <img src="https://img.shields.io/badge/macOS-14.0+-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/SwiftUI-Charts%20%2B%20WidgetKit-0A84FF" alt="SwiftUI Charts WidgetKit">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT">
  <img src="https://img.shields.io/github/downloads/Steve233333/OpenCodeGoWidget/total?label=下载" alt="downloads">
</p>

<p align="center">
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.34.dmg">
    <img src="https://img.shields.io/badge/下载-DMG%20安装包-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="DMG">
  </a>
  &nbsp;
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.34.zip">
    <img src="https://img.shields.io/badge/下载-ZIP%20免安装-34C759?style=for-the-badge&logo=apple&logoColor=white" alt="ZIP">
  </a>
</p>

<p align="center">
  <b>下载 → 拖入「应用程序」→ 浏览器登录自动配好 → 添加小组件</b><br/>
  <sub>Apple Silicon / Intel · 无需 Homebrew · 数据只存本机</sub>
</p>

---

## 为什么值得装

OpenCode Go 的额度分散在官网多个页面：5 小时、周、月要分别看；模型费用要进 Usage 页翻；每个模型的配额倍率更是藏在文档表里。这个工具把它们压进一块桌面小组件和一个固定尺寸的仪表盘里。

- **一眼看全局**：5 小时 / 周 / 月三档额度、剩余重置时间、近 7 天花费，小组件里直接看。
- **费用不再靠猜**：主 App 展示本月按日按模型堆叠柱状图、今日模型占比，数据来自 workspace 真实用量。
- **全模型配额表**：从官方文档同步 Go 模型配额，用 1x / 10x / 25x / 50x / 100x / 250x 相对刻度展示 5h、周、月三段请求量。
- **常驻不折腾**：原生 WidgetKit 小组件，点击图表进主 App，支持开机自启。

## 预览

| 桌面小组件 | 主仪表盘 | 全模型配额图 | 设置与导入 |
|---|---|---|---|
| <img src="docs/images/widget.png?v=20260831" width="300" alt="小组件：额度、近 7 天花费"> | <img src="docs/images/app.png?v=20260831" width="300" alt="主 App：本月花费堆叠图"> | <img src="docs/images/quota.png?v=20260831" width="300" alt="Go 全模型配额图"> | <img src="docs/images/settings.png?v=20260831" width="300" alt="设置：API Key 与 HAR 导入"> |

截图数据示例：本月 `$9.15 USD`、今日 `$0.10 USD`、5 小时 `5%`、周 `8%`、月 `25%`。

## 快速开始

### 安装

**DMG 推荐**：下载后打开，把 `OpenCode 小组件.app` 拖入「应用程序」。

**ZIP 免安装**：解压后直接运行。

### 配置（推荐：浏览器登录自动获取）

1. 打开应用，点右上角齿轮。
2. 点「浏览器登录自动获取」，在弹窗里登录 `opencode.ai`（推荐 GitHub 登录）：
   - 自动保存 workspace 与 Cookie —— 费用柱状图直接有数据，不用再导 HAR；
   - 自动拉取官方密钥页，把完整 Go Key 回填到 Keychain 和两个设置栏，点「使用此 Key」即完成替换。
3. DeepSeek Key（可选）：官方平台只在创建时展示一次，去 DeepSeek 控制台创建后，回到 `Codex 一键配置` 点「剪贴板填入」即可。
4. 桌面右键 → 编辑小组件 → 搜索「OpenCode Go」→ 添加中尺寸。

手动配置仍可用：粘贴 `sk-...`、粘贴 `https://opencode.ai/workspace/wrk_.../usage` 全链接、或在浏览器导出 HAR 后点「选择 HAR 文件」自动提取。所有密钥都可以在设置页里显示明文、替换或单独清除。

API Key 存在 macOS Keychain，workspace 凭据存在 App Group 本地存储，不上传到任何第三方。

## 核心功能

### 桌面小组件

- 5 小时 / 周 / 月额度进度和重置倒计时。
- 近 7 天按日堆叠花费，日期轴清晰。
- 点击图表进入主 App；点击刷新按钮立即更新。

### 主仪表盘

- 本月完整月份的按日按模型堆叠柱状图，空日不塌陷。
- 模型图例统一配色，今日模型占比单独展示。
- 固定 `620×860` 窗口，信息密度高但不乱。

### Go 配额图

- 实时同步 `opencode.ai` 官方 Go 配额文档。
- 同一行内展示 5h、周、月三段请求数，右侧给出具体数值。
- 使用相对倍率刻度，方便比较模型配额量级；限时免费模型单独标注。

### 设置与安全

- API Key 存 Keychain；workspace 凭据存 App Group。
- **密钥可管理**：显示明文、输入新值替换、单独清除（额度 Key、workspace 凭据、Codex Go/DeepSeek Key 均有独立清除入口，清除前弹确认）。
- **内嵌浏览器登录**：登录 `opencode.ai` 后自动获取 Go Key、workspace 与 Cookie，不用手填；登录凭据只存本机，可一键清除。
- HAR 导入自动解析裸 workspace ID 和认证 Cookie，不需要手动复制。
- 开机自启可开关，也可在系统设置的登录项里管理。

## 下载直链

- DMG：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.34.dmg>
- ZIP：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.34.zip>
- 历史版本：<https://github.com/Steve233333/OpenCodeGoWidget/releases>

首次打开如果提示「未验证开发者」，右键应用选「打开」即可。

## 更新日志

> 完整历史（20+ 个版本）见 [CHANGELOG.md](CHANGELOG.md)。这里只列最近三个版本。

### v1.1.11.34 — 正文"闪一下全出来" → 按正常逐字滴出去

**原因**：上游（尤其 Go 网关给 muse）是在末尾把几百个小 delta **一次性涌过来**的（直连实测：
56.2 秒那一刻 397 帧一起到）——不是我们丢帧，是真的没有"字"可以一个个发。

**做法（漏桶 / TextDeltaPacer）**：转发时按固定速率把正文滴出去，看起来就是正常逐字：

- 上游本来就均匀的流（deepseek 那种每帧几字）→ 桶是空的，**零延迟、零改动**；
- 上游猛推 → 按 300 字/秒滴，片长 ~40ms；积压超过 4 秒的量就**自动加速**（上限 1500 字/秒），
  这样长答案不会滴太久、也不会在结尾"啪一下补完"；
- **只碰 `response.output_text.delta`**：工具调用参数帧（`function_call_arguments.delta`，apply_patch 靠它）
  和其它帧一律零延迟原样转发 —— 这条我专门写了断言，免得把工具调用也拖慢。

真机实测：同一条 muse 回答（137 字）以前同一毫秒全出来，现在分成 16 帧、0.6 秒内逐步显示。

版本 **1.1.11.34 (74)**。

### v1.1.11.33 — Muse「没有流式文字」：一半是网关、一半是我们的守卫

**先说结论：这次不是终止修复的锅，主要也不是我们能控制的。** 直连网关（完全绕开我们）实测同一请求：

```
1.7s   response.created / in_progress / output_item.added（一个 reasoning 项）
       …… 中间 50 秒一声不响 ……
56.2s  output_item.done + 正文 delta 开始
89.2s  response.incomplete
```

**OpenCode Go 网关对 muse 就是"先静默憋着、最后一次性吐"**：它在 1.7 秒只发了个"开始思考"的帧，
真正的推理与正文要等模型整轮想完才 flush 出来。所以客户端在那 50 秒里只能是"正在思考"。

我们能控制的两块，这次都修了：

**① 我们的空转守卫以前会把整段读完才转发（放大了这个问题）。**
`_guard_muse_stall` 原本 `response.read()` 读完整个流再判断 —— muse 于是**永远**不是逐字流式，
长回合里客户端要等整段结束才看到东西。现在改成**有限扣留**：出现工具调用 / 正文超过 300 字 /
扣满 32 KB / 扣满 8 秒 → 立刻放行（已读部分先给客户端，剩下的边流边转）；只有"短叙述 + 没工具调用
+ 流已结束"那种经典空转才重发（上限仍 2 次，熔断不变）。重发拿到的新响应走同一个守卫（递归、次数递减），
所以重发之后也是流式的。
**踩到的坑**：第一版放行点仍然是 39.8 秒 —— 因为用了 `read(65536)`，它会**阻塞到凑满 64 KB**；
换成 `read1`（有数据就返回）后扣留窗口才真正生效。

**② Muse 的推理也吃 `max_output_tokens` —— 预算小就会"只思考不出字"。**
实测：80 预算那一轮 `output_tokens=80` 里 `reasoning_tokens=77`，于是**一个字没吐**、
直接 `response.incomplete` + `incomplete_details.reason=max_output_tokens`（截图里你用的正是「极高」档）。
新增下限 `MUSE_MIN_MAX_OUTPUT_TOKENS = 16384`：**只在客户端显式给了、且小于下限时抬高**，
没给就照上游默认（不擅自设上限）；日志会记 `muse max_output_tokens 80 → 16384`。

验证：同一个"80 预算"请求 —— 修前 `response.incomplete` + 正文 0 字；修后 18.3 秒、正文 45 字、
末帧 `response.completed`。新增单测（守卫放行/仍会重发/重发次数上限/预算下限），
Python 全量 **45 + 8 + 31 + 14 + 8** 全绿。

版本 **1.1.11.33 (73)**。

### v1.1.11.32 — 抄 opencodex 的作业：MiMo 原生 XML 工具调用 + 失败退避

两件事，都有实测依据（不是"看别人有我们也加"）：

**① MiMo 会把工具调用写成 XML 混在正文里 —— 我们真漏过。**
扫本机 Codex 会话记录（`~/.codex-deepseek/sessions`，近两周 43 个会话）发现 **3 个文件**命中
`<tool_call>`，其中 `rollout-2026-09-22T14-55-43` 里有一条 **`role=assistant` 的正文消息**，
内容就是：

```
<tool_call><function=write_stdin><parameter=session_id>77397</parameter>
<parameter=chars>x</parameter></tool_call>
```

那次的模型列表里就有 `mimo-v2.6-flash-go` —— 也就是 opencodex `#5499/#5611/#5637` 描述的同一现象：
**MiMo 用自己的语法发工具调用，网关没转成 function_call，就当正文吐出来了**（用户看到"正文里冒出怪语法"，
而那次工具其实没执行）。

按 opencodex 的思路、用我们自己的增量管线实现：
- `proxy/toolfix.py`：容错解析器 `parse_mimo_tool_markup()` —— 认 `<tool_call><function=NAME>…</tool_call>`、
  容忍网关**不补 `</function>`**、孤立 `</parameter>`；解析不出来就把原文当普通文本（宁可漏一次修补，
  也不能吃掉正文）。还提供流式用的 `find_mimo_block()` / `mimo_markup_hold_len()`。
- **参数类型按请求里的 tool schema 转**（新增 `_tool_param_types()`）：`session_id` 变整数、`chars` 保持字符串 ——
  不然发出去的 function_call 参数类型不对，Codex 会直接报参数不合法。拿不到 schema 就不猜，一律当字符串。
- `proxy/bridges_chat.py`：流式桥 `ChatBridgeTranslator` 里做"扣留 + 切块"——开标签出现就扣住尾巴等闭合，
  收齐了转成 `function_call`（added/delta/done 三帧齐发），不是 markup 就照旧当正文吐出去；
  扣超过 8 KB 或收尾还没闭合 → 当正文放出去（模型真在说字面量时不吃字）。非流式两条路径同样处理。

**② 原生 `/responses` 坏了别再每 5 分钟白试一次。**
本机日志：mimo 系列 **682 次走 chat 桥成功**、只有 9~16 次是"先发原生再失败" —— 说明缓存机制本身有效，
但 TTL 固定 5 分钟，等于每 5 分钟仍会白试一次（失败那一次可能死在流中间 = "话说一半失踪"）。
改成**连续失败指数退避**：5min → 15min → 45min → 2h（上限），原生成功一次立刻清零。

验证：
- 新增 7 条单测（解析/容错/流式转换/字面量不吃字/非流式/退避曲线），Python 全量 **44 + 4 + 31 + 14 + 8** 全绿；
- 真机：让 MiMo 用 `write_stdin` 发一次调用 → 拿到 `function_call write_stdin`
  参数 `{"session_id": 77397, "chars": "x"}`（类型正确），输出里 0 处 markup；日志同时出现新的退避行
  `原生 /responses 连续失败 1 次 → 接下来 300s 直接走 chat 桥`。

（opencodex 的另外半招——"把 grace 做成 per-model 配置"——这次没抄：我们现在的规则是
"内容不完整就继续等、最多 120 秒"，本来就不会因为某个模型思考慢而误判，per-model 配置暂时没有收益。）

版本 **1.1.11.32 (72)**。

## 本地构建

```bash
git clone https://github.com/Steve233333/OpenCodeGoWidget.git
cd OpenCodeGoWidget
./build.sh --test   # 只跑测试门槛（约 1 分钟）：配额/密钥解析 + 用量管线 + 代理全量测试
./build.sh          # 测试门槛 + 打包安装（版本号取自 ./VERSION）
```

版本号只有一个真源：改 `./VERSION`（例如 `1.1.11.25`）即可，`CFBundleVersion` 由它推导；以前每次发版要手改 build.sh 里 4 处，已经收敛。

构建产物输出到：

```text
/Applications/OpenCode 小组件.app
dist/OpenCode 小组件-<版本>.dmg
dist/OpenCode 小组件-<版本>.zip
dist/OpenCode 小组件.app
dist/release/OpenCodeGoWidget-<版本>.dmg   # 发版用（ASCII 名）
```

依赖只需要 Xcode Command Line Tools 和 macOS 14+ SDK。脚本会优先寻找本机可用签名身份，找不到时使用 ad-hoc 签名；构建前会跑 drift 检查（仓库 vs 本机代理文件一致）和上面那套测试门槛。

## 常见问题

**小组件搜不到？**  
确认系统设置里小组件已启用；运行 `killall WidgetKit` 后重新添加。

**费用图一直是空？**  
说明 workspace 数据没配置成功。点「浏览器登录自动获取」登录一次即可；也可以回到设置重新粘贴 workspace 全链接，或重新选择 HAR 文件保存。

**怎么替换或删除已经保存的 Key？**  
设置页每个密钥位都有独立入口：填新值保存 = 替换；红色「清除」按钮 = 删除（有确认弹窗）。也可以点「浏览器登录自动获取」重新拉取官网密钥。

**API Key 会泄露吗？**  
不会上传到第三方。Key 只存在本机 Keychain，网络请求只发往 `opencode.ai`。

**怎么关闭开机启动？**  
应用设置里关闭「开机自动启动」，或在系统设置 → 通用 → 登录项里移除。

**为什么应用叫「OpenCode 小组件」，界面里又叫「OpenCode Go」？**  
应用包名用于桌面识别，界面和小组件标题保留产品功能名「OpenCode Go」。

## 隐私

- 本地存储：Keychain、App Group `2DC432GLL2.com.steve233.opencodego`。
- 网络请求：仅访问 `opencode.ai` 的 usage、models、docs 相关接口。
- 无遥测、无广告、无第三方统计。

## 许可

MIT License。这是社区项目，与 OpenCode 官方无关。

---

<p align="center"><sub>SwiftUI · Charts · WidgetKit · macOS 14+</sub></p>
