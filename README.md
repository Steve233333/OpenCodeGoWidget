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
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.24.dmg">
    <img src="https://img.shields.io/badge/下载-DMG%20安装包-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="DMG">
  </a>
  &nbsp;
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.24.zip">
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

- DMG：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.24.dmg>
- ZIP：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.24.zip>
- 历史版本：<https://github.com/Steve233333/OpenCodeGoWidget/releases>

首次打开如果提示「未验证开发者」，右键应用选「打开」即可。

## 更新日志

> 完整历史（20+ 个版本）见 [CHANGELOG.md](CHANGELOG.md)。这里只列最近三个版本。

### v1.1.11.23 — 修「按 Key 的用量对不上总额」

现象：账期里「所有密钥」$6.10，而两个 Key 相加只有 $4.43。控制台核对（同一时间窗）：

| 口径 | 控制台 | 我们（修前） |
|---|---|---|
| 合计 | $6.50 | $6.12 |
| 方泽恩 | **$6.43** | $4.48 |
| 丁雁 | **$0.06** | $0.04 |
| 没有 keyId 的行 | $0（0 条） | — |

按天定位：缺口**全在今天**——当天总额 $2.24，按 Key 只有 $0.66。

根因（11.17 引入的副作用）：改成 `since=` 增量后，每次只拿"最近一段"的行，而**按 Key / 按模型的当日拆分必须用整天的数据**；片段金额比累计值小，被"只增不减"护栏挡掉 → 按 Key 卡在某个小数不再增长（当天总额因为走官方 `cost-by-day` 对账会继续涨，于是两边对不上）。

修复：

1. **今天（UTC 日）每次刷新整段拉一次**，与增量行按 `id` 去重后合并 —— 当日拆分重新变成"整天口径"；
2. **回填的"缺明细"判定加上按 Key 覆盖**：某天"按 Key 合计"不足当天总额 90% 也算缺明细，重抓那天（控制台每一行都带 keyId，正常应≈100%）。

版本 **1.1.11.23 (64)**。

### v1.1.11.22 — 修「小组件和主 App 差一天」+ 自然月多算了一天

改成 UTC 日界（11.16）后，**有两处还在用本地日历取日期、却按 UTC 格式化成 key**，整段窗口就偏了一天：

- **小组件「近 7 天」**：`Calendar(identifier: .gregorian)` 没设时区 → 取的是本地 0 点（= UTC 前一天 16:00），转成 key 后整体前移一天 → 和主 App 对不上（你截图就是这个）。
- **主 App「自然月」窗口** (`ChartWindow`)：同样问题 → 月界取本地 9/1 00:00（= 8/31 16:00Z）→ key 变成 `2026-08-31`，于是**多算了上月最后一天、少算了本月最后一天**。实测「本月花费」显示 **$30.95**，正确口径（UTC 自然月 9/1–9/30）是 **$29.69**（差的就是 8/31 那天的 $1.29）。
- 两处都改成 `BillingCycle.calendar`（UTC），和 `ChartFormatters.day` 口径一致。
- 版本 **1.1.11.22 (63)**。

### v1.1.11.21 — 图例/今日模型改用官方显示名（"GPT 5.6 Luna" 而不是 slug）

- 用户问「GPT 5.6 Luna 前面的 GPT 去哪了」：**Codex 模型选择器里是 `GPT-5.6-Luna (Go)`、Go 配额面板也写 `GPT 5.6 Luna`**，只有费用图的图例和今日模型条显示的是**原始 slug**（小写 `gpt-5.6-luna`），看着就像"GPT 没了"。
- **顺带查清 Codex 模型选择器里那条 `5.6 Luna (Go)`**：`models.json` 里写的是 `GPT-5.6-Luna (Go)`，是**Codex 自己把开头的 `GPT-` 吃掉了**（同批的 DeepSeek/Grok/Hy3 显示名都没被动）。绕开办法：显示名改成**空格写法** `GPT 5.6 Luna (Go)`（与官方文档 "GPT 5.6 Luna" 一致），已写进 `DISPLAY_NAME_OVERRIDES`，下次「配置」即生效。
- 现在图例与今日模型条统一走 `ModelPalette.displayName()`：**优先用 Go 配额表里的官方名字**（GPT 5.6 Luna、Kimi K3、GLM-5.3、MiMo-V2.6-Flash…），拿不到才退回 slug；灰度「其他」保持原样。
- 版本 **1.1.11.21 (62)**。

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
