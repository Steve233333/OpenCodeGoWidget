# 更新日志

> 每个版本都写了：改了什么、为什么改、实测数据。最新的在最上面。

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

### v1.1.11.31 — Muse 终止事件修补（对齐 opencodex 的 modelResponsesTerminalRepair）

现象：muse-spark 在 OpenCode Go/Zen 的 Responses 模式下「做任务弄着弄着空转」。翻 opencodex 的
`#5240`（今天刚合并）看到根因和我们一致但修法更好：

- **上游发完内容却不发终止帧**（省略 `response.completed` 与 usage）。我们原来的处理是**立刻**补一个
  `response.failed` —— 这一轮被判「中断」，内容其实已经完整；
- opencodex 的做法是 `modelResponsesTerminalRepair`（`graceMs: 5s`）：**等一个宽限窗口，如果开过的每个
  输出项都收到过 `response.output_item.done`（内容完整），就补 `response.completed`**，只有内容确实不完整
  才判失败。

这一版把同一套契约搬过来（不是照抄实现，是按我们的流式管线重写）：

- `proxy/sse.py`：状态机新增"开过几个输出项 / 关掉几个 / 完成的项留一份"的追踪，并导出
  `sse_turn_looks_complete(state)`（开过的项都 done 且至少一个）；
- `proxy/server.py`：① 收尾时先按上面判定 —— 内容完整就补 `response.completed`（带上已经发过的 output 项），
  不完整才保持原来的 `response.failed`（老行为不丢）；② 新增**空闲宽限**：给上游 socket 套 5 秒读超时，
  "挂着不发字节"且内容已完整时立刻收尾（这是"空转"的另一半 —— 以前会一直等）；连续空闲 24×5s=120s
  仍不完整才判失败；有数据就重置计数，慢但活着的流不会被误掐。

验证：
- 新增 `tests/test_terminal_repair_relay.py`（中继层，4 条）：上游关连接不发终止帧 → 补 completed 且
  带上 output 项 / 上游挂着不发字节 → 空闲宽限补 completed / 内容不完整 → 仍判 failed / 真终止帧原样转发。
  已接进 `build.sh --test` 门槛（Python 全量 37+4+31+18+8 全绿）。
- 顺带修一个我刚引入的坑：ensure-proxy 变"幂等不重启"后，**「配置」同步了新代理代码却不会重启它**
  （新代码永远不生效）→ 加 `--force-restart`，安装器这一步强制换新进程；`scripts/test-ensure-proxy.sh`
  第 ⑥ 条断言"跑着的旧进程会被换掉"（pid 变化）。
- 真机：deepseek 流式 200 且日志出现 `SSE 空闲宽限 5s 已启用`；muse 冒烟 200（顺带看到 narration-only
  空转重试真实触发一次 #1/#2 后成功）。

版本 **1.1.11.31 (71)**。

### v1.1.11.30 — 让"系统升级/重启后代理掉线"自己好起来

**起因（macOS 27 升级那次，日志里坐实的链条）**：

1. App 点「配置」时 PATH 很干净，安装器用 `command -v python3` 挑解释器 → 命中 `/usr/bin/python3`
   （**Xcode 自带的 Python 3.9**），plist 就这么写死了；
2. 刚升完系统它一时起不来 → 11:04:30 起代理一直没监听（KeepAlive 重试到 11:09:51 才成功）
   → Codex 侧表现成 **"Reconnecting… waiting for network"**；
3. 代理回来时代码已经把模型切成 `opencode-go/deepseek-v4.1-flash`，路由只认 `-go`/`-zen` 后缀
   → 被当成"官方 DeepSeek 模型"转发到 api.deepseek.com → **401**。

上周加的「配置后自检」正好抓到了第 2 条（`自检① 本地代理：❌`）。这次补的是三个结构性缺口：

**① 代理生命周期只有一份实现（新 `vision/ensure-proxy.sh`）**
挑解释器 → 写状态文件 → 写/刷新 plist → 起服务 → **探活验证**，安装器与 App 都调它。
解释器改成**逐个实测**（`import ssl,json,asyncio` 跑得通才算），优先级：
python.org `3.*`（版本号倒序，跳过 `Versions/Current` 软链）→ `/usr/local` → Homebrew → `/usr/bin/python3`
（仅兜底，且日志明说"依赖 Xcode/命令行工具"）。绝不再看 PATH 里第一个。
状态文件 `~/.local/share/agent-vision-toolkit/proxy-runtime`（key=value）：解释器、版本、上次修复时间、
上次结果 —— App 自检直接读它显示。

