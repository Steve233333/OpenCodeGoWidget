---
name: codex-patched-maintenance
description: 维护 ChatGPT 桌面版 DeepSeek 双开副本（ChatGPT-Patched.app）。涵盖：版本升级流程（官方更新后重建副本、新版 asar 中定位已变更的 patch pattern）、签名与 entitlements 维护（自签证书 Codex Patched Signing、ent2.plist）、CODEX_HOME 数据隔离、launchd 自动更新、常见故障（CUAService bootstrap failed、Appshot -10000 AppleEvent 认证、TCC 授权丢失、Zen 网关 tools[N].function missing field name 400）排查。Use when 用户提到 ChatGPT-Patched、副本、双开、picker-patch、补丁重建、26.810 升级、appshot 无法附加、智能快照失败、CUAService、bootstrap failed、tools missing field name、Zen 报错 400、codex 副本维护。
---

# ChatGPT-Patched 副本维护手册

## 架构总览

```
 /Applications/ChatGPT.app                    官方版（纯 GPT 会员，登录官方账号；当前 26.825.51511，旧 26.820.80927 备份于 /Library/Project/ChatGPT-26.820.zip）
~/Applications/ChatGPT-Patched.app          副本（DeepSeek，26.825.51511 单行补丁，旧 26.820.80927 可回滚）
~/.codex-deepseek/                          副本的 CODEX_HOME（会话/登录/记忆全隔离；models.json 33 个，DeepSeek+Muse 置顶 7 个同系列抱团）
~/Library/Application Support/Codex-Patched 副本的 Electron userData（界面缓存/登录态）
~/.codex/picker-patch/                      patch 工程（脚本/证书/备份，git 仓库）
~/Library/LaunchAgents/com.steve233.codex-picker-patch.plist  launchd 每小时自动检查更新
```

副本通过 7 层定制实现双开与 DeepSeek 接入：
1. **asar 单字节 patch**：模型可见性过滤改为不按 availableModels 过滤（DeepSeek 自定义模型不被隐藏）
2. **picker 单行补丁（26.825 新增）**：`app-initial-B6Gk5KCN.js` 的 `cmi`/`lz` 两处 `allowWrap?whitespace-normal:truncate` 改 `truncate` 单行 `…` + `itemBase` 改回 `26.820` 的 `rounded-lg`（见 §24）
3. **Sparkle 更新禁用**：feed URL 改写为 invalid.invalid + SUEnableAutomaticChecks=false
4. **CODEX_HOME 隔离**：Info.plist 的 LSEnvironment 注入 `CODEX_HOME=~/.codex-deepseek`
5. **Electron userData 隔离**：主可执行文件包装为 C 写的 Mach-O launcher（`launcher.c`），注入 `--user-data-dir=~/Library/Application Support/Codex-Patched`
6. **唯一 bundle id**：`com.steve233.codex-patched`（与官方 `com.openai.codex` 并存）
7. **稳定重签**：自签证书 `Codex Patched Signing` + `certs/ent2.plist` entitlements（TCC 授权跨重建保持）

## 关键路径清单

| 项 | 路径 |
|---|---|
| 本体 | `/Applications/ChatGPT.app` |
| 副本 | `~/Applications/ChatGPT-Patched.app` |
| patch 脚本 | `~/.codex/picker-patch/patch.sh` |
| 工程 git | `~/.codex/picker-patch/`（main 分支） |
| 证书 | `~/.codex/picker-patch/certs/codex-sign2.{crt,key,p12}` |
| entitlements | `~/.codex/picker-patch/certs/ent2.plist` |
| 签名身份 | `Codex Patched Signing`，keychain `~/Library/Keychains/codex-signing.keychain-db`（密码 0000，p12 密码 codex123，openssl 导出需 `-legacy`） |
| 副本 CODEX_HOME | `~/.codex-deepseek/`（含 sessions、state_5.sqlite、auth.json、config.toml、models.json） |
| 副本 userData | `~/Library/Application Support/Codex-Patched/` |
| 备份 | `~/.codex/picker-patch/backup/`（app.asar、Info.plist、官方 config.toml） |
| launchd plist | `~/Library/LaunchAgents/com.steve233.codex-picker-patch.plist` |
| 运行日志 | `~/.codex/picker-patch/patch.log`；app 日志 `~/Library/Logs/com.openai.codex/2026/MM/DD/codex-desktop-*.log` |

## 常用命令

```bash
~/.codex/picker-patch/patch.sh --install       # 若未 patch 则重建并启动副本
~/.codex/picker-patch/patch.sh --auto-update   # launchd 每小时调用：版本变了且副本未运行 → 重建
~/.codex/picker-patch/patch.sh --status        # 查看本体/副本版本、marker、agent 状态
~/.codex/picker-patch/patch.sh --uninstall     # 杀副本、删 bundle、卸 launchd（不动 CODEX_HOME）
```

版本标记：`~/.codex/picker-patch/patch-state.json`（`sourceVersion` 为构建时本体版本）。

## 版本升级流程（核心）

官方版每次更新后（`/Applications/ChatGPT.app` 版本号变化），launchd 会在副本未运行时自动重建。若自动重建失败，或需要手动升级：

