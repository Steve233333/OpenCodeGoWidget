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
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.9.dmg">
    <img src="https://img.shields.io/badge/下载-DMG%20安装包-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="DMG">
  </a>
  &nbsp;
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.9.zip">
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

- DMG：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.9.dmg>
- ZIP：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.9.zip>
- 历史版本：<https://github.com/Steve233333/OpenCodeGoWidget/releases>

首次打开如果提示「未验证开发者」，右键应用选「打开」即可。

## 更新日志

### v1.1.11.9 — 历史明细「被冲掉能自愈」+ 自然月「刷新」真的会抓数据

- **修「重启之后 9/1–9/18 又全变纯色，点刷新也没用」**：历史明细回填以前是一次性闩锁（`historyBackfillDone` 置位后再也不跑），明细一旦被某次"粗数据"覆盖就永久补不回来。现在改成**按需修复**：快照里还有"只有每天一个总额、没有模型维度"的天，就自动重跑回填；跑完仍补不上的天会记下来，同样的缺口不重复打接口。
- **最后一道护栏**：同一天的新数据只有 `(total)`、旧数据却有逐模型明细时，**保留旧的**。老 `/_server` 回落、HAR 缓存、cost-by-day 兜底这几条路径都不可能再把已经细化过的历史冲成纯色。
- **修「自然月里点刷新没反应」**：自然月视图以前只重读本地缓存、根本不抓数据，现在和账期一样真抓一次，抓失败才退回缓存。
- **回填补齐更耐造**：单页失败会重试 4 次（原来是失败一次就整轮中断，只爬到几小时前就停了）；半轮中断不再写"已尝试"备忘，下次刷新从游标接着爬；长跑期间还会上锁，避免两个爬虫同时改游标互相拖。
- **回填提速（官网改版后最大的性能坑）**：新控制台的 `usage/rows` 是 **100 条/页封顶**、**每请求服务端 4–6 秒**（实测 TTFB），30 天 1.7 万条 = 173 页 → 串行翻要 17–20 分钟。游标其实只是 base64 的 `{"createdAt","id"}`（keyset），于是改成**自己造游标直接跳到缺的那天、按天 4 并发**抓，只抓缺口；24 小时刷新也切成 4 段并行（约 1 分钟 → 约 20 秒）。实测一轮 22 天回填 12,876 行约 9–10 分钟跑完。
- **回填进度条**：图例下方一条橙色细进度条 +「历史明细补齐中 X/Y 天」，回填期间每 5 秒刷新一次；跑完**自动上色**（不用再点一次「刷新」）。
- 版本 **1.1.11.9 (50)**。

### v1.1.11.8 — 修「401 Missing API key」：请求没带凭据也不再裸奔

- **修 Codex 里那条 `401 Unauthorized: Missing API key`（带 cf-ray）**：上游实测能区分两种 401 —— 不带 Authorization 回 `Missing API key.`、key 错了才回 `Invalid API key.`。也就是说那条报错**不是 key 失效**，是请求压根没带凭据（config.toml 少了 `experimental_bearer_token`，或被「清除」删过）。代理现在在 Go/Zen 路由上**自己补 Go Key**：客户端没带 Authorization 也照常发得出去。本机用同一条无凭据请求实测：**修前 401，修后 200**。
- **修「点了配置也不生效」的两个坑**：① 同步代理文件以前只比 mtime，本机那份只要"看着更新"就永远跳过覆盖（日志写"本机更新，无需降级"）—— 改成按内容比对，有差异先备份旧文件再覆盖；② `experimental_bearer_token` 行被红色「清除」删掉后，再点多少次「配置」都补不回来（老脚本只替换已存在的行）—— 现在缺这行会自动补在 `wire_api` 后面。
- **502 不再是一句空话**：代理把 `502 Upstream proxy request failed` 带上真实异常类型与摘要，TLS / DNS / 超时一眼可辨。
- 版本 **1.1.11.8 (48)**。

### v1.1.11.7 — 历史回填进度可见

- 图表图例下方新增一行进度提示：**「历史明细补齐中：X/Y 天已带模型明细（后台拉取，约 2–3 分钟；补完请再点一次「刷新」看到颜色）」**，补完自动消失。
  起因：回填是在刷新成功后才在后台启动、跑完也不会自动重绘界面，用户容易以为"点了刷新没反应"。
- 提醒：回填只在**刷新成功后**触发（点一次「刷新」或等 5 分钟自动那轮），中途退出不影响（游标存本地可续）。
- 版本 **1.1.11.7 (47)**。

### v1.1.11.5 — 历史明细回填 + 已删除的 Key 不再出现 + 账期日期体检