**② App 自己把代理救回来（新 `Sources/ProxyWatchdog.swift`）**
启动后 10 秒、每 5 分钟、系统唤醒时先探活（**端口有响应就立刻返回，平时零开销零日志**）；
没响应才调 ensure-proxy.sh，顺手把"新模型自动发现"那个 launchd 任务也检查/重挂一次。
救不回来时：**菜单栏图标红点 + 面板顶部红字 + 设置里「修复本地代理」按钮**（不引入通知权限）。
不新增常驻 LaunchAgent —— App 本身是登录项，少一个零件。

**③ 带 provider 前缀的模型名也能路由**
`opencode-go/<slug>` ≡ `<slug>-go`、`opencode-zen/<slug>` ≡ `<slug>-zen`，归一化在一处（`proxy/config.py`
的 `normalize_route_model`），之后照走原有 go/zen 分支（别名表、日志格式不变），裸名行为完全不变。

**④ 自检说人话**
「配置后自检」与 App 的 `HealthCheck` 把代理从二态改成**三态**：未加载 / 加载了但进程没起来（带 launchctl
最后退出码）/ 进程在但端口不通，各自给对应的下一步；并显示当前解释器与上次自动修复时间。

**顺手修的一个 shell 可移植性 bug**：全项目 25 处 `$VAR` 后面紧跟中文标点（如 `$PORT）`），
bash 在非 UTF-8 locale 下会把标点当成变量名的一部分 → `set -u` 直接报 unbound（我写这个脚本时实测踩到）。
统一改成 `${VAR}` 写法，安装器 + 步骤文件 + 新脚本一起修。

**验证**：

- 离线（进了 `build.sh --test` 门槛）：`scripts/test-ensure-proxy.sh` 6 条 —— 跳过跑不起来的解释器、
  全坏时 rc=1 且不写脏文件、兜底解释器有警告、**真起一次**（临时 label + 端口 19531 + 临时目录）端口有响应、
  优先用 python.org 而不是 `/usr/bin/python3`、已在跑时幂等；Python 侧补了前缀路由 3 组单测。
- 真机：`launchctl bootout` 掉代理后跑 ensure-proxy → **2.6 秒修好**，plist 从 `/usr/bin/python3`(3.9)
  换成 `/Library/Frameworks/Python.framework/Versions/3.13/bin/python3`(3.13.1)，端口恢复响应；
  `opencode-go/deepseek-v4.1-flash` 实测 **200**（修之前是 401）。

版本 **1.1.11.30 (70)**。

### v1.1.11.29 — 重构第四阶段：安装器拆步骤 + 配置后自检（必跑）+ 残骸清单

`codex-oneclick-setup.command` 968 行一个文件、从互斥锁一路写到汇总。这一版拆成**主脚本 + 步骤文件**：

| 文件 | 内容 |
|---|---|
| `codex-oneclick-setup.command` | 200 行：头部/参数、`log`/`die`/`ask_*` 助手、互斥锁、`sync_newer_file`，然后按顺序 `source` 下面 13 个步骤 |
| `setup/steps/10-mode.sh` | 0. 模式选择（安装 / 更新） |
| `setup/steps/20-keys.sh` | 1. 收集 Key |
| `setup/steps/30-signing.sh` | 2. 签名密码 + 自签证书 |
| `setup/steps/40-deps.sh` | 3. 依赖检查 |
| `setup/steps/50-backup.sh` | 4. 备份旧配置 |
| `setup/steps/60-models.sh` | 5. 生成 models.json |
| `setup/steps/70-defaults.sh` | 6. 默认模型 / base_url / bearer |
| `setup/steps/80-agents-mcp.sh` | 7. AGENTS.md + MCP 搜索 |
| `setup/steps/90-proxy.sh` | 8. 本地代理 |
| `setup/steps/100-patched-app.sh` | 9. ChatGPT-Patched.app |
| `setup/steps/110-archive-off.sh` | 9b. 已停用项（留着提醒别回退） |
| `setup/steps/120-summary.sh` | 10. 汇总 |
| `setup/steps/130-selfcheck.sh` | 11. **配置后自检（新增，必跑）** |

**踩过的坑写在文件头**：这个脚本是 zsh 且 `SCRIPT_DIR="$(dirname "$0")"`；zsh 默认 `FUNCTION_ARGZERO`，被 `source` 的文件里 `$0` 会变成那个步骤文件 —— 所以**路径推导一律留在主脚本**，步骤文件只用已经算好的 `SCRIPT_DIR`。

**验证**（没法拿新机器测，就用这三条）：