1. **确认副本已退出**（`pgrep -f ChatGPT-Patched`），否则脚本拒绝重建
2. **核对新版 asar 中 patch pattern 是否仍唯一存在**：
   ```bash
   grep -aboF 'i.useHiddenModels&&r!==' /Applications/ChatGPT.app/Contents/Resources/app.asar | wc -l   # 必须 = 1（26.820 旧）；26.825 已改为正则 useHiddenModels&&[^`]*!==`amazonBedrock`
   grep -aboE 'useHiddenModels&&[^`]*!==`amazonBedrock`' .../app.asar | wc -l                           # 26.825 必须 = 1
   grep -aboF 'https://persistent.oaistatic.com/codex-app-prod/appcast.xml' .../app.asar | wc -l        # 必须 = 1（feed URL）
   ```
3. **若 pattern 变更**（上游重构代码），按此方法定位新 pattern：
   - 旧语义：模型可见性过滤——`authMethod!=='amazonBedrock' ? availableModels.has(...) : !hidden` 这类条件
   - 用 `grep -aboE 'amazonBedrock'` 找到全部出现点，逐个 `dd if=asar bs=1 skip=<off-120> count=300 | strings` 看上下文
   - 找到"过滤函数"里条件式的 `!==`，把 `PATTERN`/`PATCH_FROM`/`PATCH_TO`/`is_patched` 校验串同步更新（patch.sh 顶部有注释说明 26.810 的迁移例子；26.825 变量改名 `a.useHiddenModels&&i!==` 见 §24）
4. **同步检查 picker 单行补丁**（26.825 新增，见 §24）：
   ```bash
   grep -aboF 'g=u?`whitespace-normal`:`truncate`' .../app.asar | wc -l     # 若 =1 需改回单行（否则 33 个长名必叠）
   grep -aboF 'itemBase:`outline-hidden flex min-h-[var(--menu-item-height' .../app.asar | wc -l  # 同
   ```
   需 `asar extract → 改 app-initial-B6Gk5KCN.js → asar pack → codesign`（patch.sh 未内置，见 §24）
5. **运行 `patch.sh --install`**，观察日志中 `pattern ... patched`、`re-signed`、`marker written` 三行
6. **验证**：
   ```bash
   defaults read /Applications/ChatGPT.app/Contents/Info.plist CFBundleShortVersionString   # 与副本应一致（当前 26.825.51511）
   codesign --verify --deep --strict ~/Applications/ChatGPT-Patched.app
   codesign -d --entitlements :- ~/Applications/ChatGPT-Patched.app/Contents/MacOS/ChatGPT.bin  # 应含 application-groups 等
   log show --last 3m --predicate 'eventMessage CONTAINS "bootstrap failed"'   # 应为空
   open ~/Applications/ChatGPT-Patched.app && sleep 2 && python3 -c "import json;print(len(json.load(open('/Users/steve233/.codex-deepseek/models.json'))['models']))"  # 33 个且下拉不叠
   ```
7. **git commit** 记录 pattern 变更（在 `~/.codex/picker-patch/`）

**注意**：数据不会丢。重建只删 `~/Applications/ChatGPT-Patched.app`（纯程序文件），CODEX_HOME 与 userData 都不碰。models.json 33 个（DeepSeek+Muse 置顶）需另行备份 `~/Desktop/models.json.bak.*`，重建后若被重置用备份贴回。

**备用官方包**：`/Library/Project/ChatGPT-26.820.zip`（588709155 bytes，26.820.80927）可回滚双端：`cp -R /tmp/old-26.820/ChatGPT.app /Applications/` + `patch.sh --install` 即回单行不叠。

## 签名与 entitlements

- 签名身份：自签证书 `Codex Patched Signing`（RSA2048，10 年，OU=2DC432GLL2）。签名大小 1792（无 entitlements）/1855（带 ent2.plist）
- **为什么不用 ad-hoc**：ad-hoc 的 CDHash 每次重建都变，TCC 授权（屏幕录制/辅助功能）每次都要重新手动授权
- 证书信任：已加入系统信任（`security add-trusted-cert -r trustRoot -p codeSign ...`，系统域），gatekeeper 仍会 reject（无公证，预期内）
- ent2.plist 内容（重建时用 `--entitlements` 注入，缺了会导致 CUAService bootstrap failed）：
  - `com.apple.security.application-groups`: `2DC432GLL2.com.openai.codex.notifications`、`2DC432GLL2.com.openai.sky.CUAService`
  - `com.apple.security.automation.apple-events` = true
  - `com.apple.security.cs.allow-jit`、`com.apple.security.cs.allow-unsigned-executable-memory`、`com.apple.security.network.client`
- 完整官方 entitlements **不可用**：`com.apple.application-identifier=2DC432GLL2.com.openai.codex` 与副本 bundle id 冲突 → launchd spawn 失败（RBSRequestErrorDomain Code=5 / NSPOSIXErrorDomain Code=163）
- 签名前需解锁 keychain：`security unlock-keychain -p 0000 ~/Library/Keychains/codex-signing.keychain-db`

## 常见故障排查

### 1. CUAService bootstrap failed（智能快照/Computer Use 启动失败）
症状：日志 `RemoteHostedPIPContent CUAService bootstrap failed: Code=-10000`；trustd 报 `Entitlement ... is ignored because of invalid application signature or incorrect provisioning profile`。
根因：重签丢了 `application-groups` entitlements。
修复：用 `certs/ent2.plist` 重签（见上）。不要用完整官方 entitlements。

### 2. Appshot 无法附加智能快照（已知限制，-10000 AppleEvent）
症状：双击 Command → "无法附加智能快照"。日志：`Codex Computer Use Apple Event error -10000: Sender process is not authenticated`，`failureReason=start_request_failed:computer_use:-10000`。
根因：macOS Apple Events TCC 认证检查 **responsible process（启动链）**的 automation entitlement。副本主进程 ChatGPT.bin 是自签（无 provisioning profile），trustd 判其 entitlements 无效，即使证书被系统信任、即使 CUAService 本身是官方签名也无效。**这是自签架构的固有限制**，改信任设置、重启 tccd、手动加权限均无效。官方版正常是因为它是 Developer ID + 公证签名。
已知缓解尝试（均无效）：系统域信任设置、重启 tccd、删除重加屏幕录制/辅助功能授权。
注意：官方社区 openai/codex issue #18507/#19544/#28250 有同款错误，官方版也会偶发。

### 3. TCC 授权丢失（屏幕录制/辅助功能）
原因：重建后 CDHash 变化（若用了 ad-hoc）或签名身份变化。
修复：系统设置 → 隐私与安全性 → 屏幕录制/辅助功能，删除旧条目重新添加 `~/Applications/ChatGPT-Patched.app/Contents/MacOS/ChatGPT.bin`（或直接用证书签名避免此问题）。

### 4. 副本启动后被替换/无法打开
- 检查 `~/.codex/picker-patch/patch.log` 最后几行
- 检查签名：`codesign --verify --deep --strict ~/Applications/ChatGPT-Patched.app`
- 若 quarantine 属性：`xattr -dr com.apple.quarantine ~/Applications/ChatGPT-Patched.app`

### 5. 日志在哪看
- patch 脚本日志：`~/.codex/picker-patch/patch.log`
- app 主进程日志：`~/Library/Logs/com.openai.codex/2026/MM/DD/codex-desktop-<uuid>-<pid>-t0-i1-*.log`，搜索 `Appshot`、`computer-use-capture-handler`、`error`
- 系统侧：`log show --last 3m --predicate 'eventMessage CONTAINS "CUAService"'`
- 副本会话数据：`~/.codex-deepseek/sessions/`、`state_5.sqlite`、`~/Library/Application Support/Codex-Patched/Default/Local Storage/leveldb/`

### 6. Zen 网关 400：tools[N].function: missing field 'name'（web_search 工具）
症状：Codex 副本发消息即报 `Error from provider (Console): Upstream request failed: [invalid_request_error] Failed to deserialize the JSON body into the target type: tools[N].function: missing field name`（N 为工具序号，如 14）。
根因：models.json 中模型 `supports_search_tool=true` 时，Codex 会自动附加 `web_search` 工具（Responses API 里它是非 function 工具，`{"type":"web_search",...}` 无 `name` 字段）；opencode.ai Zen/Go 网关把所有工具统一转成 `{"type":"function","function":{...}}`，web_search 转换后 `function.name` 缺失 → 上游 serde 反序列化失败 → 整个请求 400。
- 官方 DeepSeek 直连**不受影响**（官方端点正确处理 web_search 工具）；问题只发生在 opencode.ai 网关路径（Zen 免费和 Go 付费共用网关，**Go 同样中招**）
- 参考：anomalyco/opencode issue #42090（Go deepseek-v4-pro 同款，已指派官方）、PR #40210（修复未覆盖 responses 路径）
- 修复：models.json 中对应模型条目 `supports_search_tool=false` 并**删除** `web_search_tool_type` 字段（留 true 才报错）。已修复：deepseek-v4-flash-free-zen、hy3-free-zen、mimo-v2.5-free-zen（2026-08-18）；官方 deepseek-v4-flash/pro 保持 true
- 影响：模型失去内置联网搜索（DeepSeek 系本就不可用，无实际损失）；改完重启 Codex 会话生效，无需动 proxy
- 教训：未来接入 Zen/Go 新模型时，默认 `supports_search_tool=false` + 无 `web_search_tool_type`，除非该模型在 Go 网关走原生 responses 路径（deepseek-* 已确认支持，见故障 9）

### 7. Go 订阅模型接入（2026-08-18 完成，2026-08-22 扩至 14 模型：Vision Exp）
- proxy 路由：`GO_SUFFIX="-go"`、`GO_UPSTREAM="https://opencode.ai/zen/go"`、`_rewrite_go_model()` 剥离后缀、请求分支 `go_route` 用 Go 端点 + ZEN_API_KEY（vision_proxy.py 顶部常量区）；新增 `NATIVE_VISION_MODELS={"deepseek-v4-flash-vision-exp","deepseek-v4-flash-vision-exp-go"}`，`handle()` 中命中则跳过 `_rewrite_image_inputs` 直通原生视觉
- models.json **现有 14 个模型**（2026-08-22，无 Zen 免费：官方 deepseek-v4-flash-vision-exp/pro + Go 12 个 —— deepseek-v4-flash/pro-go、deepseek-v4-flash-vision-exp-go、mimo-v2.5/pro-go、glm-5/5.1/5.2/5.3-go、gpt-5.6-luna-go、muse-spark-1.2-contributor-go、ox-alpha-go 限时）。`supports_search_tool`：官方 Vision Exp/pro、deepseek-v4-flash/pro-go、deepseek-v4-flash-vision-exp-go、gpt-5.6-luna-go、muse-spark-1.2-contributor-go = true，其余 7 个（mimo/glm/ox-alpha）= false；`tool_mode` 全部 null
- 已删除（2026-08-18 精简）：hy3-free-zen、kimi-k2.7-code-go、kimi-k2.6-go、minimax-m2.7-go、grok-4.5-go（注：hy3-go 于 2026-08-21 按原生 responses 重新接入，见 §19，不再属删除列）
- 曾实测不可用已移除：qwen3.x 全系+minimax-m3/m2.5+kimi-k3（anthropic-only，responses wire 401 "not supported for format openai"）、mimo-v2-pro/omni（404 已下架）、kimi-k2.5（503 端点不可用）（注：gpt-5.6-luna 原 403 已于 2026-08-20 经 VPN 复测 200 并接入见 §13；hy3-preview 原 400 已于 2026-08-21 复测可用但仅作拦截见 §19）
- 推理档位：Go 网关对 reasoning.effort 全兼容（mimo 三档实测均 200），配置按 models.dev 官方能力裁剪即可
- **默认模型**：config.toml `model = "deepseek-v4-flash"`（2026-08-18 起改回官方直连；此前为 deepseek-v4-flash-go，再此前 glm-5.3-go；mimo-v2.5-go 有 SSE 兼容修复后可切回，见故障 8；备份 config.toml.bak.*）
- **2026-08-18 全量核对**：8 个 Go 模型用带 assistant 历史消息的完整请求重放，全部 HTTP 200 且正常输出（mimo 232 字、glm-5.2 10 字+工具、glm-5.1 22 字+工具、glm-5.3 152 字、glm-5 310 字、mimo-pro 232 字、flash 148 字、pro 215 字）；官方直连 200；Zen 免费模型 429（限流，非不可用）（2026-08-21 已删 Zen 模型，当前 12 个 Go 模型均 200，见 §18/19）

### 8. Go 网关 chat 适配模型 SSE 事件缺失（mimo/glm/kimi/hy3"完成但无文本"）
症状：Codex 里选 mimo-v2.5-go（及 glm/kimi/hy3 系）发送后，UI 显示完成但**没有任何回复文本**；deepseek-v4-flash-go/pro-go 正常。
根因：Go 网关对 chat 系模型走 chat→responses 适配路径，返回的 SSE 流**缺标准 Responses 事件**：无 `response.created`/`in_progress`，`output_text.delta` 和 `function_call_arguments.delta` 无 `item_id`/`output_index`（用 curl 重放可见事件只有裸 delta+completed+ping）。Codex 客户端无法把文本挂到输出项上 → 静默丢文本。flash/pro 是原生 Responses 协议模型，事件完整，故正常。
修复：proxy 新增 `_complete_sse_frame()`（vision_proxy.py），在 `_rewrite_sse_frame`（apply_patch 桥）**之前**对每帧做协议补全：
- 流缺 `response.created` 时合成 `response.created`+`response.in_progress`（序列号自增）
- 首个 `output_text.delta` 前合成 message 的 `output_item.added`+`content_part.added`，delta 补 `item_id`/`output_index`/`content_index`
- 首个 `function_call_arguments.delta` 前合成 function_call 的 `output_item.added`（若无上游帧），delta 补 `item_id`
- `response.completed`/EOF 时合成 `output_text.done`+`content_part.done`+`output_item.done` 收尾
- 流自带 `response.created`（flash/pro/官方直连）则完全透传，零改动；任何解析异常 fail-safe 转发原帧
- 验证：curl 重放 mimo/glm/kimi 请求，事件序列已完整（created→item.added→delta(带item_id)→done→completed），flash 对照流事件数与修复前一致
- 教训：chat 适配模型在 Codex 里不可直接使用，全靠该补全层兜底；新增此类模型接入后务必重放验证事件序列

### 9. web_search 剥离仅限 Zen/Go 路由（2026-08-18，17:00 起细化）
- 故障 6 的 `_strip_web_search_tool(parsed, model, go_route)` 必须**只在 zen/go 路由调用**（`ws_changed = (zen_changed or go_changed) and _strip_web_search_tool(parsed, model, go_changed)`）；无条件调用会误伤官方 DeepSeek 直连
- **2026-08-18 细化：Go 网关已把 deepseek-v4-flash/pro 切到 DeepSeek 原生 /v1/responses（PR #40210 注释，2026-08-05 上线），原生路径接受 web_search 并真实执行**（直连 Go 网关实测：flash/pro 带 web_search 均 200，flash 实际触发 3 次 web_search_call 联网）。因此剥离条件改为**仅保留「Go 付费路由 + deepseek-* 模型」的 web_search**（`go_route and model.startswith("deepseek-")` 则跳过剥离）；Zen 免费层和 mimo/glm/kimi/hy3 等 chat 适配模型仍必须剥离（免费层和 oa-compat 转换路径仍 400）
- **已恢复搜索**：models.json 中 deepseek-v4-flash-go、deepseek-v4-pro-go 设 `supports_search_tool=true` + `web_search_tool_type="text"`（2026-08-18，备份 models.json.bak.20260818202314）；Codex 客户端会为它们附加 web_search 工具，proxy 放行 → 可联网
- 上游修复状态（截至 2026-08-18）：PR #40210（SSE 补全+剥离非 function 工具）仍 Open 未合并；PR #42231（同修复）因缺 issue 链接被 bot 自动关闭；issue #42090 已指派 fwang。**mimo/glm 等 chat 适配模型的搜索需等上游**，代理无法模拟模型侧内置搜索
- 验证方法：`curl http://127.0.0.1:19100/v1/responses` 带 `{"type":"web_search","external_web_access":true}` 工具，flash-go 应 200 且响应含 `web_search_call` 事件；mimo-go 应 200（工具被剥离）且无 `web_search_call`