- **修「账期之前的日期全是纯色」**：新接口的 `cost-by-day` 只有每天总额，改版前的历史天没有模型维度。新增 **历史明细回填**：分页拉 30 天 `usage/rows`（约 1.7 万条 = 170 页，页间 0.15s 礼貌间隔），把历史按天按模型补回来；游标存 UserDefaults，可中断可续，**一次刷新在后台跑完**（不阻塞界面）。实测：自然月 19 天里 **17 天恢复成多模型彩色**，剩下 2 天（9/13、9/18）本来就只用了 1 个模型。
- **修「只有所有密钥是纯色、按 Key 却有颜色」**：`cost-by-day` 的兜底数据每轮会**覆盖**回填好的历史明细 → 加了两道保险：① 兜底只填「没有明细的天」，绝不覆盖；② **并集自愈**：只要「各 Key 明细的并集」比当天更细，就用并集。
- **修「只有 2 把 Key 却显示 3 个」**：下拉框以前会把「明细里出现过的 Key」也并进来，于是**已删除的 Key** 以裸 id 出现。现在只列控制台密钥列表里的 Key（已删除 Key 的历史用量仍保留在「所有密钥」里，与控制台的 Legacy 口径一致）。
- **账期日期体检**：环境自检的「大体检②」现在还会用官方 `monthly.resetsAt` 反推账期区间（标题 + 生效/到期时间），拿不到会明说。
- 版本 **1.1.11.5 (45)**。

### v1.1.11.0 — 大体检 + 统一数据源（今日模型不再和图表打架）

- **修「今日模型和实际用量对不上」**：这一块以前单独调老接口（`fetchCostTodayPerKey`），新控制台上线后两套数据源打架 —— 实测同一天同一个 Key：`dailyByKey`（新接口 rows）$1.12 vs 老接口 $0.60。现在**统一从同一份当日数据派生**：今日模型取 `daily` 今天那格、按 Key 取 `dailyByKey` 今天那格；实测四源已完全一致（$1.165）。
- **`availableKeys` 会并上明细里出现过的 Key**，下拉框不再漏。
- **环境自检升级成「大体检」**（设置页 → 环境自检）：
  - 大体检①：快照四源对账（今日 daily / 今日模型 / 按Key明细 / 按Key汇总），不一致直接报偏差
  - 大体检②：直连官方 `/zen/go/v1/usage`，把 rolling/weekly/monthly 三档百分比打出来，与我们界面显示并列对照
  - 大体检③：Go 配额表抓取状态（多少行、多久前抓的）
- 版本 **1.1.11.0 (40)**。

### v1.1.10.9 — 新控制台数据接全：按模型/按 Key 拆分恢复 + 明细增量累积

- **`usage/rows` 明细接入**：新控制台的 `cost-by-day` 只给每天总额（所以图上一天只有一色、`(total)` 还混进了图例）。现在改为翻页拉 `usage/rows?range=24h`（每条带 `costMicroCents` / `model` / `serviceApiKeyId`，pageSize 上限 100），聚合出**按模型**和**按 Key**的当日拆分。
- **历史增量累积**：30 天全量要 169 次请求（每条 100 上限）不现实，所以每次刷新把当日明细并进快照、历史逐日堆起来（老快照里的天原样保留）。副作用：**历史那几天仍是单色**（老接口下架前没抓到按天按模型），从今天起的新数据都会带模型色。
- **`__Host-console_session` 必带**：新控制台用它鉴权，只发 `auth` 一律 401（这就是"费用不刷新"的真因）。
- 版本 **1.1.10.9 (39)**。

### v1.1.10.4 — OpenCode 换新控制台：费用抓取迁到新接口（2026-09-19）

- **背景**：OpenCode 上线新控制台，地址从 `/workspace/...` 变成 **`/console/...`**；老的 `/_server` server-fn 接口直接返回 303 跳登录页 → 我们抓费用的那条路彻底断了，表现就是**费用/图表数字不涨**（一直显示缓存里的旧值）。
- **迁移到新 API**：`GET /console/api/usage/cost-by-day?range=30d`，带上 **`x-org-id: <wrk_...>`** 头（新接口必带，缺了返回 `OrgRequired`）+ 老 cookie。新接口是正规 REST（还有 `usage/models`、`usage/rows`、`usage/export` 等，后续可以做得比老接口更细）。老路径保留为回落，过渡期不会彻底断。
- **登录页也跟着换**：内嵌浏览器的入口从老的 `opencode.ai/auth` 改成 **`opencode.ai/console/login`** —— 不改的话用户在新控制台里登录完，App 也拿不到新会话 cookie。
- **自检跟着更新**：「费用凭据」这项改测新接口，401 会明确说"改版后要用新登录态，重新点浏览器登录自动获取（必要时先清除登录）"；接口通了会把**返回样本前 220 字符**直接显示出来（也存进 `lastConsoleAPISample`），方便我远程看结构。
- **说明**：新接口的返回结构官方没公开，这版用**防御式解析**（在 JSON 里找同时带日期和金额的对象，字段名覆盖 date/day/timestamp × cost/total/amount/spend…），拿到真实样本后再收紧；模型维度的按天拆分暂时可能退化成单色（老接口那套 model 维度要看新 API 给不给）。
- 版本 **1.1.10.4 (34)**。

### v1.1.10.3 — 修「新机器 502」的真凶：Python 缺 CA 证书（2026-09-19）