1. 步骤文件与主脚本 `zsh -n` 全部通过；
2. 把主脚本 + 13 个步骤按 source 顺序重组，与拆分前的 968 行逐行比对：**除"新增自检"和下面那条 `RES_DIR` 兜底外，一行不差**；
3. 从**打包好的 App 包**里拷出 `codex/` 目录，用假 `HOME` 跑了一次完整的更新模式（`--noninteractive --skip-patch --skip-proxy-start --update`）—— 走完模式选择/Key/依赖/备份/模型表/默认模型/AGENTS/MCP/代理文件/汇总/自检，退出码 0；
4. 顺手修掉一个开发期踩坑：直接从**仓库**跑安装器时没有 App 包里那个 `resources -> .` 软链，会在"生成 models.json"报"模板文件缺失"。现在用 `RES_DIR` 兜底（App 包里 `RES_DIR=resources`，仓库里 `RES_DIR=.`），两种布局都跑通了。

**配置后自检**（新增）：固定写进日志的是 ① 运行环境（macOS 版本、架构、python3 版本、HOME）② 三个关键服务（launchd 本地代理 / `~/.codex-deepseek/config.toml` / `ChatGPT-Patched.app`）③ 每条失败的**下一步**（看哪个日志、跑哪条命令）。只报告不中止，失败项在日志里一眼可见。

**残骸清单（没删，等你点头）**：`/Applications` 里 5 个 `.bak-*` 旧副本、`dist/` 504 MB（47 个历史版本的 DMG/ZIP）。清单和体积见本次交付说明，确认后我再删。

版本 **1.1.11.29 (69)**。

### v1.1.11.28 — 重构第三阶段：本地代理拆包（纯搬移，行为不变）

`vision_proxy.py` 原来是 **3793 行 / 107 个顶层符号**的单体脚本（协议桥、搜索边车、工具修补、Muse 兼容、SSE 重写、HTTP 服务全在一个文件里）。这一版拆成薄入口 + `proxy/` 包：

| 文件 | 内容 | 行数 |
|---|---|---|
| `vision_proxy.py` | 入口 + 兼容层（launchd 路径没变） | 55 |
| `proxy/config.py` | 配置/常量/日志/推理档位注册表 | 284 |
| `proxy/bridges_chat.py` | Responses ⇄ Chat Completions 桥 | 550 |
| `proxy/bridges_messages.py` | Responses ⇄ Anthropic Messages 桥 | 309 |
| `proxy/toolfix.py` | 工具调用 / JSON 参数 / 历史修正 | 261 |
| `proxy/search_sidecar.py` | 联网旁路 | 302 |
| `proxy/muse.py` | Muse 兼容层 | 319 |
| `proxy/apply_patch.py` | apply_patch 工具改写 | 147 |
| `proxy/sse.py` | SSE 流改写引擎 | 609 |
| `proxy/server.py` | Proxy 类（路由/上游转发）+ main() | 1218 |

**怎么证明是纯搬移**：把 107 个顶层符号逐个按源码片段比对，**全部逐字节一致**（只多了模块 docstring / import / 空行），另有静态检查确认每个模块引用的全局名字都能解析（没有漏 import），且模块依赖图无环。

配套改动：

- **入口保留兼容层**：老测试是用 `spec_from_file_location` 直接加载 `vision_proxy.py` 再取 `vp.<符号>` 的，所以入口把各模块的顶层符号重新导出一遍，这些测试（66 个用例）与 Muse 兼容自检（13 项）全部照旧通过；
- `check-drift.sh` 改成**整目录递归比对**（含 `proxy/` 子目录），不再只比几个固定文件；
- `docs/gen-model-matrix.py` 改成从 `proxy/` 包里抠常量（以前只读单文件文本）；
- **顺带修掉一个原有的静默 bug**：`_perform_web_search` 的 env 兜底用到了 `pathlib` 但整个文件**从没 import 过它**，而那一圈是裸 `except: pass` —— 结果是"环境变量里没有 ZEN_API_KEY 时，去 env 文件里找 key"这条兜底永远静默失败。补上 `import pathlib`。

真机冒烟（就是这台，代理已换成拆包版本）：DeepSeek `bridge=None status=200`、GLM `bridge=chat-fallback status=200`（命中 503→chat 桥回落）、Muse `status=200`，日志零 Traceback；跑着的 Codex 长请求（2.7 MB body）同样 200。

版本 **1.1.11.28 (68)**。

### v1.1.11.27 — 重构第二阶段：界面代码拆开（纯重构，界面一模一样）

`App.swift` 1265 行一个文件装着整个界面（应用壳 + 仪表盘 + 图表 + 设置 + 自检行），改任何一处都要在这一个文件里翻半天。这一版把它按职责拆开：