### 10. Go 网关 400：assistant 消息 content 数组（2026-08-18）
症状：同一会话第一条消息正常，**换新聊天后** Codex 报 `[400] Provider returned error`（mimo/glm/kimi/hy3 等 chat 适配模型）。
根因：Codex 回传的 assistant 消息 content 是**数组**（`[{"type":"output_text","text":...}]`，标准 Responses 格式）；Go 网关把这些模型转 chat 格式时，assistant content 数组无法映射到 chat schema → 整请求 400。第一个聊天里没有 assistant 历史消息所以正常；换新聊天后带上历史回复就炸。deepseek-v4-flash/pro-go 与官方直连是原生 Responses，接受数组不受影响。
定位方法：proxy 请求 dump 后二分 input——含 assistant 消息（role=assistant + content 数组）即 400；content 改字符串或 role 改 user 即 200。
修复：proxy 新增 `_normalize_assistant_content()`（vision_proxy.py），对 zen/go 路由把 assistant 消息 content 数组拼接成纯字符串（原生模型接受两种形式，无副作用）。
教训：新增 chat 适配模型时，验证用例必须包含「回传 assistant 消息」的场景（第二条消息），只测单条消息会漏掉此 bug。

### 11. 带图片聊天 mimo 400 = 故障 10 同根因（2026-08-18 排查结论）
症状：mimo-v2.5-go 在**带图片的聊天**里报 400，纯文本正常；deepseek-v4-flash-go 和 glm-5.2-go 带图片正常。
排查过程（耗时点，勿重复）：先怀疑图片聊天独有的输入结构——在重放 payload 里插入标准 `reasoning` item、`function_call`+`function_call_output` item（view_image 工具调用历史）以及两者组合，curl 重放**全部 200**，排除标准结构嫌疑；models.json 条目对比（input_modalities 均含 image、其余字段一致）也无差异。
最终结论：**仍是故障 10 的 assistant content 数组**——图片聊天轮次多、历史里必然带 assistant 消息数组，触发概率远高于纯文本；proxy 修复已部署但 Codex 客户端未重启（旧请求仍走旧构造路径），**重启 Codex 客户端后正常**，无需新代码。
教训：proxy 修复后若用户仍报错，先让用户重启 Codex 客户端再排查；图片聊天 400 不必再造新 dump，直接归因 assistant content 数组。