- **502 的真凶找到了**：新机器上代理日志写着 `RuntimeError: Upstream network error: [SSL: CERTIFICATE_VERIFY_FAILED] ... unable to get local issuer certificate` —— python.org 的 Python 没跑过官方的 `Install Certificates.command` 时**没有 CA 根证书**，所有 HTTPS 直接失败。表现很有迷惑性：同机 Swift 侧（走 macOS 系统信任库）一切正常、Key 检测也通过，只有代理连不上上游 → Codex 只看到 `502 Upstream proxy request failed`。
  三层修复：① `vision_proxy.py` / `model_discovery.py` 启动时若 `SSL_CERT_FILE` 未设且 `/etc/ssl/cert.pem` 存在就指过去（macOS 自带 CA bundle，用户什么都不用做）；② 两个 launchd plist 显式带上 `SSL_CERT_FILE`；③ 安装时若发现 `/Applications/Python 3.*/Install Certificates.command` 就自动跑一次。
- **「环境自检」三项增强**：新增 **Python 证书**检查（专门抓 `CERTIFICATE_VERIFY_FAILED` 并给出修法）、新增 **费用凭据**检查（workspace + authCookie 是否存在，并实测 `_server` 接口 —— cookie 过期就是"费用/额度不刷新"的常见原因，返回登录页会明确指出）；修掉 **双开副本**误报：以前只查 `~/Applications/ChatGPT.app`，装在 `/Applications` 的机器会被误判"找不到官方 app"，现在两处都查。
- **设置页按钮去重**：「Codex 一键配置」里那个重复的「浏览器登录自动获取」去掉（和「Go 额度设置」里的是同一个登录弹窗），统一保留 Go 额度那一栏的。
- 版本 **1.1.10.3 (33)**。

### v1.1.10.2 — 新增「环境自检」：哪一步没配上，点一下就知道（2026-09-19）

- **设置页新增「环境自检」**（在「Codex 一键配置」下面）：11 项逐条给结论，还能「复制报告」直接发人。覆盖：
  - 本地代理：launchd 任务是否加载 + `127.0.0.1:19100` 是否有响应
  - 新模型自动发现：6 小时任务在不在（这正是「有些东西没配上、开机启动项丢了」的那类问题）
  - **Go Key：存在性 + 真实有效性**（发一次 `max_tokens=1` 的最小请求；401=Key 失效、429=限流、5xx=网关抽风不算 Key 的错，且会重试一次再判）
  - **DeepSeek Key：存在性 + 真实有效性**（`/models` 免费接口）
  - Codex 配置、模型目录（数量 + 其中 Go 几个）、双开副本（官方/副本版本对比）、小组件数据通道
  - **代理最近一次报错原文**：直接读 `proxy.err.log` 里最后的 `handler error` / `fallback FAILED` / `not set in env` —— 也就是 Codex 那个 502 的真因
- **探测模型从 `deepseek-v4-flash` 换成 `kimi-k3`**：实测同一时刻 `deepseek-v4-flash` 的 chat 适配层返回 530、`kimi-k3`/`glm-5.3` 正常，用它探活会把「网关抽风」误判成「你的 Key/网络有问题」。
- 版本 **1.1.10.2 (32)**。

### v1.1.10.1 — 新电脑不再需要 Xcode 命令行工具（自带预编译启动器）（2026-09-19）

- **打补丁不再依赖 clang**：补丁流程里唯一需要编译器的地方，是给双开副本编一个 30 行的 C 启动器（注入 `--user-data-dir` 隔离配置目录）。现在把它**预编译成通用二进制**（`resources/patch/launcher-universal`，arm64 + x86_64，源码 `launcher.c` 一并入库）随 App 分发；检测不到可用 clang 时直接用预编译版，实测补丁照常完成。clang 真的不可用、包也丢了时才退到最后兜底（直接放回原二进制，副本仍能跑，只是与官方版共用配置目录，并在日志里明说）。
- **clang 检查也改成"真跑一次"**：和 python3 同一个套路 —— 没装命令行工具时 `/usr/bin/clang` 也是占位程序，`command -v` 会骗过检查，所以现在必须 `clang --version` 成功才算可用。
- **python3 提示改成二选一**：A) 装 python.org 的 Python（不需要命令行工具）B) 装 Xcode 命令行工具；并直接说明「无法从软件更新服务器获得」那类报错是系统从 Apple 下载失败（多半是 VPN 把 Apple 域名也走了代理），可先关 VPN 再试。
- 配合：U 盘里放了 `python-3.14.7-macos11.pkg`（python.org 官方通用包），新电脑装它一个就能跑完整流程。
- 版本 **1.1.10.1 (31)**。

### v1.1.10.0 — 窗口高度可拉伸 + 一键配置不再拿 Key 背锅（2026-09-19）