| 文件 | 内容 |
|---|---|
| `Sources/App.swift` | 应用壳：`@main`、菜单栏图标、`AppDelegate`（117 行） |
| `Sources/Views/DashboardView.swift` | 主面板（原来是 `ContentView`，改叫 `DashboardView`） |
| `Sources/Views/ChartViews.swift` | `MonthChartView` / `CostBar` |
| `Sources/Views/QuotaViews.swift` | `QuotaRow` |
| `Sources/Views/SettingsViews.swift` | `SettingsView` / `GoSettingsContent` |
| `Sources/Views/SelfCheckViews.swift` | `HealthCheckRow` / `WidgetSelfCheckRow` |

**怎么确保"界面一模一样"**：拆完把新旧源码逐行比对（去掉空行/注释/import 后 **1122 行 vs 1122 行完全一致**），只有 `ContentView` → `DashboardView` 这一次改名 —— 属于纯搬移，不是重写。

顺带清掉两条编译告警（构建现在 **零告警**）：

- `onChange(of:perform:)` 在 macOS 14 起已废弃 → 改成两参数版本；
- `WidgetDataStore` 里一个"永远没被改过的 var"。

`build.sh` 的源码清单改成**递归扫描 `Sources/`**（支持 `Views/` 子目录），拆文件不会再出现"打包时才编译失败"。

版本 **1.1.11.27 (67)**。

### v1.1.11.26 — 重构第一阶段：用量管线的规则收敛成一份（纯重构，行为不变）

起因：四周内为修数据问题发了 18 个版本，补丁层层叠加 —— 同一条"不许丢明细"的规则在 4~5 个地方各写了一遍（`preferDetail`、两套路径各自的守卫、`applyUnionDetail`、`daysMissingDetail`），改一处漏一处，于是"纯色 / 差一天 / 按 Key 对不上"换着形态复发（9/19–9/23 复发 4 次）。

这一版不加功能、不改口径，只做结构：

- **`UsageMerge`（合并规则唯一真源）**：只增不减、明细优先（纯总额要明显更大 >5% 才盖掉明细）、半窗不冲整天（旧的更大 >0.1% 就保留）、按 Key 覆盖、并集自愈（<98% 拒绝替换，纯总额且 ≥90% 时等比归一）。日常刷新与按天回填**都只调它**。
- **`UsageRows`（行解析唯一真源）**：微美分换算 + `createdAt` → 北京时间日的映射（走 `ChartFormatters.day`）+ 一行同时算进"按模型"和"按 Key"两份拆分。
- **删掉老 `/_server` 整条回落链**（`fetchViaWorkspace` / `fetchWorkspaceCost*` / `fetchHARFallback` / `parseServerFnCost` / `cacheServerText` / `lastServerText`）：该接口随控制台改版已 404，回落只会把 9/19 的 HAR 旧数据当成本日数据；现在失败 = 保留旧快照 + 报错。
- **新增密钥列表接口**：`GET console/api/service-accounts`（items[].keys[] 带 id/name/status/revokedAt），替代已失效的 `/workspace/<ws>/keys` HTML 抓取，顺带过滤吊销的 Key。
- **补测试**：`Tests/UsagePipelineTests.swift` + `scripts/test-usage-pipeline.sh`，8 组 33 条断言，钉死上面每条规则（含"没带 keyId 的行算总额不算按 Key"这种边界）。离线、不联网、`build.sh --test` 里是门禁。
- **拆文件**：`CostCrawler.swift` 960 → 260 行，拆出 `ConsoleUsageAPI`（网络/游标/解析）、`UsagePipeline`（回填/进度/落盘）、`UsageCostModels`（DailyCost/MonthlyCost）、`ChartFormatters`（日界）。

行为、数字口径（北京时间 0 点）、配额来源（官方 `go/status`）一律没变。

版本 **1.1.11.26 (66)**。

### v1.1.11.25 — 重构第零阶段：版本号单一真源 + 测试门槛（纯流程，行为不变）

- **单一版本源**：新增 `./VERSION`，`build.sh` 读取它推导 `CFBundleShortVersionString` + `CFBundleVersion`（以前手改 4 处，25 个提交里改了 19 次）；
- **测试门槛聚合**：`./build.sh --test` 一次跑齐 drift 检查、配额解析自检、密钥解析自检、用量管线自检、Python 代理全量测试；正式打包走同一套门槛；
- **README 拆分**：650 → 200 行，历史条目移到本文件，README 只留简介 + 最近三版；
- 下载直链由构建时自动对齐当前版本号（以前漏改就 404）。

版本 **1.1.11.25 (111125)**。

### v1.1.11.24 — 日界统一成「北京时间 0 点」+ 修「今日总额和今日模型不同口径」

**你拍板的：要 0 点刷新。** 这一版把全 App 的"天"统一回 **Asia/Shanghai 0 点翻页**（柱子、今日卡片、图例、回填窗口、小组件近 7 天全部一致）。

顺带修掉你截图那个 bug —— 同一个"今日"里两套口径：