### 12. 官方 DeepSeek 联网历史切 Go 模型 400：web_search_call action 格式不兼容（2026-08-19 修复）
症状：用官方 DeepSeek（默认模型，supports_search_tool=true）联网搜索后，同一会话切到 Go 模型（deepseek-v4-flash-go/pro-go）即报 `[400] Provider returned error`；新开窗口正常。
根因：官方 DeepSeek 联网后历史里含 `web_search_call` item，其 `action.type="web_search"`（OpenAI 官方格式）。Go 网关 **deepseek 原生 responses 路径**只接受 `action.type ∈ {search, open_page, find_in_page}`，官方 `web_search` 触发 `input: unknown variant 'web_search'` 400。mimo/glm 等 chat 适配路径不受此限制（但 history 走 proxy 的 `_normalize_assistant_content` 修复后正常）。
定位方法：直连 Go 网关 `https://opencode.ai/zen/go/v1/responses` 重放带 `web_search_call` 的历史，二分 action 变体——`web_search`→400；`search`+`queries`（字符串数组）→200；`open_page`+url→200；空 output 或简化为单 item 不触发（需多轮完整历史才能复现）。
修复：proxy 新增 `_normalize_web_search_call(parsed)`（vision_proxy.py），对 zen/go 路由把 `action.type=="web_search"` 改写为 `{"type":"search","queries":[item.search_query 或 action.query 或 "search"]}`，output（搜索结果）原样保留；已是 search/open_page 的不动。接入调用链：`wsc_changed = (zen_changed or go_changed) and _normalize_web_search_call(parsed)`。
副作用：仅搜索词可能兜底为 "search"（搜索结果正文保留），实际影响可忽略；官方直连/纯文本不受影响。
验证：单测 4 种 case + 端到端 flash-go/mimo-go 带官方 ws 历史均 200（备份 vision_proxy.py.bak.20260819142412）。

## 回滚

- 从 git 恢复脚本：`cd ~/.codex/picker-patch && git log --oneline`，找到旧 commit 后 `git checkout <commit> -- patch.sh`
- 备份的官方原始文件：`~/.codex/picker-patch/backup/`（app.asar、Info.plist、config.toml.official-gpt-rollback）
- 卸载副本：`patch.sh --uninstall`（只删 bundle 和 launchd，不动数据）
- 官方版恢复纯 GPT：`cp ~/.codex/picker-patch/backup/config.toml.official-gpt-rollback ~/.codex/config.toml`

## 环境事实备忘

- macOS：darwin（Apple Silicon）；证书 p12 需 `-legacy`（openssl 3.x）
- 副本 models.json：`~/.codex-deepseek/models.json`（33 个：官方 deepseek 1 个 + Go/Zen 32 个；supports_search_tool：`✓ 9 个`（`deepseek-v4-pro, deepseek-v4-pro-go, deepseek-v4-flash-go, deepseek-v4-flash-vision-exp, deepseek-v4-flash-vision-exp-go, gpt-5.6-luna-go, muse-spark-1.2-contributor-free-zen/go, grok-4.6-go`），`✗ 24 个`（`glm×4, kimi×3, qwen×5, hy×2, mimo×3, minimax×2, longcat, ling, nemotron×2, big-pickle`），见 §7/13/14/18/27/28）
- models.json **排序规则**（2026-08-18 三次整理，2026-08-22 Vision Exp 置顶/插入，Codex 选择器按此顺序显示）：官方 Vision Exp/pro → Go 的 deepseek（flash-go、vision-exp-go、pro-go）→ Go 的 mimo（v2.5-go、mimo-v2.5-pro-go）→ Go 的 glm（5.3/5.2/5.1/5-go 版本倒序）→ Ox Alpha (Go) 限时
- **排序由 `priority` 字段决定**（教训：只改 models.json 数组顺序无效，Codex 客户端按 priority 升序稳定排序，同值按数组顺序）：14 个模型已设为 1–14 与目标顺序一致；重排时数组顺序和 priority 必须同步改，备份 models.json.bak.20260821173828.before-hy3
- 视觉代理：launchd 常驻 `com.agent-vision-toolkit.proxy`（端口 19100），DeepSeek 上游转发（另有 codex-vpn-502-fix skill）
- sudo 密码：0000（本机）

### 13. Go 新增 GPT-5.6 Luna / Muse Spark 1.2 Contributor（2026-08-20）
- 背景：用户要求接入便宜且原生 `openai-responses` 的 Go 模型。Luna（OpenAI，1.05M 上下文，$0.20/$1.20，`grok-4.5` 同级原生 responses）与 Muse Contributor（Meta，1M 上下文，$0.10/$0.20，数据用于改进模型）均走 `https://opencode.ai/zen/go/v1/responses`，pi.dev 确认 `sessionAffinityFormat=openai-nosession`，理论完美兼容 Codex
- 核对：Luna 初始 403 大陆封锁（需 VPN 全局 TUN），Muse 初始 403 `requires explicit opt in`（需 https://opencode.ai/workspace/wrk_01KT9VX0KZCD5SYNXH8D3EYJD8/go 同意数据采集）。Luna 经 VPN 复测 200，Muse opt in 后 200
- 接入：`models.json` 新增 `gpt-5.6-luna-go`（priority 5，context 1050000，reasoning low/medium/high/xhigh/max 五档）与 `muse-spark-1.2-contributor-go`（priority 6，context 1048576，reasoning low/medium/high/xhigh 四档，无 minimal/max），插于 `deepseek-v4-pro-go` 之后，其余 priority 顺延至 14；`config.toml` 默认模型切至 `deepseek-v4-flash-go/high`（用户指定）
- 联网：`vision_proxy.py:_strip_web_search_tool` 白名单从 `deepseek-*` 扩至 `("deepseek-","gpt-5.6-luna","muse-spark-1.2")`，`models.json` Luna/Muse 设 `supports_search_tool=true` + `web_search_tool_type="text"`
- 额度：Muse Contributor 最便宜但 Go 额度表未列；按 $0.10/$0.20 估算月约 15 万次（同 MiMo-V2.5 量级）

