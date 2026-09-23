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
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.30.dmg">
    <img src="https://img.shields.io/badge/下载-DMG%20安装包-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="DMG">
  </a>
  &nbsp;
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.30.zip">
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

- DMG：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.30.dmg>
- ZIP：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.30.zip>
- 历史版本：<https://github.com/Steve233333/OpenCodeGoWidget/releases>

首次打开如果提示「未验证开发者」，右键应用选「打开」即可。

## 更新日志

> 完整历史（20+ 个版本）见 [CHANGELOG.md](CHANGELOG.md)。这里只列最近三个版本。

### v1.1.11.30 — 让"系统升级/重启后代理掉线"自己好起来

macOS 27 升级后 Codex 报 "Reconnecting… waiting for network" 的根因链已查实：安装器用 `command -v python3` 挑到了 **Xcode 自带的 Python 3.9**（一时起不来）→ 代理 5 分钟没监听 → 之后 Codex 又发了带前缀的 `opencode-go/...`（路由不认 → 401）。

这次补三个结构性缺口：

- **代理生命周期只有一份实现**（新 `vision/ensure-proxy.sh`）：解释器改成**逐个实测**（python.org 3.x → /usr/local → Homebrew → /usr/bin 兜底），挑完写 plist、起服务、**探活验证**，并记状态文件；安装器和 App 都调它。
- **App 自己救回来**（新 `ProxyWatchdog`）：启动后 10 秒 / 每 5 分钟 / 唤醒时探活，端口活着就什么都不做；死了才修。救不回来 → 菜单栏红点 + 面板顶部红字 + 设置里「修复本地代理」按钮（不要通知权限、不加常驻 LaunchAgent）。
- **前缀也能路由**：`opencode-go/<slug>` ≡ `<slug>-go`、`opencode-zen/<slug>` ≡ `<slug>-zen`。

顺带把自检的代理行改成三态（未加载 / 加载了没进程 / 进程在端口不通）+ 显示当前解释器；并修掉全项目 25 处 `$VAR` 紧跟中文标点的 shell 可移植性 bug（bash 在非 UTF-8 locale 下会把它当变量名，`set -u` 直接报 unbound）。

真机实测：bootout 掉代理后 **2.6 秒**自动修好（解释器从 Xcode 3.9 换成 python.org 3.13.1），`opencode-go/deepseek-v4.1-flash` 由 401 变 **200**。

版本 **1.1.11.30 (70)**。

### v1.1.11.29 — 重构第四阶段：安装器拆步骤 + 配置后自检（必跑）

`codex-oneclick-setup.command` 968 行 → 主脚本 200 行 + `setup/steps/*.sh` 13 个步骤（模式选择→Key→签名→依赖→备份→模型表→默认模型→AGENTS/MCP→代理→补丁→汇总→**自检**）。

**新增「配置后自检」（必跑）**：日志里固定记录 ① 运行环境（macOS/架构/python3/HOME）② 三个关键服务（launchd 代理、`config.toml`、ChatGPT-Patched.app）③ 每条失败的下一步。只报告不中止。

**验证**：步骤文件全部 `zsh -n` 通过；主脚本 + 13 步重组后与拆分前**逐行一致**；再从打包好的 App 包里拷出 `codex/`、用假 `HOME` 完整跑了一遍更新模式（`--skip-patch --skip-proxy-start`）。

版本 **1.1.11.29 (69)**。

### v1.1.11.28 — 重构第三阶段：本地代理拆包（纯搬移，行为不变）

`vision_proxy.py` **3793 行 / 107 个顶层符号**的单体脚本 → 薄入口（55 行）+ `proxy/` 包（config / bridges_chat / bridges_messages / toolfix / search_sidecar / muse / apply_patch / sse / server）。

**怎么证明是纯搬移**：107 个顶层符号逐个按源码片段比对，**全部逐字节一致**；入口保留兼容层，所以老的 66 个 Python 用例 + 13 项 Muse 自检照旧通过。`check-drift.sh` 改成整目录递归比对（含 `proxy/` 子目录），`docs/gen-model-matrix.py` 改成从包里抠常量。

顺带修掉一个原有的静默 bug：`_perform_web_search` 的 env 兜底用到 `pathlib` 却从没 import（外面是裸 `except: pass`）→ 补上。真机冒烟：DeepSeek / GLM（走 chat 桥回落）/ Muse 各一条 200，日志零 Traceback。

版本 **1.1.11.28 (68)**。

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