- 「今日模型」的取数走 UTC 日（= 9/22，还有 $2.93）
- 「今日」那个总额走本地日（= 9/23，刚过 0 点 → $0.00）

根因是 `MonthlyCost.todayEntries()` / `todayEntries(for:keyId:)` / `fetchCostTodayPerKey()` 各自**自带一份 Asia/Shanghai 格式化器**，而 `ChartFormatters.day` 当时是 UTC —— 两套口径同时生效。现在这三处全部改成调用 `ChartFormatters.day`，**日界只由一处定义**。

配套改动：

- `ChartFormatters.day` 与 `BillingCycle.tz` 回到 `Asia/Shanghai`（月/账期窗口、小组件、图表自动跟随）；
- **停用 `cost-by-day` 的逐日对账**：官网那份是 UTC 日口径，拿它缩放/降级会把本地日金额改回 UTC 日（`cost-by-day` 只保留"哪些天有数据"的兜底作用，金额以逐条 `rows` 为准）；
- 一次性迁移：`usageDayConvention` 由 `utc` 改 `local`，首次运行自动作废旧快照 + 回填标记并重拉 30 天明细（约 1 分钟）；
- 额度（5h/周/月）仍走官方 `go/status`，不受影响。

**已知代价**（你已确认接受）：逐天金额不再与官网 UTC 日逐天 0 差，实测每天差 $0.02–0.16；账期/自然月总额本身不受影响（同一批行求和）。

版本 **1.1.11.24 (65)**。

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

### v1.1.11.20 — MiMo 2.6 两个新模型：五项能力直连实测校准

绕开本地代理、**直连网关**对 `mimo-v2.6-flash` / `mimo-v2.6-pro` 逐项实测（避免被代理兜底掩盖真实行为）：

| 项目 | 实测结果 | 处理 |
|---|---|---|
| 上下文 | models.dev：**1,048,576（1M）**，输出 131072 | 保持 1M ✓ |
| 推理档位 | `low` ✓ `medium` ✓ `high` ✓；`minimal` / `xhigh` / `max` 一律 **400 Invalid request parameters** | 之前只写 `high`（把低/中档藏掉了）→ 写进 overrides 为 low/medium/high（默认 low）；代理 clamp 会把 xhigh/max 夹到 high |
| API 格式 | `/responses` **503 Endpoint is unavailable**，`/chat/completions` **200** → 只支持 chat | 加进代理 chat 桥名单（`RESPONSES_FALLBACK_MODELS`），经代理实测 **200**（日志：`responses->chat fallback engaged`） |
| 联网 | chat 端点无原生 search | 由代理 sidecar 代搜（日志确认 `injected synthetic web_search`）✓ |
| 图片 | 带图请求实测 **200** | models.json 声明 `text+image+audio` ✓（models.dev 还列了 video/pdf，Codex 白名单不接受，故意不收） |

- **顺带修 `mimo-v2.5-pro` 的档位**：实测 `low`/`medium`/`high` 可用（`minimal`/`xhigh`/`max` 400），但配置里只写了 `high` → 已补成 low/medium/high。`mimo-v2.5` 则**什么档位都收**（minimal→max 全 200，等于忽略这个参数），保持 low/high/max 不动；`mimo-v2.5-pro` **不支持图片**（发图 404，models.json 声明 text-only ✓ 本来就是对的）。

顺带一条观察：探测时 **整个 MiMo 家族**的 `/responses` 都是 503（v2.5 / v2.5-pro 同样），而 DeepSeek 200 —— 说明这是 MiMo 只挂在 chat 端点上，不是我们的配置错。

版本 **1.1.11.20 (61)**。

### v1.1.11.19 — 配色改成「只有 Go 配额表里的模型有颜色」+ 不再配置 Zen 模型

- **配色（按你的要求）**：图例、柱子、今日模型条统一按「Go 配额表」分色 —— 表里的模型各自有颜色，**表外的全部合并成灰色「其他」**（`omen-alpha`、`union-alpha`、各种免费 Zen…）。以前它们各占一格，还常被标成"已下架"（比如 `mimo-v2.6-flash` 明明在线却进了那行提示）。
- **内置兜底配额表 28 → 30 行**：补上 `mimo-v2.6-pro`、`mimo-v2.6-flash`、`grok-4.7`，首装/离线时也能正确分色。
- **以后不再配置 Zen 模型（含免费 Zen）**：`model_discovery.py` 默认不再往 `models.json` 写 `*-zen`，并会剪掉已有条目（要临时装回：`OPENCODE_INCLUDE_ZEN=1`）。本机实测 42 → **32 个模型**（30 Go + 2 官方 DeepSeek），旧文件备份在 `~/.codex-deepseek/models.json.bak.*`。
- 记忆管线（记忆提取/合并）跟着从 `mimo-v2.5-free-zen` 换成 `mimo-v2.5-go`（Zen 移除后必须换，否则会指向不存在的模型）。
- 版本 **1.1.11.19 (60)**。