### 14. Go 网关 Luna/Muse 400 三连击与修复（2026-08-20，vision_proxy.py）
- **阶段1 `colon` 非法**：Luna 报 `Invalid 'input[5].id': 'rs_aaa:rs_bbb' Expected ^[a-zA-Z0-9_-]+$`。根因 Codex 回放 `rs_*:rs_*` 推理 ID 含 `:`。初修 `_sanitize_input_ids` 将 `:`→`_`，触发下一阶段
- **阶段2 `encrypted_content` 验签失败**：改 ID 后 Luna 报 `encrypted content could not be verified`，Muse 同款。根因密文与原始 ID 绑定，改 ID 即验签失败。改修：Go 路由下 `":" in id` 的 `input` 项剥离 `encrypted_content` 再改 ID
- **阶段3 `Item not found (store=false)` / `limit` 缺失**：剥离后 Luna 报 `Item rs_aaa_rs_bbb not found. store=false`，且 Luna/Muse 同报 `'required' Missing 'limit'`（工具 schema 严格校验：`properties` 含 `limit` 则 `required` 必须含 `limit`，DeepSeek 宽松但 Luna/Muse 严格）
- **最终修复（选 B：Go 全量但仅 Luna/Muse 触发）**：
  - `_sanitize_input_ids` 改为**直接丢弃** `id` 含 `:` 或 `id.startswith("rs_")` 的 `input` 整项（实为 Luna 专用，Muse/DeepSeek/mimo/glm 不产 `rs_*` 不触发；丢一条推理历史 vs 400 可接受）
  - 新增 `_fix_tool_required`：Go 路由下若工具 `parameters.properties` 含 `limit` 则补 `required` 含 `limit`（缺数组则补全 `properties` 全量）
  - 副作用：丢一条推理上下文、工具 `limit` 变必选；均仅 Go 路由，官方直连不受影响
- 教训：`rs_*` 推理密文与 `store=false` 语义在 Go 网关与 OpenAI 官方行为不一致，代理层需按模型家族区分严格度

### 15. Muse 推理档位核对（2026-08-20）
- pi.dev 官方：Muse 支持 `minimal/low/medium/high/xhigh`（`max` 不支持）；Luna 支持 `low/medium/high/xhigh/max`
- Codex 侧 `enabled-reasoning-efforts` 无 `minimal`，故 Muse 建模仅列 `low/medium/high/xhigh` 四档，Luna 五档已对齐

### 16. 跨模型长历史复用与 DeepSeek→Muse `query` 缺失（2026-08-20）
- 症状：DeepSeek 长会话（`input[670]`）切 Muse 报 `input[670].action missing required field query`。直接用 Muse 不报错，仅 DeepSeek 670 项历史→Muse 触发
- 根因：DeepSeek 历史 `web_search_call.action` 为 Go 定制 `{"type":"search","queries":[...]}`（仅 `queries` 数组），Muse 经 Go 严格校验 `query: string` 必选。`_normalize_web_search_call` 原仅 `web_search→search+queries` 单向，未补 `query`
- 修复：`vision_proxy.py:_normalize_web_search_call` 升级为**双字段兜底**——对所有 `web_search_call` 的 `action`，缺 `query` 则 `query=queries[0]`，缺 `queries` 则 `queries=[query]`，两者皆缺则 `query="search"`+`queries=["search"]`；保留 `web_search→search` 转换。Go 全量但实为跨模型历史触发，非长历史日常不触发
- 关联：同日新增拦截策略（见 §17），与本双字段修复互补：前者保跨 `search=true` 家族互通，后者保 `search=true→false` 不静默丢弃

### 17. `search=true 历史 → search=false 模型` 拦截与记忆模型切换（2026-08-20，用户选“拦截并提示”；2026-08-21 同步 ox-alpha/hy3）
- 背景：跨模型审计（14 模型）发现 `search=true(6个: 官方 DeepSeek×2 + deepseek-v4-flash/pro-go + luna/muse)` → `search=false(8个: mimo×2/GLM×4/ox-alpha/hy3)` 长历史复用必 400；用户要求**不静默丢弃 `web_search_call`，改为拦截提示新开会话**
- 实现：`vision_proxy.py` 新增 `_SEARCH_FALSE_MODELS`（`mimo-v2.5/pro, glm-5/5.1/5.2/5.3, ox-alpha/ox-alpha-free/x-preview-f-free, hy3/hy3-preview`）与 `_intercept_unsupported_history(parsed,model)`；`handle()` 中 `go_route` 时若目标为无搜索模型且历史含 `web_search_call`，直接 400 返回友好文案“Cross-model history blocked... Please start a new session... Model=xxx”（2026-08-20 初始为 `deepseek-v4-flash-free/mimo-v2.5-free`，2026-08-21 由 §18/19 替换为 ox-alpha/hy3，见 proxy 日志 `_SEARCH_FALSE_MODELS`）
- 记忆模型：`~/.codex-deepseek/config.toml` `memories.extract_model`/`consolidation_model` 由 `deepseek-v4-flash-go` → `mimo-v2.5-go`（用户指定，与默认对话模型 `deepseek-v4-flash-go` 分离）
- 副作用：仅长搜索历史切无搜索模型时硬拦截需手动新开会话，短/无搜索历史的日常切换无感；官方直连不受影响

### 18. Ox Alpha Free 限时接入与 Zen 双 ID 分叉（2026-08-21，用户指定 ox-alpha-go）
- 背景：`Ox Alpha Free` 为 stealth 限时免费模型（OpenRouter 标 `1,048,576-token context`，`glm-5.3-Vision` 猜测），`opencode.ai` 同时暴露但 **ID 分叉**：`Zen x-preview-f-free`（`https://opencode.ai/zen/v1/chat/completions`）与 `Go ox-alpha-free`（`https://opencode.ai/zen/go/v1/chat/completions`，`Go models list` 实测含 `ox-alpha-free`，`Zen ox-alpha-free → 401`，`Go x-preview-f-free → 401`）。用户要求删 2 个 Zen 套餐（`mimo/DeepSeek free` 日常 429 且 `_SEARCH_FALSE` 残留）并以 `ox-alpha-go` 友好别名接入 Go
- 核对：`Go ox-alpha-free` 直连 `200`（`reasoning_content` 正常），`reasoning_effort` 仅 `low/high/max` 合法（`medium/xhigh → 400 [1210] please use low, high, or max`），与 `deepseek-v4-flash` 同档；`supports_search_tool` 需 `false`（chat 适配路径，`web_search` 必 400，`SKILL.md:6` 同 `glm/mimo`）
- 接入：`models.json` 新增 `ox-alpha-go`（`priority 13` 置尾，`context 1048576` 对齐 OpenRouter，`reasoning low/high/max` 三档，`input_modalities text+image` 走代理视觉描述，`supports_search_tool=false` 无 `web_search_tool_type`），`glm-5.3-go` 模板；`vision_proxy.py:_rewrite_go_model` 新增 `GO_ALIASES={"ox-alpha":"ox-alpha-free"}`、`_rewrite_zen_model` 加 `ZEN_ALIASES={"ox-alpha":"x-preview-f-free"}`，`_SEARCH_FALSE_MODELS` 由 `deepseek-v4-flash-free/mimo-v2.5-free` 替换为 `ox-alpha/ox-alpha-free/x-preview-f-free`（三 ID 兜底，避免裸/Go/Zen 形态漏拦截）
- 验证：经 `127.0.0.1:19100/v1/responses` 单条 `200 OK`、SSE 含 `response.created/item_id/delta` 补全（`SKILL.md:8` 同 `glm/mimo`）、二轮带 `assistant content 数组` 合并后 `200`、`web_search` 剥离后 `200`、含 `web_search_call` 历史被 `400 Cross-model history blocked` 拦截（与 §17 同）；删除 Zen 模型后 `models.json` 13 模型日需重启 Codex 刷新选择器
- 教训：限时 free 模型跨 `Zen/Go` ID 不一致需别名层兜底；未来此类模型默认 `search=false` + `priority` 置尾，结束免费后直接删条目与别名即可

