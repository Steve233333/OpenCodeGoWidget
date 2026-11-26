# OpenCode Go 套餐小组件

> 把 OpenCode Go 的额度、花费和全模型配额表，钉在 macOS 桌面和 iPhone 主屏上的原生小组件。

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
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.95.dmg">
    <img src="https://img.shields.io/badge/下载-DMG%20安装包-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="DMG">
  </a>
  &nbsp;
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.95.zip">
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
- **用量刷新有兜底**：官网某个用量接口改参数（比如 2026-10-15 的 `bucket=hour` 必 500）不会让整轮刷新停摆，金额和柱状图照常更新。
- **Key 列表只认当前官网状态**：服务账户换组、Key 被吊销或控制台登录过期时会立即撤下旧 Key；失效登录明确提示重登，不再把“临时”等旧缓存当成可用 Key。
- **模型目录自愈**：官网临时漏列不会立刻让模型消失；连续缺席满 12 小时才移除，目录文件被覆盖为空或损坏时会从 last-known-good 基线恢复。
- **配置不假成功**：安装器先落盘新 Key 再切换代理；旧服务会被精确退场，端口监听者必须确认是 agent-relay；Key 401/403 会让配置返回失败。
- **默认模型统一**：新配置默认使用 DeepSeek V4.1 Flash (Go) + Max，对话、记忆提取与记忆合并保持同一模型。
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

- DMG：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.95.dmg>
- ZIP：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.95.zip>
- 历史版本：<https://github.com/Steve233333/OpenCodeGoWidget/releases>

首次打开如果提示「未验证开发者」，右键应用选「打开」即可。

## iOS 源码版

仓库包含独立 iOS 原生 App + Widget Extension，最低 iOS 18.0。iOS 版只需在 App 内登录 OpenCode 账号，不要求 Go API Key，支持主屏小/中号、锁屏组件、30 天历史、按 Key、按模型与配额表。

个人设备使用 Xcode Personal Team 自动签名，免费账号通常需每 7 天重新构建安装。生成和安装步骤见 [iOS/README.md](iOS/README.md)。

## 更新日志

> 完整历史见 [CHANGELOG.md](CHANGELOG.md)。下面列出较新的版本。

### v1.1.11.95 — 修复 API Key 副本无法分支会话

`execution-config-loading` 时回退到 app-server 默认权限，不再阻断 worktree 会话分支；
补丁会同步重算完整性并重签。

版本 **1.1.11.95 (195)**。

### v1.1.11.94 — 修复旧版 Codex 副本重建

`26.1013` 等旧版没有新版 CUA、browser-complete、离线语言源码时，不再把“无需补丁”
误判成完整性失败；新增补丁代际，同官方版本也会自动重建一次到新脚本。

版本 **1.1.11.94 (194)**。

### v1.1.11.93 — 浏览器完成标记：补齐 Go 直通链路

Go Responses 直通没有 `phase` 时，浏览器完成标记也能正常渲染成卡片。

版本 **1.1.11.93 (193)**。

### v1.1.11.92 — 浏览器完成标记不再原样显示

chat 桥补 `phase:"commentary"`；旧会话重开也会重新渲染完成卡片。

版本 **1.1.11.92 (192)**。

### v1.1.11.89 — 恢复 macOS 配额倍率可读性

配额条改为“最低模型 = 1×”的相对对数刻度，并直接显示 `×N`、5 小时请求和月额度。

版本 **1.1.11.89 (129)**。

### v1.1.11.86 — Go / Go Plus 配额与真实月额度

模型配额改为同步官方 Console：Go / Go Plus 分别显示 5 小时估算请求和真实月额度，
GLM-5.3 当前为 Go `$500`、Plus `$1000`。macOS 与 iOS 同步更新。

版本 **1.1.11.86 (126)**，iOS **1.0.18 (19)**。

### v1.1.11.85 — 修复副本断网启动回退英文

把 Codex 语言包加载器的 `enable_i18n` 默认值从 `false` 改为 `true`，并继续同步
asar 完整性、框架摘要和签名。断网启动也会读取本机 `zh-CN` 语言包。

版本 **1.1.11.85 (125)**。

### v1.1.11.84 — 适配 Hy4 Flash Free

新增 `hy4-flash-free-go`：文本+图片、1,048,576 上下文、`none/high` 两档，
支持工具调用。模型目录模板、代理档位表、桌面白名单和 Widget 兜底列表已同步。

版本 **1.1.11.84 (124)**。

### v1.1.11.83 — 把内置浏览器修复固化进 app.asar

`1.1.11.82` 只修了运行时 `.mcp.json`，新版 Codex 每次启动会重新生成缓存并冲掉
wrapper。本版直接在 `app.asar` 的源配置里接入 OpenAI 签名 Node wrapper，启动后生成的
`cua_repl` 配置不会再次失效。

版本 **1.1.11.83 (123)**。

### v1.1.11.82 — 修复 26.1103 升级后副本内置浏览器失效

新版浏览器 IPC 会校验进程签名祖先。通过 OpenAI 签名的 Node wrapper 隔开自签 Electron
与 `node_repl`，保持原生鉴权开启；安装器和重建流程会自动同步这套 wrapper。

版本 **1.1.11.82 (122)**。

### v1.1.11.81 — 代理交接不再依赖固定备用端口

旧代理占用 19100 时，新代理先要在固定的 19217 自检；该端口若被其他软件占用，
就会保留旧服务并退出。现在会在 `19117–19216` 自动找空闲端口，再安全停旧、切新。

版本 **1.1.11.81 (121)**。



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