### v1.1.11.18 — 「环境自检」新增运行环境一行（macOS 版本 / 构建 SDK / 最低要求）

- 背景：用户换了 macOS 27 的机器，问"这个软件适配吗"。报告里能一眼看出「系统版本 vs 我们声明的构建 SDK 与最低要求」，不用再猜。
- 现在自检报告第一行是：`运行环境：macOS 26.6.2 (25G83) · 小组件 1.1.11.18 · 构建 SDK macosx26.0 · 最低要求 macOS 14.0`。
- 构建产物也补上了 `DTSDKName` / `DTPlatformVersion`（App 和小组件扩展都有），以后查"这份包是用哪版 SDK 编的"不用再翻构建日志。
- 版本 **1.1.11.18 (59)**。

### v1.1.11.17 — 日常刷新改走官方增量接口（`since=`），一次约 2–3 秒

**全网核对结论（2026-09-22）：「按天 × 按模型」的聚合接口并不存在。**

- 线上控制台 bundle 只暴露 `cost-by-day` / `models` / `summary` / `export` / `go/status`，没有任何 groupBy 或 day-model 聚合；
- 官方公开的 OpenAPI（`opencode.ai/openapi.json`，162 个路径）里**根本没有 usage 相关端点**；
- 生态里最成熟的第三方实现 `xhang1108/opencode-usage`（Chrome 扩展）也是**逐条拉 `rows`（100 条/页）客户端自己聚合**，它的 changelog 明确写着「从已下线的 RSC `/_server` 爬虫迁移到 Console Usage API」——也就是说，老接口确实死透了，大家都只能这么拿。

**但挖到两个官方参数（实测有效）：**

| 参数 | 效果 | 实测 |
|---|---|---|
| `since=<ISO8601>` | **增量**，到边界即停 | `since=05:00` → 只回 108 条；不加 `since` 时同一游标会一路退回前一天 |
| `range=all` | 全量历史（不受 30 天上限） | 第一页与 30d 相同，游标可继续往前 |

日常刷新现在这样走：记下 `lastRowSyncAt`，下次用 `since=上次-2h`（2 小时重叠兜"迟到入库"的行）；没有同步记录、或间隔超过 24 小时，才退回 4×6h 切片。
**实测：118 行 / 2 页 / 2.3 秒**（之前是 24 小时窗口十来页）。

同时复核：UTC 日界之后 **30 天逐天对账 0 差**（没有一天超过 $0.005）。

版本 **1.1.11.17 (58)**。

### v1.1.11.16 — 用量明细「又快又准」：日界改成和官网一样的 UTC

- **修「数字和官网对不上」**：官网 `cost-by-day` 的「天」是 **UTC 日** —— 实测 9/18：UTC 日 = **$0.1242**（= 官网显示值），而我们原来按北京时间切 = **$0.2184**。跨日那 8 小时被算进相邻两天，逐天差 3–8%。现在**统一按 UTC 日**：图表、明细、回填窗口、自然月/账期窗口边界全部同一套日历。实测最近 7 天**逐天 0 差**：

  | 日期 | 我们 | 官网 |
  |---|---|---|
  | 9/16 | 1.5844 | 1.5844 |
  | 9/17 | 2.0916 | 2.0916 |
  | 9/18 | 0.1242 | 0.1242 |
  | 9/19 | 2.1858 | 2.1858 |
  | 9/20 | 1.6165 | 1.6165 |
  | 9/21 | 0.0790 | 0.0790 |
  | 9/22 | 0.4078 | 0.4078 |

- **代价（说清楚）**：凌晨 0–8 点看到的「今日」是 UTC 的今天（= 北京时间昨天 8 点到现在），这样才和官网完全一致。
- **一次性迁移**：首次运行会把本机"旧口径"存下来的数据整体作废重建一次（写 `usageDayConvention=utc` 标记），避免新旧口径混着显示。
- **速度（实测）**：官方接口这几天自己变快了（`rows` 每页 **4–6s → 1–2s**），加上我们已经上了的「合成游标 + 按天并行 + 只抓缺口」：**30 天全量重建 16,922 行 ≈ 1 分钟**（以前 10–17 分钟），日常刷新十几秒。
- 版本 **1.1.11.16 (57)**。

### v1.1.11.15 — 换账号不再串号：设置里新增「清除用量缓存」