- **窗口可以上下拉伸了**（像「系统设置」）：宽度仍锁 620 保持排版，高度改成弹性（最小 480，往上不限），拖下边框就能拉高，拉高后是**多显示内容**（配额图、图例一次看全）而不是留白；原来的 `.frame(width:height:) + .fixedSize()` 写死了尺寸，现在换成 min/ideal/max 约束 + `windowResizability(.contentSize)`。
- **修「新机点配置报 models.json 生成为空，请检查 key 是否有效」这个误导错误**：真凶是那台机器**没装 Xcode 命令行工具** —— macOS 的 `/usr/bin/python3` 在没装 CLT 时只是个占位程序，一执行就弹「请求安装开发者工具」然后失败。安装器原来的依赖检查只判断"命令存在"，占位程序存在 → 检查通过 → 后面所有 python 步骤（生成 models.json、config.toml、MCP 注入、picker 补丁）静默挂掉，统计那步 `|| echo 0` 兜底成 0，最后报成 Key 有问题（Key 明明在上一行刚校验通过）。
  现在改成：**真跑一次 `python3 -c 'print(1)'`**，失败就直接提示「先运行 `xcode-select --install`，装完（约 1GB，5~15 分钟）再点配置」；models.json 为空时也按真实原因分流（python3 不可用 / 模板缺失 / Key 过滤后无模型）。
- 实测：用假 `python3`（模拟没装 CLT 的机器）跑安装器，第一步就报明确的 `xcode-select --install` 指引，不再走到后面误报。
- 版本 **1.1.10.0 (30)**。

### v1.1.9.9 — 续费换新账期后，顶部数字不再挂着上个月的钱（2026-09-19）

- **修「账期显示 24、图却是空的」**：顶部那个大数字以前是**把快照里所有天相加**，不受账期/自然月开关影响；而柱子是按窗口过滤的。续费开新账期后，新周期还没用量 → 图是空的，数字却还是上个月自然月的 $24.11。现在总数和柱子共用同一套窗口（`ChartWindow`），账期新周期显示 $0.00，切「自然月」才是本月的钱。
- **修「换周期就丢半个自然月」**：抓取器以前只保留「账期窗口内」的天，新账期一开始就把 9/1–9/17 那段丢掉（自然月视图随即变空）。现在保留抓到的整月数据（这些月份天然覆盖当前账期 + 当前自然月），由各视图各自按窗口过滤 —— 账期看 9/19–10/18，自然月看 9/1–9/30，两边都完整。
- **顺手**：`build.sh` 不再每次构建都往桌面拷 DMG/ZIP（桌面清干净了，需要时 `COPY_TO_DESKTOP=1 ./build.sh`）。
- 版本 **1.1.9.9 (29)**。

### v1.1.9.8 — 图例只列「还在架」的模型，下架的不再占格子（2026-09-17）

- **图例跟着实时在架状态走**：以前图例 = Go 实时列表 + 「本月用过但不在列表里」的补位，于是 `ox-alpha-free`（8-28 就下架）、`hy3-free` 这种历史模型一直挂在图例里。现在图例 = **Go 实时 38 项 + Zen 免费实时列表里本月真用过的**；下架的一律不进图例，只在末尾留一行小字「另有 N 个已下架模型仍出现在历史柱里（ox-alpha-free、hy3-free 等）」，柱子颜色照旧保留，不会突然变白。
- **Zen 免费侧也实时同步**：新增 `https://opencode.ai/zen/v1/models` 的拉取与 24h 缓存（`-free` 后缀 + `big-pickle` 判定为免费），Zen 免费模型下架后同样会自动从图例消失。
- **图例后缀不再一律 (go)**：Zen 免费模型（`xxx-free`、`big-pickle`）现在标 (zen)，和 Go 模型区分开。
- **兜底配色不再每次启动换色**：未知模型的颜色从 Swift `hashValue`（每次进程重新加盐）改成 FNV-1a 稳定哈希 —— 已下架模型只在兜底配色里出现，之前每开一次 App 柱子颜色都变。
- 版本 **1.1.9.8 (28)**。

### v1.1.9.7 — 「别的电脑小组件空白」不用再猜：加一条备用通道 + 一键自检（2026-09-17）

- **根因说清楚**：主 App 是**非沙盒**进程，小组件是**沙盒**进程，两边唯一的桥是 App Group 容器里的 `widget_snapshot.json`。容器拿不到（App 没进 /Applications、被 Gatekeeper 重定位、扩展签名/entitlements 不可信、容器被清）时，小组件读不到数据 → 空白，而主 App 完全无感 —— 这就是「只有我那台正常」的原因。旧版还在这时候甩一句「未配置 ZEN_API_KEY」，与 Key 毫无关系，纯误导。
- **新增备用通道（关键修复）**：非沙盒的主 App 现在会把快照**也写进小组件自己的沙盒容器**（`~/Library/Containers/com.steve233.opencodego.widget/Data/Library/Application Support/OpenCodeGoWidget/widget_snapshot.json`）。沙盒扩展读自己的容器永远被允许，**完全不依赖 App Group entitlement**；主通道坏掉的机器靠这条路也能显示。写入只在容器已存在（小组件跑过一次）时进行，不会自己去乱建 Containers 目录。
- **写入不再静默**：`WidgetDataStore.save()` 现在三通道逐一尝试并返回结果，一个都没写成时主界面顶部弹橙色告警（以前全是 `try?`，失败无声无息）。
- **空态文案说真话**：改成分情况显示「小组件读不到共享数据」/「还没有用量数据」/「快照读取失败」，而不是一律「未配置 ZEN_API_KEY」。
- **新增「小组件自检」**：设置页一键生成报告——快照来源与时间、App Group 容器路径与文件是否存在、备用通道是否可写、偏好域是否可用，并附一句判读；旁边还有「重写快照」按钮，把三条通道重新灌一遍。
- 版本 **1.1.9.7 (27)**。

