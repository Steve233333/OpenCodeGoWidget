# 本地转换层（vision_proxy）

Codex 只会说 **Responses** 协议，而各家模型说的是各自方言。这一层负责翻译、修补与兜底。

## 一张图看懂

```
Codex ──▶ vision_proxy.py（薄入口 + 兼容 re-export）
              │
              ├─ proxy/policy.py    ★ 模型怪癖的唯一真源（家族 + 单模型覆盖）
              ├─ proxy/server.py      HTTP 服务本体：Proxy.handle() 读请求 → 路由 → 转发
              │    ├─ 原生 /responses    （原生模型）
              │    ├─ chat 桥           （chat 适配模型；坏了自动切，并记住"这个模型坏了"）
              │    └─ messages 桥       （只认 Anthropic Messages 格式的模型）
              ├─ proxy/sse.py         SSE 改写引擎：帧分发 + apply_patch 参数拼接 + 终止修复 + 正文平滑
              ├─ proxy/toolfix.py     工具调用修补：坏 JSON 参数、历史里的 monster、MiMo XML→function_call
              ├─ proxy/muse.py        Muse 兼容：schema 修补、禁止空转前缀、空转重试、预算下限
              ├─ proxy/search_sidecar.py  给没有原生搜索的模型合成 web_search（结果来自 deepseek 代搜）
              │                             + 历史翻译件：查询词/调用 id/占位结果/合成工具定义（两个桥共用）
              └─ proxy/apply_patch.py apply_patch 工具描述改写（custom → function）
```

## 模型策略表（要加模型/改行为，只改这里）

`proxy/policy.py`：

- `MODEL_FAMILIES`：家族级默认（前缀匹配，最长前缀赢）
- `MODEL_OVERRIDES`：单个 slug 覆盖（例如 `grok-4.7` 走原生、`union-alpha` 只走 messages）
- 入口 `policy_for(model)`；顺手做名字归一（`-go`/`-zen` 后缀、`opencode-go/` 前缀）

字段与含义：

| 字段 | 作用 |
|---|---|
| `route` | `native`（只用原生）/ `native-or-bridge`（先试原生，坏了走 chat 桥并记退避）/ `bridge`（直接走桥）/ `messages`（只认 Messages 格式） |
| `native_search` | 模型自带 `web_search`；False 的由搜索边车合成 |
| `terminal_grace` | 上游没发终止帧时的宽限秒数（None = 用全局 5 秒） |
| `min_output_tokens` | 输出预算下限（muse：推理也吃这个预算，太小会"只思考不出字"） |
| `stall_guard` | 是否启用"只叙述不调用工具"的空转守卫（muse） |
| `smoothing` | 正文平滑（上游一次性涌出时按 300 字/秒滴，看起来像正常逐字） |

**改行为的规矩**：先改策略表，再改 `tests/test_model_policy_golden.py` 的基线并在 CHANGELOG 说明 ——
那张表就是"重构前的行为"，它一红就说明你顺手改了别的东西。

## 每个模型家族现在是什么行为（2026-09-23）

| 家族 | 路由 | 搜索 | 特殊处理 |
|---|---|---|---|
| deepseek | 原生 | 自带 | — |
| gpt（5.6 luna） | 原生 | 自带 | 显示名绕开 Codex 的 `GPT-` 前缀剥离 |
| muse-spark | 原生 | 自带 | 空转守卫（有限扣留 + 最多 2 次重发）、预算下限 16384、正文平滑 |
| mimo / glm / kimi / qwen / minimax / longcat / hy / grok(4.5,4.6) | 先原生→坏了走 chat 桥 | 边车合成 | MiMo 的原生 XML 工具调用会被解析成 function_call |
| grok-4.7 | 原生 | 边车合成 | — |
| zen 免费家族（ox-alpha / x-preview / big-pickle / ling / nemotron / *-free） | 先原生→坏了走 chat 桥 | 边车合成 | — |
| union-alpha | messages | — | Go 网关只在 /v1/messages 暴露它 |
| omen-alpha | chat 桥 | — | 不浪费一次原生探测 |

## 出问题先看哪里

| 症状 | 先看 |
|---|---|
| 完全连不上 / Codex 报 "waiting for network" | `~/.local/share/agent-vision-toolkit/{ensure-proxy.log,proxy.err.log}`；`ensure-proxy.sh` 一键修 |
| 模型"只思考不出字" | `proxy.err.log` 里有没有 `max_output_tokens … → 16384`（预算太小）或 `response.incomplete` |
| 话说一半断了 | 上游流断（`status=0`）/ 终止帧缺失：日志会写 `上游空闲 … 收尾` 或 `补 response.completed` |
| 正文一次闪出来 | 上游把整段一次 flush（直连网关也这样）；本层只做平滑，不改内容 |
| 工具调用没执行 / 正文冒出 `<tool_call>` | MiMo XML 解析是否命中：日志 `MiMo XML 工具调用已转成 function_call` |
| 换模型接着聊被 400 拦（Cross-model history） | 已不该出现：历史里的 `web_search_call` 会翻成 `web_search` 调用 + 占位结果，日志写 `history replay: translated N web_search_call, dropped M reasoning items`；若又冒出来说明桥里的 `_translate_history` 被绕过 |

## 测试与门槛

- 离线：`build.sh --test` 会跑 `tests/run_all_robust.py`（单元 48 + 策略基线 3 + 中继 8 + SSE 字节基线 2 + 混沌 38 + 发现 14 + 安装器 8）
- 真机冒烟：`scripts/smoke-conversion.sh`（DeepSeek / MiMo / Muse / GLM 各一条流式请求 + 跨模型搜索历史两条）
- shell 写法检查：`scripts/check-shell-cjk-vars.sh`（`$VAR` 后面别直接跟中文标点）