- **问题**：刷新是"保留旧天 + 合并新数据"的增量逻辑，所以**退出登录换到别的账号后，上一个账号的历史天会被原样保留在图上**，新账号的数据又并进来 —— 两个账号的用量串在一起（用户问到过这一点）。
- **自动处理**：每次刷新都会用官方 `go/status` 的 `subscriberUserId`（`acc_…`）核对账号；**账号一变，本机用量缓存整个作废**（快照三条通道 + 回填标记），随后按新账号从零重建。cookies 与 Key 不动。
- **手动入口**：设置 →「小组件自检」一排新增 **「清除用量缓存」** 按钮（带二次确认），换账号后不放心就点一下，再回主界面点「刷新」重建。
- 清缓存只删本机这份"历史用量/费用/密钥列表"快照，**不会**动账号、Key 或服务器上的任何数据。
- 版本 **1.1.11.15 (56)**。

### v1.1.11.14 — 补齐用量修复：半截窗口不落盘 + 官方总额归一

打 1.1.11.12 时只做了"别用更小的数据覆盖"，但**回填补明细那条路**还是会拿半截数据盖上去（实测：9/19 被回填写成 $0.41，官方 $2.1858）。这一版补上：

- **回填严格"整窗才算数"**：某一页失败时，这个时间窗的残留行**一律不落盘**（宁可不补，也不要用半天数据冒充整天）；这天保持"缺明细"，下次刷新重抓。
- **官方总额归一到官网口径**：`cost-by-day` 只对**已结算的整天**给总额（今天那份还是 0，所以只对 >0 的天对账）。对账时：
  - 明细比官方少一点点（<10%，属于日界/舍入级别）→ **把各模型等比归一到官方总额**，柱子上的钱与官网完全一致，颜色比例仍来自真实明细；
  - 明细比官方少很多（≥10%，说明只有半天）→ 先按官方总额显示（钱先对），并排队重抓明细。
- **并集自愈不再"用半天顶账"**：`applyUnionDetail`（上次给"纯色自愈"加的那段）以前无条件用"各 Key 明细的并集"替换当天数据 —— 并集只有半天时会把刚对上的官方总额又顶回成 $0.40。现在并集金额明显偏小就拒绝替换；只差一点点（日界/舍入）时按官方总额等比归一，既保钱又拿到颜色。
- **修「套餐生效日期显示成今天」**：官方 `go/status` 的时间戳带毫秒（`2026-10-19T02:02:53.000Z`），默认 `ISO8601DateFormatter` 解析不了小数秒 → 静默退化成"现在 ± N 小时"的兜底值。现在两种格式都试。
- **实测结果**：9/19 从 $0.40 恢复为 **$2.1858（= 官网口径）**、6 个模型有颜色；月额度 **6%**（与官网一致）；到期时间 **10/19 10:02**、周重置 9/21 08:00、5 小时重置 9/21 00:06，全部与官网一致。
- 版本 **1.1.11.14 (55)**。

### v1.1.11.13 — 修「App 卡死/窗口都画不出来」：重签后钥匙串授权框把界面构造卡住

- **症状**：本地重新打包（ad-hoc 重签）后打开小组件，窗口迟迟不出来、"刷新"没反应，桌面上挂着一个钥匙串授权框；实测两个实例的主线程都卡在 `SecItemCopyMatching`。
- **根因**：`Sources/App.swift` 里 `@State private var apiKey = KeychainStore.load()` —— 这行在**视图属性初始化**时就**同步读钥匙串**。每次重签都会让钥匙串里那条 `com.steve233.opencodego.apikey` 的 ACL 失效，macOS 弹授权框等用户点，界面构造于是被阻塞（连 window 都来不及画）。
- **修复**：① 属性初始化不再读盘，改到 `.task` 里；② 读 Key 一律走 `resolvedKey()`，并把顺序改成 **App Group → env 文件 → 钥匙串**（一键配置必写 env，正常路径根本不碰钥匙串）；③ 环境自检里那处直接读钥匙串也一并改掉。
- 版本 **1.1.11.13 (54)**。

### v1.1.11.12 — 修「历史用量偏小」+ 月用量百分比和官网对不上

- **修「明明昨天用了 $2，图上只有 $0.5」**：明细是每次刷新拉最近 24 小时，而 **24 小时窗口只覆盖"边界那天"的一部分** —— 它把这天整天已经存好的明细**覆盖成了晚上那一小段**。实测：9/19 整天（rows 口径）$2.1858，而「19:40 之后」那一段正好 $0.5218，界面就显示成 $0.45。现在三道保险：
  1. 24h 窗口的行数据只在"不少于已存"时才覆盖那天（用量只会累加，明显更少就是半天数据）；
  2. 每次刷新拿官方 `cost-by-day` 的**每日总额对账**：某天明细比官方总额少 5% 以上，立刻改用官方总额显示（**钱先对**），并把这天重新排进"缺明细"队列；
  3. 回填补明细时，允许"新的整天数据更全就替换旧数据"（以前是"有明细就跳过"，所以半天明细永远修不回来）。