### v1.1.9.6 — 换电脑点「配置」能不能复制出一样的 Codex：全链路体检 + 修掉档位映射被目录反压（2026-09-17）

- **体检方法**：假 HOME + 假 launchctl，跑**应用包里**那支安装器，再和本机逐字段比对；干净安装、旧机更新两条路各跑一遍。
- **干净安装 = 完全一致**：38 个模型、顺序一致、逐字段差异 **0**（上下文 / 最大上下文 / 模态 / 默认档位 / 搜索 / apply_patch 类型 / 显示名 / 档位表）；`vision_proxy.py`、`model_discovery.py`、`reasoning_registry.json`、`reasoning_overrides.json`、`probe-new-model.sh` 五份哈希全一致；代理与自动发现两个 launchd 任务（6h + 开机）正确落盘。
- **旧机更新会自动纠错**：新模型自动补回（union-alpha / grok-4.6 / hy4-preview 37→40）、上下文纠回（hy3-go 200000→262144）、模态与显示名按 models.dev 纠正、陈旧代码文件按 mtime 覆盖、下架模型走 12h 宽限后清理。
- **修掉一个真缺口：手工实测档位被旧目录反压**。以前「目录里已有、且覆盖层也有」的模型会被跳过同步，导致老机器上错误的档位永远修不回来，而 `reasoning_registry.json` 又是照着目录生成的（实测 glm-5.3-go 卡在 `['medium']`、deepseek-v4-flash-go 卡在 `['low']`，一致性检查还打印「以目录为准」）。现在抽出 `_effective_levels()`，优先级钉死 **覆盖层 > models.dev > opencodex**，不一致就纠回并打日志，一致性检查文案同步改对；新增两条回归用例（含用假 `CODEX_HOME`/`CACHE_DIR` 驱动整个 `sync()` 的端到端用例）。
- 版本 **1.1.9.6 (26)**。

### v1.1.9.5 — Union Alpha Free 的上下文与档位对齐真实值（2026-09-17）

- **上下文 262144 / 输出 131072，三方实锤**：超长输入触发网关原文 `Prompt too long: about 360081 tokens estimated, but the maximum context length is 262144 tokens including the completion`；`max_tokens: 999999999` 回 `max_tokens exceeds maximum of 131072`；models.dev 的 `opencode-go/union-alpha` 与 `opencode/union-alpha` 两条元数据同为 `context 262144 / output 131072`。已把 262144 钉进 `CONTEXT_OVERRIDES`，避免以后上游元数据漂移把 Codex 窗口改小。
- **推理档位只有一档 `high`，这是真值不是漏配**：models.dev 明写 `reasoning_options: []`（`reasoning: true`，会思考但不可调）；实测 `thinking: enabled/disabled` + `budget_tokens` 512/1024/4096/32768/65536/90000、以及 `reasoning.effort` / `reasoning_effort` 全部被接受但行为一致（同题 4 次采样 output_tokens：默认 42.5 / disabled 41.0 / enabled 40），流式里也从不出现 `thinking` 块——网关吞掉了这些参数。已写进 `reasoning_overrides.json` 钉住：想「快一点」得换模型，这个旋钮是假的。
- **抖动容忍度提高**：`union-alpha` 会成片回 `503 Endpoint is unavailable`（实测连续 3 次），messages 桥的瞬时 5xx 重试从 3 次提到 4 次（退避 0.8/1.6/2.4s）。
- 维护手册 §29 补测段落记录全部原始证据。
- 版本 **1.1.9.5 (25)**。

### v1.1.9.4 — Union Alpha Free 真能在 Codex 里跑了：新增 Anthropic Messages 通道（2026-09-17）

