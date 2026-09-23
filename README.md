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
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.38.dmg">
    <img src="https://img.shields.io/badge/下载-DMG%20安装包-0A84FF?style=for-the-badge&logo=apple&logoColor=white" alt="DMG">
  </a>
  &nbsp;
  <a href="https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.38.zip">
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

- DMG：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.38.dmg>
- ZIP：<https://github.com/Steve233333/OpenCodeGoWidget/releases/latest/download/OpenCodeGoWidget-1.1.11.38.zip>
- 历史版本：<https://github.com/Steve233333/OpenCodeGoWidget/releases>

首次打开如果提示「未验证开发者」，右键应用选「打开」即可。

## 更新日志

> 完整历史（20+ 个版本）见 [CHANGELOG.md](CHANGELOG.md)。这里只列最近三个版本。

### v1.1.11.38 — 修「upstream 400：`arguments` must be valid JSON」

**现象**：用 muse 继续一段老对话时，上游直接 400：
`Upstream request failed: [invalid_request_error] \`arguments\` must be valid JSON`，整轮发不出去。

**根因（实测定位，不是猜）**：会话历史里有 **4 条 `function_call` 的 `arguments` 本身不是合法 JSON** ——
`proposed_plan` 是空串、`request_user_input` 被截断、`write_stdin` 少了半截（都是某次工具调用没发完整留下的）。
我们原样回放，Go/Zen 网关按 function 校验就整轮拒掉。muse 上必现；deepseek 上会先撞另一条校验
（`reasoning_text`），所以之前没暴露。

**修法**：`proxy/toolfix.py` 新增 `_repair_history_args()`，在回放历史时把 `arguments` 修成合法 JSON ——
能救的救（补 `{"` 前缀、去尾逗号、补闭合符号），救不回来的退化成 `{}` 并记一行日志；
`_normalize_fc_args_history()` 现在对每条 function_call 都过一遍（以前只认得"缺 `{"`"那一种形态）。

**复现 + 验证（同一探针）**：
- 修前：`muse-spark-1.3-contributor-go` + 截断 arguments → **HTTP 400**（与你看到的一字不差）
- 修后：同一请求 → **HTTP 200** ✓
新增单测覆盖 6 种形态（含 3 条真实坏样本）。

版本 **1.1.11.38 (78)**。

### v1.1.11.37 — 转换层收敛收尾：SSE 引擎拆完 + handle 拆完（并加部署护栏）

**③ SSE 引擎（完成）**
- `_rewrite_sse_frame` 159 → **22 行**：解析 → 记账 → 按帧类型查表分派 → 没认领就原样字节转发；
  5 个 handler（`_rf_terminal` / `_rf_output_item_added` / `_rf_fc_args_delta` / `_rf_fc_args_done` /
  `_rf_output_item_done`）。
- `_complete_sse_frame` 247 → **39 行**：三个共享 `seq/out/compat` 的闭包抽成 `_ChatCompatCtx` 类，
  7 个帧分支变成类方法 + `_COMPAT_HANDLERS` 分派表。
- 护栏：`tests/test_sse_golden.py` + `tests/fixtures/sse_golden.json` —— 用**重构前**的逐帧输出当规格
  （deepseek 原生流 / muse 命名空间工具 / apply_patch 参数流 / 无终止帧 / 垃圾帧 / 重复 item_id），
  改完**逐字节一致**；另有一条专门钉"没登记的帧必须原样字节转发"。

**② 请求管线（完成）**
- `handle()` 485 → **31 行**（只剩：建 txn → `_turn_begin` → `_turn_execute` → 异常映射 → 收尾日志）。
- `_turn_begin`（52 行）：读请求体 → 准备 → 回传 `turn`；`_prepare_parsed_request`（89 行）负责模型名兼容 /
  apply_patch 改写 / 合成搜索 / 工具历史修补 / muse 注入 / 预算与推理档位；`_turn_execute`（341 行）承接
  上游与路由执行（这一块内部还能再按 route/bridge/native 细分，但不影响本阶段目标）。
- server.py 1398 → 849 行；pipeline.py 独立成文件（`RequestPipelineMixin` 组合进 `Proxy`）。

**新增部署护栏（今天的教训）**
`scripts/deploy-proxy.sh`：备份运行目录 → 同步 → 强制重启 → **跑四家族冒烟** → 失败自动回滚并重启。
起因：这次我把 `pipeline.py` 的重构**先部署再冒烟**，漏传一个变量（`incoming_headers`）导致四家族全 502，
你的 Codex 先踩到了；补传后已恢复。以后统一走这个脚本，坏的代码上不了线。

验证：全量 **47 + 3 + 8 + 31 + 14 + 8** 全绿；SSE 基线逐字节一致；真机冒烟四家族全绿
（DeepSeek 47 / MiMo 44 / Muse 24 / GLM 70 字，markup 均 0）。

版本 **1.1.11.37 (77)**。

### v1.1.11.36 — 转换层收敛 ④（先行）：魔数入表、删死代码、补架构文档

Phase ① 之后先把**风险最低、收益明确**的第 ④ 阶段做掉（② `handle()` 拆管线、③ SSE 管道化还在排队）：

- **24 处裸魔数变成具名常量**（`proxy/config.py`）：`IO_CHUNK_BYTES` / `IO_BUFFER_BYTES` /
  `RETRY_BACKOFF_BASE` / `WEB_SEARCH_*_LIMIT` / `SSE_MAX_BUFFERED_FRAME` —— 值一个没改，只是不再是
  散在逻辑里的 `65536`、`0.8 * (i + 1)`、`[:4000]`。
- **删掉只被测试用的死代码** `_build_chat_fallback_events`（生产早走增量翻译器）：它那两条测试
  （"流里正文 + 工具调用拼装"、"坏 JSON 参数修复"）**改走生产路径**（`ChatBridgeTranslator`）继续守着，
  死代码没了、覆盖没少。
- **新增 `Resources/codex/vision/README.md`**：一张图看懂模块分工、策略表字段含义、每个模型家族现在的行为、
  "症状 → 先看哪里"对照表、测试与门槛。以后加模型或排查问题不用再翻代码。

验证：全量 **47 + 3 + 8 + 31 + 14 + 8** 全绿；真机冒烟四个家族全绿（DeepSeek / MiMo / Muse / GLM）。

版本 **1.1.11.36 (76)**。

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
