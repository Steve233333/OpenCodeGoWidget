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
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.5.dmg">
    <img src="https://img.shields.io/badge/下载-DMG%20安装包-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="DMG">
  </a>
  &nbsp;
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.5.zip">
    <img src="https://img.shields.io/badge/下载-ZIP%20免安装-34C759?style=for-the-badge&logo=apple&logoColor=white" alt="ZIP">
  </a>
</p>

<p align="center">
  <b>下载 → 拖入「应用程序」→ 配 API Key → 添加小组件</b><br/>
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

### 配置

1. 打开应用，点右上角齿轮。
2. 粘贴 OpenCode Go API Key（`opencode.ai → Settings → API Keys` 里的 `sk-...`）。
3. 想看真实费用图，就再导入一次 workspace：
   - 粘贴 `https://opencode.ai/workspace/wrk_.../usage` 全链接；或
   - 在浏览器导出 HAR 后点「选择 HAR 文件」，应用会自动提取 workspace ID 和认证 Cookie。
4. 桌面右键 → 编辑小组件 → 搜索「OpenCode Go」→ 添加中尺寸。

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
- HAR 导入自动解析裸 workspace ID 和认证 Cookie，不需要手动复制。
- 开机自启可开关，也可在系统设置的登录项里管理。

## 下载直链

- DMG：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.5.dmg>
- ZIP：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.5.zip>
- 历史版本：<https://github.com/Steve233333/OpenCodeGoWidget/releases>

首次打开如果提示「未验证开发者」，右键应用选「打开」即可。

## 更新日志

### v1.1.8.6 — 元数据接 models.dev + Omen Alpha 接入（2026-09-05）

- **模型元数据源升级**：`model_discovery.py` 接入 `models.dev`（OpenCode 官方同源），优先级链为本地手工 registry > models.dev > opencodex 上游。一次回填修正 20 个模型的上下文/档位偏差（如 luna 372K→1.05M、kimi-k2.x 1M→262K、grok-4.6 1M→500K），新增模型元数据从此与 OpenCode 客户端同源，不再靠模板抄错。
- **Omen Alpha (Go) 接入**：网关 `/responses` 适配层对其全坏（裸 500/带工具 400），代理新增 `RESPONSES_ALWAYS_BRIDGE` 无条件走 chat 桥（官方原生端点即 chat）；原生视觉直通（`NATIVE_VISION_MODELS`）、deepseek 边车代搜修复（直连用裸模型 ID 修 401 + 超时 15s→60s）、`_SEARCH_FALSE_MODELS` 保护。
- **sync 脚本两处修复**：占位符替换硬编码旧路径；config.toml 模板不再整体抄 home（防真 key/本机路径进公开模板）。
- 版本 **1.1.8.6 (16)**。

### v1.1.8.5 — 副本重建保险（2026-09-04）

- 重建前先改名备份旧副本，5 个失败出口统一恢复备份+明确报错，最差也是旧副本还能用。
- 成功路径加验签确认，通过才删备份；`--uninstall` 顺手清掉残留备份。
- 配置页顶部加只读行"官方版 xx / 副本版 yy（已一致/有新版可升）"。
- 版本 **1.1.8.5 (15)**。

### v1.1.8.4 — 副本冻结版（2026-09-04）

- 副本不再跟随官方自动更新：停掉每小时 `--auto-update` 定时任务，冻在可用版本，官方升它的、副本不动。
- 小组件"配置"按钮改为只清理残留定时任务、不再装回自动更新；手动升级唯一入口为配置按钮。
- 版本 **1.1.8.4 (14)**。

### v1.1.8.3 — 修复 26.901 副本打不开（2026-09-03）

- 根因：26.901 官方包启用 Electron per-file asar 完整性校验；旧补丁只改字节不更新 header 里的 `integrity` 哈希，副本启动即 `ASAR Integrity Violation` 静默退出，点图标无反应。
- `patch.sh` 重建时改为同长原地刷新：picker 单行改空格填充（不再需要 npx 解包）、重算全部 8525 个文件的 integrity 哈希、sha256(新 header) 写回 `ElectronAsarIntegrity`；自审三道校验全过后再签名。
- 小组件"配置"按钮覆盖安装的也是新版 `patch.sh`，更新官方版后重新配置不再打坏副本；版本 **1.1.8.3 (13)**。

### v1.1.8.2 — 修复图例滚动留白（2026-09-03）

- 主 App 图例 `LazyVGrid` 换 `VGrid` 一次全画：修窗口从底部滚动位置恢复时只画出前几格、上下拉一下才补全的问题；Widget 扩展不受影响。
- 版本 **1.1.8.2 (12)**。

### v1.1.8.1 — 同步 Muse Spark 1.3（2026-09-03）

- 三处回退表补上 `muse-spark-1.3-contributor`：配额与 1.2 同值（45,300 / 113,300 / 226,600），图例给略深一档的绿与 1.2 区分。
- `Resources/codex` 副本同步电脑最新配置（vision_proxy 1.3 原生搜索等），models.json 模板 33→34 项。
- 版本 **1.1.8.1 (11)**。

### v1.1.8 — 非联网模型只走 deepseek 代搜（2026-09-02）