- **新增 `/v1/messages`（Anthropic Messages）桥**：`union-alpha` 这类模型网关只放开了 Anthropic 格式（`/responses` 和 `/chat/completions` 恒 500，同刻其它模型全 200），代理现在把 Responses 请求翻成 Messages 请求、再把 Anthropic SSE 翻回 Responses SSE，Codex 侧完全无感：`instructions→system`、`function_call→tool_use`、`function_call_output→tool_result`、工具 `→ input_schema`、连续同角色合并、`max_tokens` 必填兜底，头部换 `x-api-key` + `anthropic-version`（Bearer 会 401 Missing API key）。
- **实测全绿**：流式文本、`shell` 工具调用（参数是合法 JSON）、带 `tool_result` 的第二轮、`apply_patch` freeform（返回合法 V4A 补丁）、非流式，全部 200。
- **顺手修好一条线上故障**：官方开始强制 `x-opencode-session`，缺了直接 `400 MissingSessionID`，而且 chat 端点也中招——实测 chat 桥（glm/mimo/qwen 这一大批）当天已经因此 502。代理以前从不发这个头，现在按「instructions + 前几条消息 + 模型」指纹补一个：同一对话稳定、不同对话不串号。修完 glm/mimo/kimi/qwen 对照组全部恢复 200。
- **两条桥加瞬时 5xx 重试**（500/502/503/504，只在没往客户端写字节前重试，不会重复计费）：`union-alpha` 会随机回 `503 Endpoint is unavailable`，退避一次就能成。
- **回归**：离线 66 项鲁莽用例 + 31 项单测（新增 12 项 messages 桥用例）全绿；`docs/MODEL-MATRIX.md` 与维护手册 §29 同步。
- 版本 **1.1.9.4 (24)**。

### v1.1.9.3 — 新的限时免费模型 Union Alpha Free 能看到了（2026-09-17）

- **修复「新模型显示不出来」**：官方给限时免费那行的三个配额格写的是「无限制」，而解析器的免费白名单里只有「无限」——`Int("无限制")` 转不出数字、也不在白名单里，整行被当成无效行丢掉。连带 `union-alpha` 根本没机会进入结果（同样的病根也在 Codex 侧的 `model_discovery.py` 里，导致 `union-alpha-go` 一直进不了 models.json）。现在白名单补上「无限制 / 不限 / 不限量 / free / unlimited」，并且不再靠猜 id。
- **id 不再靠猜**：文档显示名 `Union Alpha Free` 归一后会猜成 `union-alpha-free`，而网关真实 id 是 `union-alpha`（猜错直连 401 Model not supported，models.dev 里也没有这条可校正）。加了显示名 → 网关 id 的对照表。
- **缓存键升级到 v3**：否则升级后 12 小时 TTL 内还会继续显示缺 Union 的 v2 缓存。
- **限时免费那行换人**：`ox-alpha-free` 2026-08-28 就从 Go 下架（直连 401），9 月起由 `union-alpha` 接手。兜底名单、配色、脚注文案全部跟着换：亮绿给了 Union，脚注改成从数据里取免费行名（以后官方再换模型不用改代码），ox 只留一个褪色绿给历史费用柱子。
- **兜底名单整表刷新到 38 项**：补上 `union-alpha` / `omen-alpha` / `hy4-preview` / `qwen3.8-flash` / `glm-5.3-flash` / `longcat-2.0` / `grok-4.6` / `deepseek-v4.1-flash` / `deepseek-flash`；缓存过期判定里加了 `union-alpha`，数量凑够但漏抓也会被发现。
- **回归 fixture 加固**：`无限制` 行进离线 fixture（行数闸门 15 行）、`--live` 冒烟多断言一条「真实页面含 union-alpha」。
- 版本 **1.1.9.3 (23)**。

### v1.1.9.2 — 密钥终于能删能换 + 浏览器登录自动获取（2026-09-14）

- **密钥管理不再只有「留空复用」**：三处密钥位全部可管理。
  - `Go 额度设置`：新增「显示」明文查看、`清除已存 Key`（删 Keychain + App Group）、`清除 workspace 凭据`（删 workspaceID + authCookie）；填新值保存即替换。
  - `Codex 一键配置`：Go Key / DeepSeek Key 行新增红色「清除」按钮（确认后分别删除 env 里的 `ZEN_API_KEY` 行与 `config.toml` 的 `experimental_bearer_token` 行）；签名密码加「随机生成」一键口令（它绑定本地签名钥匙串，删除会让副本签名降级为 ad-hoc，因此不做清除）。
- **浏览器登录自动获取（新）**：设置页「浏览器登录自动获取」弹出内嵌浏览器（WKWebView，Safari UA），登录 opencode.ai 后自动：
  - 保存 auth Cookie + workspace ID → 费用柱状图立刻有数据，不用再导 HAR；
  - 拉取官方密钥页 SSR 数据，回填完整 Go Key（67 字符）到 Keychain 与两个设置栏；「拉取密钥」可随时再同步，多把 Key 时可选择「使用此 Key」；
  - 登录态自动保存、下次打开直接复用；「清除登录」一键退出并清 Cookie。
  - 建议用 GitHub 登录；Google 的 OAuth 可能拒绝内嵌浏览器。
