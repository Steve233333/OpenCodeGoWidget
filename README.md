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
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.35.dmg">
    <img src="https://img.shields.io/badge/下载-DMG%20安装包-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="DMG">
  </a>
  &nbsp;
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.35.zip">
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

- DMG：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.35.dmg>
- ZIP：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.35.zip>
- 历史版本：<https://github.com/Steve233333/OpenCodeGoWidget/releases>

首次打开如果提示「未验证开发者」，右键应用选「打开」即可。

## 更新日志

> 完整历史（20+ 个版本）见 [CHANGELOG.md](CHANGELOG.md)。这里只列最近三个版本。

### v1.1.11.35 — 转换层收敛 ①：模型策略只有一处真源

体检发现（不是整面墙歪，但确实又砌了几块）：`handle()` 483 行、同一句"这个模型自带搜索"写了 4 遍
+ 1 处同义判断、路由决策散在 3 份名单 + 2 份缓存里。这一版先收**最该收的那块：模型怪癖**。

- **新增 `proxy/policy.py`**：两层结构 —— `MODEL_FAMILIES`（家族默认）+ `MODEL_OVERRIDES`（单模型覆盖），
  入口 `policy_for(model)`；顺手做名字归一（`-go`/`-zen` 后缀、`opencode-go/` 前缀）。
  字段：`route`（native / native-or-bridge / bridge / messages）、`native_search`、`terminal_grace`、
  `min_output_tokens`、`stall_guard`、`smoothing`。
- **删掉 3 份平行名单 + 2 份学习缓存**：`RESPONSES_FALLBACK_MODELS` / `RESPONSES_ALWAYS_BRIDGE` /
  `MESSAGES_ALWAYS_BRIDGE` / `_RESPONSES_BROKEN_UNTIL` / `_RESPONSES_FAIL_STREAK` 全部移除；
  "学坏了就退避"改由 `policy.NativeProbeCache` 单独拥有（逻辑没变：5/15/45 分钟 → 上限 2 小时，成功清零）。
- **server.py 里 4 处字面重复 + 1 处同义判断全部改成查表**（`has_native_search(model)`）；muse 的预算下限、
  空转守卫开关、终止宽限、正文平滑也都改由策略字段驱动（默认值与今天逐条相同，**行为不变**）。
- **新增策略基线测试** `tests/test_model_policy_golden.py`：把重构前对 36 条模型/写法（32 个真实模型 +
  provider 前缀 + 未知模型）的路由与搜索判定逐条固化 —— 以后谁顺手改行为，这张表立刻变红。
- **新增 `scripts/smoke-conversion.sh`**（真机冒烟：DeepSeek / MiMo / Muse / GLM 各一条流式请求，
  断言 200 + 有正文 + 无 markup 泄漏）与 **`scripts/check-shell-cjk-vars.sh`**（进门槛：
  今天三次踩到 `$VAR` 紧跟中文标点导致 unbound 的坑，写成检查脚本永不复发）。

验证：策略基线 36 条逐条一致；全量测试 **47 + 3 + 8 + 31 + 14 + 8** 全绿；真机冒烟四条全绿
（DeepSeek 46 字 / MiMo 27 字 / Muse 30 字 / GLM 63 字，markup 均 0）。

版本 **1.1.11.35 (75)**。

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