### 19. Hy3 接入（2026-08-21，原生 responses，无搜索，本地工具可用）
- 背景：用户评估 Hy3 能否像 DeepSeek 无缝适配；实测 `hy3`/`hy3-preview` 已在 `Go models list`（`https://opencode.ai/zen/go/v1/models`），按 Responses 原生接入，无需别名
- 核对：Go `https://opencode.ai/zen/go/v1/responses` 直连：`hy3` 带 `reasoning_effort` 全档 `minimal/low/medium/high/max/xhigh/ultra/none/不传` 均 `200`（无 `ox-alpha` 的 `[1210] low/high/max` 限制，比 DeepSeek 宽松），响应无显式 `reasoning` item（隐式思考）；`context 262144/max 128000/text->text/295B MoE 21B active`（OpenRouter `tencent/hy3`）；`tools:web_search` 直连必 `400 [400002] missing field name`（`_strip_web_search_tool` 需保持剥离），`function`（`apply_patch`/`echo`）直连 `200 stop_reason: tool_call` -> 本地工具可用
- 接入：`models.json` 新增 `hy3-go`（`priority 14` 置尾，`context 262144`，`reasoning low/medium/high/xhigh/max` 五档对齐 Codex `enabled-reasoning-efforts`，`supports_search_tool=false` 无 `web_search_tool_type`，`input_modalities text+image` 走代理视觉描述），复用 `ox-alpha-go` 模板；`vision_proxy.py:_SEARCH_FALSE_MODELS` 新增 `hy3/hy3-preview`（拦截含 `web_search_call` 的历史切入，复用 §17 `400 Cross-model history blocked` 文案），`_strip_web_search_tool` 保持剥离（无需白名单），`_rewrite_go_model` 无需别名（Go id 即 `hy3`），`hy3-preview` 仅作拦截不建模（偶发 `Model is unavailable`）
- 验证：经 `127.0.0.1:19100/v1/responses`（带鉴权 `sk-92e1c...`）单条 `200`（`1+1=2` 469 tokens）、`web_search` 剥离后 `200`、二轮 `assistant content 数组` 合并 `200`、`apply_patch` function `200`、含 `web_search_call` 历史被 `400 Cross-model history blocked` 拦截（与 §17/18 同）；`Go models list` 含 `hy3`/`hy3-preview`，`hy3` 单条/工具均稳，`hy3-preview` 偶发不可用故不建模
- 教训：原生 responses 模型即使无搜索也无需 SSE 补全（自带 `response.created`），与 DeepSeek/Luna/Muse 同档；无搜索模型一律 `search=false` + 进 `_SEARCH_FALSE`，搜索任务切 `deepseek-*/luna/muse` 即可

### 20. Ox Alpha / GLM-5.3 工具调用卡死：流式参数丢 `{"` 前缀（2026-08-23 修复）
症状：Codex 副本选 `ox-alpha-go`（及 `glm-5.3-go`）执行任何需要工具的任务（联网搜索、跑命令）时 UI 永远转圈"卡住"。会话 rollout 里出现上百次连续 `exec_command` 空参数/坏参数调用，每次输出都是 `failed to parse function arguments: expected value at line 1 column 1`；proxy 日志请求体每轮精确 +373 字节（一对坏 function_call+output 的序列化尺寸）无限重试。纯文本聊天完全正常。
根因：**上游 opencode.ai Go 网关的 chat→responses 流式适配器对 ox-alpha-free / glm-5.3 吞掉工具参数流的前两个字符 `{`+引号**：delta 首块为 `cmd":"` 而非 `{"cmd":"`，最终 done 帧 `cmd":"pwd"}`。Codex 收到非法 JSON → 执行报错 → 模型重试 → 死循环。**非流式模式完全正常**，mimo/hy3 走同一适配器也正常——是该两模型模板专属 bug。
影响面审查（2026-08-23 全量实测 14 模型流式 run_cmd 工具调用）：仅 `ox-alpha-go`、`glm-5.3-go` 中招；glm-5.2/5.1/5-go 已被网关切原生 responses（native_created=True）不受影响；官方 DeepSeek×2、deepseek-go×3、luna/muse 原生路径正常；mimo×2 chat 路径正常。hy3-go 正常。
修复（vision_proxy.py，备份 .bak.20260823224856）：
- 新增 `_repair_json_object_args(s)`：先 json.loads 校验（健康参数字节级透传），失败则按裸键模式 `^[A-Za-z_]\w*\s*"?\s*:` 补 `{"` 前缀 + 括号候选组合兜底，全失败返回原文
- 新增 `_fc_args_broken(args)` 判定
- 流式侧三处改写（仅无 response.created 的 chat 适配流生效，原生路径首帧短路零接触）：`close_function_call()` 合成帧用修复后参数；`response.function_call_arguments.done` 帧 arguments 修复改写；`response.output_item.done`（function_call）item.arguments 修复改写。**delta 保持逐字透传不缓冲**——codex-rs 从 output_item.done 取完整 item 执行工具，done 帧修好即可，避免缓冲延迟/并行调用分桶复杂度
- 请求侧新增 `_normalize_fc_args_history(parsed)`：zen/go 路由入站历史中解析失败的 assistant function_call 参数同款补括号（救活旧毒化会话，防模型模仿自己的坏历史复发）；挂 `(zen_changed or go_changed)` 条件链
- compat state 增加 `model` 字段（`self._last_model`）便于修复日志定位
验证：ox-alpha-go/glm-5.3-go 流式 done 帧均拼出合法 `{"cmd":"pwd"}`（日志 `repaired fc args at stream close`）；带坏参数历史的二轮请求 200 且日志 `repaired malformed function_call arguments in zen/go request history`；mimo-v2.5-go 与官方 flash 对照组响应逐字段一致零改动。
教训：①chat 适配模型的接入验证必须包含「流式工具调用」case，只测文本/单条消息会漏掉此类截断 bug；②UI"卡住"且 proxy 请求体匀速增长 = 客户端在死循环重试坏工具调用，直接查 rollout 里 function_call arguments 形态即可秒定位；③上游网关随时可能给某模型单独换适配路径（glm 家族一半原生一半 chat），每次接新模型都应全量回归工具调用。

### 21. ox-alpha-go / mimo-v2.5-go 全模型"一直超时"：Go 网关上游故障，本地无责（2026-08-25 排查）
症状：Codex 副本里 OX Alpha 与 MiMo V2.5 两模型持续超时/失败；OpenCode 客户端同款模型正常。proxy 日志可见两类失败：`RuntimeError: Upstream network error: [Errno 60] Operation timed out`（connect 75s 超时）与快速返回的 `HTTP 500 {"message":"Internal server error"}`。
定位链（勿重走）：①proxy 进程/端口/env 均正常 → ②shell 直连 `https://opencode.ai/zen/go/v1/models` 200（v4/v6 双栈均通，排除本机网络/TUN 黑洞）→ ③**用相同 payload 直连上游 POST /v1/responses 同样 500**（排除 proxy 改写层）→ 结论为 Go 网关侧故障。
2026-08-25 14:10 全量实测矩阵（直连 `opencode.ai/zen/go`，ZEN key；14:20 复测补抖动数据）：
| 上游模型 ID | /v1/responses | /v1/chat/completions |
|---|---|---|
| deepseek-v4-flash | **200** completed | 200 |
| deepseek-v4-flash-vision-exp | **200** completed | 200 |
| deepseek-v4-pro | **200**（incomplete 系 max_output_tokens 截断，非故障） | 200 |
| mimo-v2.5 | **500** | 抖动极慢：13–29s 才响应、偶发整体超时 |
| mimo-v2.5-pro | **500** | 200 |
| glm-5.3 / 5.2 / 5.1 / 5 | **全部 500**（glm-5.2 在 8-23 尚原生正常） | 全部 200 |
| ox-alpha-free | **500** | 间歇 200/503（try1=200 7.3s，try2=503 Endpoint unavailable） |
| gpt-5.6-luna（参考） | — | 500 |
| muse-spark-1.2（参考） | — | 401 ModelError |
结论：①**Go 网关 `/v1/responses` 路径对全部非 deepseek 模型系统性 500**（mimo×2/glm×4/ox-alpha 无一幸免，含已切原生 responses 的 glm-5.2），仅 deepseek 三模型原生链路存活——Codex 副本当前只有 deepseek-v4-flash/vision-exp/pro(-go) 可用；②chat 端点大体存活但质量劣化（ox-alpha 间歇 503 = 供应商不稳，mimo-v2.5 首响应 13–29s），OpenCode"能用但变慢"；③ox-alpha-free 若持续间歇 503 按 §18 教训删条目收尾；④Errno 60 connect timeout 为故障期伴随现象，非 VPN 问题。
处置：临时切 `deepseek-v4-flash-go/pro-go/vision-exp-go`；恢复探测命令 `curl -4 -sS -X POST https://opencode.ai/zen/go/v1/responses -H "Authorization: Bearer $ZEN_API_KEY" -d '{"model":"<id>","input":[{"role":"user","content":[{"type":"input_text","text":"hi"}]}],"max_output_tokens":64,"stream":false,"store":false}'`；必要时向 anomalyco/opencode 提 issue（附复现 curl）。

