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
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.52.dmg">
    <img src="https://img.shields.io/badge/下载-DMG%20安装包-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="DMG">
  </a>
  &nbsp;
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.52.zip">
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

- DMG：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.52.dmg>
- ZIP：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.52.zip>
- 历史版本：<https://github.com/Steve233333/OpenCodeGoWidget/releases>

首次打开如果提示「未验证开发者」，右键应用选「打开」即可。

## 更新日志

> 完整历史（20+ 个版本）见 [CHANGELOG.md](CHANGELOG.md)。这里只列最近三个版本。

### v1.1.11.50 — 重建小组件不再搞坏 Codex 副本

今天官方升级到 26.930 后副本坏了两处：clang 编译失败却继续签名（主可执行文件根本没生成，而 `codesign`
照样报通过），加上新版 Electron 的框架摘要校验 fail-closed（摘要不同步就 FATAL）。修复当时只在本机脚本里，
仓库那份落后 86 行 —— 安装器按内容覆盖，等于**下次重建就复发**。本版把修复**固化进仓库**，加门禁
`scripts/test-patch-guards.sh`（4 条护栏 + 5 个行为用例）进 `./build.sh --test`；重建收尾顺手维护
`~/.local/bin/codex` 软链；手册补 §33。

版本 **1.1.11.50 (90)**。

### v1.1.11.49 — 「今日」写错一次不再永久锁死

过了 0 点后「今日模型」显示 **$2.29**（其实那是**昨天整天**的 $2.2893），而按 Key 的今天只有 $0.50、
控制台日志今天 0 点至今只有 **$0.51** —— 而且**怎么刷新都不动**：合并规则「只增不减」挡住了"变小"的修正。
现在只在**今天这一格**、且这一轮**整天窗口抓成功**时，用日志整窗重算它（历史天一个字节不动；
窗口失败或空窗口时保持旧值）。真机验证：刷新一次 $2.29 → **$0.51**。

版本 **1.1.11.49 (89)**。

### v1.1.11.48 — 会话被截图撑爆不再卡死（45MB 自动丢老图）

做图像迭代的会话会把截图和 `view_image` 结果的 base64 永久留在上下文里，每轮重发 → 撞上游
**48.4 MiB** 上限 → 413/502 反复，线程自己永远恢复不了（实测卡在 50.7MB、累计 192 次 413）。
现在代理在请求体超 **45MB** 时按时间从旧到新丢（图片优先，**永远保住最新 1 张**，其次大块工具输出），
只改发往上游这一份、不动磁盘会话，并留下一行 `请求体减肥` 日志。
真机 A/B：同一个 64.1MB 请求，旧代码 502（172 秒失败）、新代码 **200**（减到 32.1MB，15 秒）。

版本 **1.1.11.48 (88)**。

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