- **修复「替换 Key 后点配置不生效」**：装好后再点「配置」走的是 `--update`，安装器以前无条件沿用旧 Key，把本次传入的新 Key 静默丢弃。现在更新模式优先使用本次传入的新 Key，未传入的才沿用旧值（用假 HOME 验证：全传/不传/只传 Go 三个分支都正确）。
- **修复「留空复用时 Key 悄悄丢了」**：App 以前只把输入框内容传给安装器——输入框留空、Key 只在 Keychain 里时，App 校验能过、脚本却拿不到 Key，配置会被静默写成「没有 Go Key」的纯官方直连。现在 App 传"有效值"（本次输入 > 已存 env > Keychain）并回写 Keychain。
- **修复「清掉 Go Key 后 Codex 里还能选到 Go 模型」**：更新模式会按本次 Key 修剪 models.json（无 Go Key 移除 `-go`/`-zen`，无 DeepSeek Key 移除官方模型）；无 Go Key 时同时停用残留的本地代理和 Go 模型自动发现，不再出现"选中 Go 模型直连 DeepSeek 报 model 不支持"。
- **DeepSeek Key 自动获取不可行（评估结论）**：DeepSeek 官方只在创建时展示一次完整 Key，接口不提供明文回读。已在登录弹窗提供「打开 DeepSeek 控制台」入口，DeepSeek 输入框新增「剪贴板填入」，浏览器里创建后复制一次即可。
- **解析回归自检**：新增 `scripts/test-key-parse.sh`（离线 fixture：本人/他人 Key、重复序列化去重、workspace ID 提取），`build.sh` 打包前强制通过。
- 版本 **1.1.9.2 (22)**。

### v1.1.9.1 — 小组件的配额表也能看到 DeepSeek V4.1 Flash 了（2026-09-14）

- **修复「配额面板少一行」**：官方给 V4.1 Flash 那行加了促销装饰（名字带 `<br><small>4x · 9 月 20 日结束</small>`，数值是 `<del>旧值</del><br><strong>新值</strong>`），小组件沿用的解析要求单元格是纯文本，整行匹配失败 → 这一行直接消失了。现在解析改成「按行取格、剥标签取文本」：名字丢掉 `<br>` 之后的备注，数值取 `<strong>` 的当前值。
- **促销额度看得懂**：V4.1 Flash 显示 4x 后的当前额度 26,000 / 65,000 / 130,000，行内带一个橙色 `4x` 小标签（悬停看完整备注「4x · 9 月 20 日结束」）。
- **一眼区分容易混的两行**：模型名列从 130pt 加宽到 150pt —— 之前 `DeepSeek V4 Flash Vision Exp` 被截断成「DeepSeek V4 Flas…」，和 `DeepSeek V4 Flash` 长得几乎一样。
- **缓存键升级到 v2**：否则升级后 12 小时 TTL 内还会继续显示缺 V4.1 的旧列表；现在装完立刻重抓。
- **兜底名单整表刷新**：离线/首装的硬编码名单按 2026-09-14 实时表重写（27 行，含 `deepseek-v4.1-flash`），顺带修掉 `deepseek-v4-flash=7600`、`qwen3.7-max=340`、`flash-vision-exp=3800` 三处过期数字。
- **打包门禁加一道自检**：`scripts/test-quota-parse.sh` 用官方真实片段做离线 fixture 回归（促销装饰行 / 价格行 / 模型清单行 / <10 行闸门），`build.sh` 里不通过就不让打包；`--live` 模式可另抓真实页面冒烟。同一天 Python 端 `model_discovery.py` 修的是同一个病根。
- 版本 **1.1.9.1 (21)**。

### v1.1.9.0 — 配额表解析不再漏行 + 档位对齐补齐（2026-09-14）

- **修复模型"自己消失"**：官方给 Go 配额表里的 DeepSeek V4.1 Flash 那行加了 4x 促销标记（单元格变成 `<br><small>` 备注 + `<del>旧值</del>/<strong>新值</strong>` 双值），旧解析只认纯文本单元格，整行匹配失败 → 配额 id 27→26 → 同步把 `deepseek-v4.1-flash-go` 当野模型剪掉，Codex 的模型列表里再也选不到。现在解析一律剥标签取文本：行名丢掉 `<br>` 后面的促销备注，配额取当前生效值（`<strong>`，不是被划掉的 `<del>`）。
- **剪枝双闸**：① 文档页里还出现该模型 → 判为解析漏行，`safety-hold` 不剪；② 首次缺席只记账，连续缺席超过 12 小时（两轮同步）才剪。上游改文档格式、抓取截断、正则撞车都不会再当场删掉能用的模型，日志会写明谁被 hold / 谁在挂起。
- **档位对齐补齐到安装模板**：`templates/config.toml` 的 `[desktop]` 现在自带 `enabled-reasoning-efforts`，取值与 `model_discovery.py` 的 `_effective_whitelist()` 一致（app 默认档 + 目录里出现过的档位）。新机器装完即可看到全部档位，不再依赖首次同步成功（VPN/SSL 抽风时也不会少档）。
- **档位矩阵重生成**：`docs/MODEL-MATRIX.md` 基线更新到 2026-09-14，37 个模型的档位/协议/搜索列与本机目录一致（此前仍停在已改名的 `deepseek-flash-go`）。
- 回归测试：`test_model_discovery_robust.py` 新增 `t_quota_nested_markup_row`（带装饰标签的行必须解析出来）与 `t_prune_safety_hold`（解析漏行不剪、首次缺席挂起、连续缺席才剪），四套件 76 例全绿。
- 版本 **1.1.9.0 (20)**。