### 22. responses→chat 自动降级桥：网关转换层崩溃的本地兜底（2026-08-25 实施，commit b3d39c6）
背景：§21 矩阵确认 Go 网关 `/v1/responses` 对全部非 deepseek 模型系统性 500 而 chat 端点存活，用户选择本地桥接方案（而非等上游）。luna/muse 403/401 经用户确认为未挂 VPN 所致，非下线。
实现（vision_proxy.py，备份 .bak.20260825144457）：
- `RESPONSES_FALLBACK_MODELS = {mimo-v2.5/pro, glm-5/5.1/5.2/5.3, ox-alpha-free}` + `_RESPONSES_BROKEN_UNTIL` TTL 缓存（300s）
- handle() 中 go_route + `/responses` 路径 + 命中模型时：先探测 responses；`>=500` 或 TTL 内 → 关闭原响应，`_responses_request_to_chat()` 转换后 POST `/v1/chat/completions`；chat 成功则记 TTL 并经 `_send_chat_bridge()` 回写 Responses 协议，chat 也失败则返回带双状态码说明的 502（ox 上游间歇 503 时即此表现）
- 请求侧映射：instructions→system、input message→messages（assistant content 数组天然拍平=免 §10）、reasoning/web_search_call 丢弃、function_call(+output)→assistant.tool_calls/role=tool（同轮多 call 合并）、input_image→image_url 数组、扁平 tools→嵌套 function、reasoning.effort→reasoning_effort；**max_output_tokens 不透传**（防截断思考）
- 响应侧：聚合 chat SSE（content/tool_calls by index/finish_reason/usage）→ 一次性产出完整 Responses 帧序列 created→in_progress→message 链→function_call 链（delta/done）→completed(usage)；工具参数过 `_repair_json_object_args`（§20 同款保险）；非流式请求回 JSON response 对象
- 日志三态：`engaged upstream_status=X chat_status=200` / `upstream_status=0`=TTL 跳探测 / `fallback FAILED ... err=`=chat 也不可用
验证：单测（请求映射×7 场景、坏参数修复、非流式、图片、多 call 合并）+ 端到端经 proxy：mimo/glm-5.2/ox 流式文本与工具调用均 200（shell args `{"cmd":"pwd","limit":1000}`），TTL 快速路径生效，deepseek-v4-flash-go 对照组零改动
教训：①上游 chat↔responses 桥是 Go 网关最脆弱一环（§6/8/9/12/20/21 六次事故同一层），本地降级桥一次投资永久免疫此类故障，但代价是失去逐字流式（整段缓冲）且 reasoning_content 不回传；②新增 fallback 模型只需往 `RESPONSES_FALLBACK_MODELS` 加 ID（剥后缀后的上游名）；③网关恢复后桥自动回归直通路径（探测成功即清 TTL），无需人工干预。

### 24. 26.825 picker 重叠：33 个长名换行叠加（2026-08-31 修复，当前双端 26.825.51511）

症状：Codex 副本模型下拉 `33` 个 `Muse Spark 1.2 Contributor (Go)` 等长名在 `26.825.51511` 换行重叠（Kimi-2.6 处压行），`26.820.80927` 单行 `…` 不叠。