- **修「月用量百分比和官网差 1%」**：官网那三个百分比来自控制台 `GET /console/api/go/status`（`usedMicroCents / limitMicroCents` **四舍五入**），而我们在用的是网关 `/zen/go/v1/usage`，它是**向下取整** —— 实测 5.72%：官网显示 6%、网关给 5%。现在优先用控制台官方口径，网关只做兜底；月度的重置时间改用订阅周期 `access.endsAt`（网关那个接口压根不给月度 resetsAt）。
- 版本 **1.1.11.12 (53)**。

### v1.1.11.11 — Muse Spark 兼容层（依据 muse-codex-compat）

**背景**：Muse Spark（Meta 后端，走 opencode Zen/Go）的 tool-schema 校验与 tool-call 流式行为和同网关的 DeepSeek / GLM / MiMo 都不一样 —— 同一份 Codex payload，只有它会挂：`400 Invalid JSON schema`、`400 Recursive JSON schemas are not currently supported`、工具名带点号导致 Codex 报 `unsupported call`、以及"只写「马上改」却不调用工具"的空转。

**代理里新增的改写（全部只对 `muse-spark*` 生效，其他模型 payload 字节不变）**：

1. **修空 schema stub**：Codex 给延迟工具发的 `{"type": {}, "description": {}}` 非法 → 修成 `string`（只走 schema 语义子键，不会误伤名字就叫 `description` 的属性）。
2. **本地 `$ref` 就地展开**：Meta 不支持递归 schema；展开后爆量（>3 倍且 >200 KB）就放弃这次改写，宁可不修也不撑爆请求。
3. **工具 schema 嵌套砍到 8 层**（实测第 9 层起必拒）。
4. **`strict` 保险放松**（实测不是根因，属廉价保险）。
5. **响应侧拆点号工具名**：`multi_agent_v1.spawn_agent` → `name=spawn_agent` + `namespace=multi_agent_v1`，流式和非流式都做。
6. **空转兜底**：请求尾补「要么调用工具、要么给最终答复」的硬约束（`instructions` + `input` 末尾各一条）；流式响应先缓冲判断，确实空转就用同一份请求体重发（最多 2 次，同一份响应 2 分钟 6 次熔断），最后一次不管怎样都原样发给客户端，绝不把调用方吊着。

**开关**（写在 `~/.config/agent-vision-toolkit/env`，不改代码就能关）：
`VISION_PROXY_MUSE_SCHEMA_FIX` / `VISION_PROXY_MUSE_NO_PREAMBLE` / `VISION_PROXY_MUSE_STALL_RETRY` / `VISION_PROXY_MUSE_TOOLNAME_FIX`

**验证**：13 项离线断言全过（Muse 命中、非 Muse 字节不变、空转判定不误判回显的 instructions），实机 Muse / DeepSeek / GLM 请求各一条均 200，非 Muse 日志无任何 muse 改写行。

**注意**：Muse 的流式响应现在会先缓冲再吐（要判断是否空转），所以它表现为"想完一次性出现"，不再逐字流式。另外 `muse-codex-compat` 技能（探针脚本 + 离线测试 + 实测限制清单）已一起放进 App 包的 `skills/` 目录。

版本 **1.1.11.11 (52)**。

### v1.1.11.10 — 修「别的电脑点配置失败、日志停在半路」（zsh glob 静默杀脚本）

- **症状**：新机器上点「配置」，日志停在「无需同步：…（内容一致）」那一行就没下文了，只显示「上次配置失败」，**一句错误都没有**。
- **根因**：安装器是 zsh 脚本，而 zsh 默认 `nomatch` —— 只要有一个 **glob 匹配不到任何文件，整个脚本立刻退出（status 1）**，且只往 stderr 吐一句 `no matches found`。脚本里有一行是「如果装了 python.org 的 Python，就跑一次 Install Certificates 修证书」：机器上**没装 python.org Python 时这条 glob 不匹配 → 脚本当场死掉**，后面的本地代理、模型发现、副本重建全都没执行。用同样的路径复现：老脚本 `:694: no matches found …` 退出码 1，日志正好停在那一行。
- **修复**：脚本开头 `setopt null_glob`（匹配不到就当空列表，跳过而不是死掉）；另外把「失败 rollout 归档」那处的 `*.archived-*.jsonl` 一起保护（空目录同样会触发这个坑）。
- **顺手加保险**：退出码非 0 时脚本自己补一句 `ERROR: 配置脚本异常中断（退出码 N）`，以后不会再有"日志戛然而止、查不出原因"的情况。
- 版本 **1.1.11.10 (51)**。

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