- 按你说的改成 `非联网的只走 deepseek`：`vision_proxy` 的 `Google/DuckDuckGo 直连` 那段删了，只留 `deepseek-v4-flash-go` 代搜；`websearch-server` 的 `回退 Exa/Parallel` 也删了，只留 `delegate`，`深圳天气` 试过真能搜到才停。
- 版本 **1.1.8 (10)**。

### v1.1.7 — 双路联网搜索 + 代搜托付（2026-09-02）

- 搜索不卡了：`websearch-server.py` 补上 `双路`（先直连绕开 `Clash/VPN` 的 `127.0.0.1` 代理，不通再走系统代理）+ `托给 deepseek 代搜`（`24 个没原生联网的 mimo/glm/qwen` 先让 `deepseek-v4-flash-go` 带着 `web_search` 去搜，再回退 `Exa/Parallel`），`glm/qwen` 网络一卡也不 `sandbox` 了。
- 补坑：之前漏了 `import pathlib`，代搜时会报 `没找到 pathlib`，已补上；`check-drift` 也会比这个文件，不一样就拦。
- 版本 **1.1.7 (9)**。

### v1.1.6 — 停用大对话自动搬走 + 防漂移（2026-09-02）

- 不再自动搬走大对话：原来超过 8MB 就搬到 `failed_rollouts/` 会导致恢复时报错 `file does not exist`（如 `2026-09-02 17:10` 的 8M 对话），现在直接关掉，更新时还会自动把之前搬走的 10 个对话搬回来。
- 加了个小规矩：电脑上的配置是老大，小组件里的是小弟，打包前会自动比一下，不一样就停住不让打包，避免以后改了电脑忘了改小组件。
- 版本 **1.1.6 (8)**。

### v1.1.5 — 联网修复与设置整合（2026-09-02）

- 不联网模型真实联网：`mimo/glm` 等 `web_search` 由 `deepseek-v4-flash` 边车真搜（直接 DuckDuckGo 3s 优先），不再报 `sandbox 无网络`。
- 上下文/档位自动：`context_window` 与 `supported_reasoning_levels`（含 `ultra`）从 `opencodex` 上游 24h 自动同步，一键更新即生效。
- 设置页整合：`Go 额度` 与 `Codex 一键配置` 合并单页滚动，`Codex` 4 栏 `Go* / DeepSeek / 视觉 / 签名密码*` 单按钮 `配置`，异常 `muse` 的 `budget` 必填死循环已修。
- 设置页底部显示 **版本 1.1.5 (7)**。

### v1.1.4 — 菜单栏常驻与图标修复（2026-09-01）

- 菜单栏常驻：`LSUIElement` + `MenuBarExtra`，关掉主窗口仍 5 分钟后台自刷（跟 DeepSeekMonitor 一致），支持开机自启。
- 菜单栏图标重做为 HIG 模板：`16pt (16px/32px)` 纯黑+透明，`isTemplate=true`，浅/深色自动适配，不再出现巨大白底块。
- 小组件纯展示化：不再直连 `/_server`，只读主 App 的 `widget_snapshot`，避免沙盒 502 用空覆盖。
- 设置页底部显示 **版本 1.1.4 (6)**。

### v1.1.3 — 账期对齐与小组件修复（2026-08-31）

- 主仪表盘图表新增 **账期 / 自然月** 切换，默认 **账期**：按 `monthlyResetsAt` 对齐 Go 月重置日（本期 8/18 13:51 — 9/18 13:51），解决月中开通套餐被自然月切断、后半月柱子缺失的问题；来回横跨两自然月时自动双月合并拉取。
- 账期标题区排版重做：`8月18日-9月17日` 置顶、第二行 `套餐生效 … — …` 与 `$13.33 USD` 同行、第三行自绘分段开关左置与 `所有密钥 ▾` 右置，左侧纵向对齐柱状图 Y 轴。
- 小组件近 7 天修复：/widget 扩展识别为空 `dailyCosts` 时不再覆盖非空快照、额度服务端先按日历回溯统计、空态提示 `请在主 App 配置 workspace`。
- 设置页底部显示 **版本 1.1.4 (6)**。

## 本地构建

```bash
git clone https://github.com/Steve233333/OpenCodeGoWidget.git
cd OpenCodeGoWidget
./build.sh
```

构建产物会输出到：

```text
/Applications/OpenCode 小组件.app
dist/OpenCode 小组件-1.1.8.5.dmg
dist/OpenCode 小组件-1.1.8.5.zip
dist/OpenCode 小组件.app
~/Desktop/OpenCode 小组件-1.1.8.5.dmg  # build.sh 会自动拷一份到桌面
```

依赖只需要 Xcode Command Line Tools 和 macOS 14+ SDK。脚本会优先寻找本机可用签名身份，找不到时使用 ad-hoc 签名。

## 常见问题

**小组件搜不到？**  
确认系统设置里小组件已启用；运行 `killall WidgetKit` 后重新添加。

**费用图一直是空？**  
说明 workspace 数据没配置成功。回到设置重新粘贴 workspace 全链接，或重新选择 HAR 文件保存。

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