### v1.1.8.9 — Muse 浮点参数死循环修复（2026-09-12）

- **修复 Muse 在 Codex 副本里的工具调用死循环**：Muse 经 Go 网关回来的工具参数里整数常带 `.0`（如 `yield_time_ms: 30000.0`、`max_output_tokens: 8000.0`），Codex 原生执行器只认整数，直接拒收，模型嘴上说"参数类型写错了"实际每次发一样的，原地空转十几轮。代理现在统一归一化：SSE `function_call_arguments.done` / `output_item.done`、非流 JSON、chat 桥、历史回放五条路径全覆盖，真小数/字符串/bool 不动，健康参数字节级透传。
- **9 月 2 日修过一次同类问题**，当时补丁落在临时目录没合进仓库所以复发了，这次正式合入 + 补回归测试，不会再丢。
- 测试：`test_units.py` 21/21、`test_robust.py` 31/31、`test_model_discovery_robust.py` 14/14。
- 版本 **1.1.8.9 (19)**。

### v1.1.8.8 — 应用内更新 + 视觉代理下线（2026-09-10）

- **应用内更新**：设置页新增「检查更新」（打开设置页自动查一次，24 小时节流；菜单栏也有入口）。发现新版显示「发现新版 x.y.z」，点「更新」才会下载 ZIP、校验 bundle id/版本、替换 `/Applications` 里的旧版（旧版改名 `.bak-旧版本` 留作回退）并自动重启；不后台静默更新，`/Applications` 不可写时退化为打开 Release 页面。
- **视觉代理彻底下线**：删除智谱 GLM 转文字整条链路（`vision_client.py`、`vision/bin/` 五个看图 CLI、`NATIVE_VISION_MODELS`、图片历史裁剪）。**不再需要视觉 Key**，一键配置从 4 栏减到 3 栏（Go / DeepSeek / 签名密码）；图片由模型原生处理，不声明 `image` 的模型发图会报错，换有视觉的模型即可。安装器会顺手清掉旧机器 env 里的 `VISION_*` 三行。
- **修复 kimi-k3 不可用**：Go 网关把「该模型不支持 responses 格式」的报错从 500 改成 401，代理只在 500 时切 chat 桥，导致 kimi-k3 文/图都失败。现在已知 chat 适配模型吃 401 也会切桥（kimi-k3 文本与图片实测通过）。
- **档位三层一致**：`model_discovery.py` 每次同步会一起生成代理档位表 `reasoning_registry.json` 和桌面端 `enabled-reasoning-efforts` 白名单，并做一致性自检——以前目录声明 3 档、界面只显示 2 档、发出去还可能被压成第 2 档的问题不会再出现。手工档位改 `reasoning_overrides.json`（registry 从此是生成物）。
- **模型 id 归一**：Go 配额表里的新模型会用 models.dev 官方 id 校正（`DeepSeek V4.1 Flash` 曾猜成 `deepseek-v4.1-flash` 导致 401，正确 id 是 `deepseek-flash`）。
- **发布资产改名**：DMG/ZIP 以 ASCII 名发布（`OpenCodeGoWidget-1.1.11.7.zip`），README 直链不再 404。
- 版本 **1.1.8.8 (18)**。

### v1.1.8.7 — 清死代码 + 新模型 SOP 工具化（2026-09-05）

- **死代码清理**：删除 `_SEARCH_FALSE_MODELS` 名单、`_strip_web_search_tool` 纯 no-op 函数及引用，测试改写为 synthetic 注入 fuzz；拦截逻辑已收敛为 `_SEARCH_TRUE_PREFIXES` 白名单通用分支。
- **安装器防旧包降级**：`codex-oneclick-setup.command` 新增 `sync_newer_file` mtime 守卫 + 原子锁，旧包点"配置"不再覆盖本机新修复。
- **新模型 SOP 工具化**：新增 `vision/probe-new-model.sh` 5 探针分类器（协议/档位声明验证/联网/视觉/400穿透），`docs/MODEL-MATRIX.md` 37 模型基线矩阵。
- **Zen Free 动态化修复**：`-free` 后缀自动发现，新增 deepseek/muse-1.3 免费版（37 total）；模态白名单过滤 video/pdf（卡 logo 修复延续）。
- 版本 **1.1.8.7 (17)**。

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
dist/OpenCode 小组件-1.1.9.2.dmg
dist/OpenCode 小组件-1.1.9.2.zip
dist/OpenCode 小组件.app
~/Desktop/OpenCode 小组件-1.1.9.2.dmg  # build.sh 会自动拷一份到桌面
```

依赖只需要 Xcode Command Line Tools 和 macOS 14+ SDK。脚本会优先寻找本机可用签名身份，找不到时使用 ad-hoc 签名。

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