根因：`26.825` 的 `webview/assets/app-initial-B6Gk5KCN.js` 把 `26.820` 的单行样式改多行——
- `cmi:_comboboxRow`：`g=u?`whitespace-normal`:`truncate`` 条件换行（旧无此函数，`VI` 直接 `truncate`）
- `lz:Item`：`J(min-w-0,P?`whitespace-normal`:`truncate`)` + `J(min-w-0 text-xs...,F?`...)` 双处换行
- `mz.itemBase`：`rounded-lg px/py` → `flex min-h-36px items-center justify-center rounded-xl`（36px 容器撑不住两行）

`33` 个平均 18 字、最长 31 字（Muse Contributor）在 `w-65(260px)` 内必换两行后 `36px` 装不下即叠。A 验证（退 26.820 单行即不叠）已证非 models.json 数量问题。

修复（仅副本 `~/Applications/ChatGPT-Patched.app`，正本不动，`opencodex.me` 不改 asar 而用 priority 减量故不适用"33 全在"场景）：

```bash
npx --yes asar extract ~/Applications/ChatGPT-Patched.app/Contents/Resources/app.asar /tmp/fix-single
# app-initial-B6Gk5KCN.js 三处：
# g=u?`whitespace-normal`:`truncate` → g=`truncate`
# J(`min-w-0`,P?`whitespace-normal`:`truncate`) → J(`min-w-0`,`truncate`)
# J(`min-w-0 text-xs ...`,F?`whitespace-normal`:`truncate`) → J(`...,`truncate`)
# 可选：mz.itemBase 改回旧 rounded-lg（如仍叠）
npx --yes asar pack /tmp/fix-single /tmp/app-single.asar && cp /tmp/app-single.asar ~/Applications/ChatGPT-Patched.app/Contents/Resources/app.asar
security unlock-keychain -p 0000 ~/Library/Keychains/codex-signing.keychain-db
codesign --force --deep --sign "Codex Patched Signing" --keychain ~/Library/Keychains/codex-signing.keychain-db --entitlements ~/.codex/picker-patch/certs/ent2.plist ~/Applications/ChatGPT-Patched.app
rm -rf ~/Library/Application\ Support/Codex-Patched/GPUCache ~/Library/Application\ Support/Codex-Patched/CacheStorage ~/Library/Application\ Support/Codex-Patched/Code\ Cache && open ~/Applications/ChatGPT-Patched.app
```

验证：`grep -a "g=\`truncate\`" .../app.asar` 1 处、`w-65` 1 处、`models.json 33` 且 `display_name` 全长，`picker` 单行 `…` 不叠。备份 `/Library/Project/ChatGPT-26.820.zip` 可回滚。下次官方升 `26.826` 需在 `patch.sh --install` 后重做此单行补丁。

### 23. proxy 加固 P0-P5（2026-08-25，commits 1493651/1d3dc6b/81fe433，分支 feature/proxy-hardening）
对标 opencodex（github lidge-jun/opencodex）补齐五块短板：
- **P0 测试**：`tests/test_units.py`（12 单测：请求映射/SSE聚合/坏参数修复/预算截断/incremental translator）+ `tests/run_regression.py`（live e2e：deepseek 直通对照/mimo 桥流式/reasoning 可见/ox 工具调用/glm 非流式）。改 proxy 必跑：`python3 tests/run_regression.py`。教训：测试 helper 的 bytes join 混入 str、给截断参数断言 parse 成功——两个假红都是测试自身 bug，先怀疑脚手架再怀疑实现
- **P1 日志**：`_log()` 自动加 `[YYYY-MM-DD HH:MM:SS]` 前缀；每个 API 事务 finally 打一行 `txn method path model route status bridge ms`
- **P2 断流兜底**：`_send_response_sse` EOF 后若未见任何 terminal 事件 → 合成 `response.failed`（code=upstream_stream_interrupted），codex-rs 不再挂死
- **P3 流式**：新 `ChatBridgeTranslator` 类取代全缓冲——chat delta 逐块映射 output_text.delta/function_call_arguments.delta，done 帧仍过 `_sanitize_fc_args`（§20 保险）。实测 mimo 长回答正文 268 增量均匀铺满 12s（旧版单 blob）；glm 短诗 72 块/1.4s 属模型生成快，非攒批
- **P4 reasoning 可见**：chat 的 reasoning_content/reasoning delta → reasoning item（summary_part/text added/delta/done 链），实测思考 83 块从 0s 实时流出
- **P5 内存闸门**：累计文本 16MB 预算（超限 graceful 截断 incomplete）、非流式体 64MB 上限
- **P6-lite 附赠**：`_upstream_headers` 清洗 python-urllib UA（CF error 1010 实锤拦截该 UA；本地脚本经 proxy 全 403 即此因）→ 替换为 vision-proxy/1.0
- 排障工具箱新增：直连 vs 经 proxy 的 delta 到达时间分布对照法（判别攒批在哪层）；readline 按 JSON 解析判 delta 类型（grep 字节串会漏转义形态）
- **搜索边车决策（2026-08-25，用户拍板：不做）**：评估过 opencodex 式方案（剥离托管 web_search → 合成 `web_search(query)` function → proxy 内部用可联网后端（候选 luna-go）跑 agentic 循环代搜，≤3 次/turn）。机制可行但①带托管搜索的调用消耗 Go 订阅额度极快（$12/5h 上限）②proxy 需从单发转发升级为有状态循环(~250 行)③§17 历史拦截需适配合成工具历史。维持现状:搜索任务手动切 deepseek/luna/muse,mimo/glm/ox 保持无搜索+§17 拦截保护

### 25. 记忆管线一劳永逸：mimo 最便宜 + 防超大 rollout 重试（2026-09-01）

症状：副本每次一打开就烧大量 `mimo-v2.5-go` 额度，`MEMORY.md 206KB≈35k tokens` 且每次重启都重试 13 个 `memory_stage1 error (EOF/expected value at line 1)`，单次 `consolidate_global` 输入 `MEMORY 35k + raw 37k + raw_memory 135k ≈70k`，用 mimo 也贵在量而非单价。`diagnose.py` 显示 `memory_stage1 error 13` 对应 3~19MB 的超大 `rollout-*.jsonl` 经 `127.0.0.1:19100` 代理时 JSON 截断（本次 19MB 的 `01a018ba` 等 13 个）。

根因：`[memories]` 的 `extract_model/consolidation_model` 选 `mimo-v2.5-go` 本身是对的（Go 表里 `$0.14/$0.28/$0.0028` 最便宜一档，仅比 `muse-spark-1.2 $0.10/$0.20/$0.002` 略高，远便宜于 `deepseek-v4-flash $0.44/$1.32`），贵在**量**：`use_memories=true` 时 35k 的 `MEMORY.md` 每轮对话都作前缀输入，且超大 rollout 反复入队重试。

处置（2026-09-01 已落地，本机为样板）：
- `config.toml` 显式 `max_rollouts_per_startup = 2`（在 `disable_on_external_context` 下一行），限流每次启动只扫 2 个新 rollout。
- 清理 `memories_1.sqlite` 中 `memory_stage1` 的 `error/running` 行 + `UPDATE stage1_outputs SET selected_for_phase2=1` + `finalize_phase2.py` 重建 `raw_memories.md`（45/45 已选，`memory_consolidate_global done`），并将 13 个超大 `rollout-*.jsonl`（3~19MB）移至 `/tmp/codex_mem_backup_<ts>/failed_rollouts/`。
- 重启后验证：`diagnose.py` 应 `memory_stage1 done 49 / error 0 / running 0`，`stage1_outputs 45 rows, 45 selected`。

长期保险：模板 `resources/templates/config.toml` 已同步加 `max_rollouts_per_startup = 2`，安装器默认 `mimo-v2.5-free-zen` 免费 + `memories=false` 默认关闭（2026-09-01 更新，commit 8672672）；对 `>8MB` 的 rollout 视为超上下文需手动总结或移走；`MEMORY.md 206KB` 的前缀成本固定 35k tokens/轮，欲再降需归档旧 Task Group。

### 26. 记忆默认关闭 + 免费模型（2026-09-01 2）

处置：安装器与 `resources/templates/config.toml` 默认 `generate_memories=false, use_memories=false, disable_on_external_context=true, extract_model=mimo-v2.5-free-zen`（之前为 `mimo-v2.5-go` 付费）；存量 `~/.codex-deepseek/config.toml` 的 `patch` 逻辑在更新时自动把 `generate/use → false, disable → true, extract → free-zen`（含 `max_rollouts_per_startup=2` 补齐），用户想开再手动改回 `true`。

### 27. MCP 搜索托管 + Muse 去搜对齐（2026-09-01 3）

背景：`models.json` 33 个中 27 个无原生 `web_search`（`mimo×3, glm×4, kimi×3, qwen×5, hy×2, grok, longcat, minimax×2, ling, nemotron×2, big-pickle`），`opencode.ai` 网关对它们 `400 missing field name`；`muse-spark-1.2-contributor-go` 曾 `true` 导致每轮 37 次 `web_search_call` + 9万 input 循环。
处置（2026-09-01 3 初版）：
- `resources/templates/models.json:1878` `muse-spark-1.2-contributor-go` `supports_search_tool true→false` 并删 `web_search_tool_type`，与 `free-zen` 对齐。
验证：`python3 -u websearch-server.py` `tools/list` 2 工具；`websearch("AI news 2026", numResults=2) → [parallel] 8 条` 已通（2026-09-01）。

### 28. 原生支持全开（2026-09-01 4，本地实测纠错）

背景：线上盲审 6/27 漏把 `muse` 与 `grok` 判 `false`。本地直打 `https://opencode.ai/zen/go/v1/responses`：`muse-spark-1.2-contributor` 带 `web_search` `200`（Meta 官博 `built-in web search grounding, $0.00825/搜`，`api.meta.ai` 原生）、`grok-4.6` 带 `web_search` `200`（`docs.x.ai/tools/web_search`，`grok-4.6 500k` 原生），`glm-5` 等 `500 Internal` 仍不通，`qwen/kimi/minimax/nemotron` `401 not supported for format openai`。
处置：`resources/templates/models.json` 与 `~/.codex-deepseek/models.json` 把 `muse-spark-1.2-contributor-free-zen/go` 与 `grok-4.6-go` 改回 `supports_search_tool=true + web_search_tool_type=text`，现 `✓ 有搜 9 个`（`deepseek×4 + vision×2 + gpt-5.6-luna-go + muse×2 + grok`），`✗ 无搜 24 个`（`glm×4, kimi×3, qwen×5, hy×2, mimo×3, minimax×2, longcat, ling, nemotron×2, big-pickle`，新加的 `qwen3.8/hy3` 等才真没有）；`vision_proxy.py:924` `_SEARCH_TRUE_PREFIXES` 加 `"grok-"`，`setup.command:7` 的 `MCP websearch` 保持仅 24 个无搜用，6→9 的 `muse/grok` 切回原生无需 MCP。
教训：不能只看 `models.json` 标 `false` 就判原生不支持，需按 `provider` 官文档（`developer.meta.com / docs.x.ai`）+ `zen/go/responses` 直打验证；新模默认 `false` 是对的，但 `muse/grok` 是老模已支持。
