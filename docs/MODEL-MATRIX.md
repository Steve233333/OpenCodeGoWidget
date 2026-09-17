# 模型 × 调整矩阵（基线 2026-09-17）

> 由 `docs/gen-model-matrix.py` 生成：模型清单来自 `Resources/codex/templates/models.json`，
> 协议/搜索列来自 `vision_proxy.py` 的名单。新增模型按 SOP 接入后重跑本脚本。

总数 38（Go 28 + Zen 8 + 官方 2）

| # | Slug | 显示名 | Context | 档位 | 协议 | 搜索 |
|---|---|---|---|---|---|---|
| 1 | `glm-5.3-flash-go` | GLM-5.3-Flash (Go) | 1,000,000 | low,high,max | 桥接 | 边车 |
| 2 | `glm-5.3-go` | GLM-5.3 (Go) | 1,000,000 | low,high,max | 桥接 | 边车 |
| 3 | `glm-5.2-go` | GLM-5.2 (Go) | 1,000,000 | high,max | 桥接 | 边车 |
| 4 | `glm-5.1-go` | GLM-5.1 (Go) | 202,752 | high,max | 桥接 | 边车 |
| 5 | `kimi-k3-go` | Kimi-K3 (Go) | 1,048,576 | low,high,max | 桥接 | 边车 |
| 6 | `kimi-k2.7-code-go` | Kimi-K2.7-Code (Go) | 262,144 | low,high,max | 桥接 | 边车 |
| 7 | `kimi-k2.6-go` | Kimi-K2.6 (Go) | 262,144 | low,high,max | 桥接 | 边车 |
| 8 | `longcat-2.0-go` | LongCat-2.0 (Go) | 1,000,000 | low,high,max | 桥接 | 边车 |
| 9 | `mimo-v2.5-go` | MiMo-V2.5 (Go) | 1,000,000 | low,high,max | 桥接 | 边车 |
| 10 | `mimo-v2.5-pro-go` | MiMo-V2.5-Pro (Go) | 1,048,576 | high | 桥接 | 边车 |
| 11 | `minimax-m3-go` | MiniMax-M3 (Go) | 1,000,000 | low,high,max | 桥接 | 边车 |
| 12 | `minimax-m2.7-go` | MiniMax-M2.7 (Go) | 204,800 | low,high,max | 桥接 | 边车 |
| 13 | `muse-spark-1.3-contributor-go` | Muse Spark-1.3-Contributor (Go) | 1,048,576 | low,medium,high,xhigh | 原生 | 原生 |
| 14 | `muse-spark-1.2-contributor-go` | Muse Spark 1.2 Contributor (Go) | 1,048,576 | low,medium,high,xhigh | 原生 | 原生 |
| 15 | `qwen3.8-max-go` | Qwen3.8-Max (Go) | 1,000,000 | low,medium,xhigh | 桥接 | 边车 |
| 16 | `qwen3.8-flash-go` | Qwen3.8-Flash (Go) | 1,000,000 | high | 桥接 | 边车 |
| 17 | `qwen3.7-max-go` | Qwen3.7-Max (Go) | 1,000,000 | high | 桥接 | 边车 |
| 18 | `qwen3.7-plus-go` | Qwen3.7-Plus (Go) | 1,000,000 | high | 桥接 | 边车 |
| 19 | `qwen3.6-plus-go` | Qwen3.6-Plus (Go) | 1,000,000 | high | 桥接 | 边车 |
| 20 | `deepseek-v4.1-flash-go` | DeepSeek-V4.1-Flash (Go) | 1,000,000 | low,high,max | 原生 | 原生 |
| 21 | `deepseek-v4-pro` | DeepSeek-V4-Pro | 1,000,000 | high,max | 原生 | 原生 |
| 22 | `deepseek-v4-pro-go` | DeepSeek-V4-Pro (Go) | 1,000,000 | high,max | 原生 | 原生 |
| 23 | `deepseek-v4-flash-go` | DeepSeek-V4-Flash (Go) | 1,000,000 | low,high,max | 原生 | 原生 |
| 24 | `deepseek-v4-flash-vision-exp` | DeepSeek-V4-Flash Vision Exp | 1,000,000 | low,high,max | 原生 | 原生 |
| 25 | `deepseek-v4-flash-vision-exp-go` | DeepSeek-V4-Flash-Vision-Exp (Go) | 1,000,000 | low,high,max | 原生 | 原生 |
| 26 | `hy4-preview-go` | Hy4-Preview (Go) | 1,024,000 | high | 桥接 | 边车 |
| 27 | `hy3-go` | Hy3 (Go) | 262,144 | high | 桥接 | 边车 |
| 28 | `union-alpha-go` | Union-Alpha-Free (Go) | 262,144 | high | 原生 | 边车 |
| 29 | `grok-4.6-go` | Grok-4.6 (Go) | 500,000 | low,high,max | 桥接 | 边车 |
| 30 | `gpt-5.6-luna-go` | GPT-5.6-Luna (Go) | 1,050,000 | low,medium,high,xhigh,max | 原生 | 原生 |
| 31 | `big-pickle-zen` | Big Pickle Free (Zen) | 200,000 | high | 桥接 | 边车 |
| 32 | `deepseek-v4-flash-free-zen` | DeepSeek V4 Flash Free (Zen) | 200,000 | low,high,max | 原生 | 原生 |
| 33 | `muse-spark-1.3-contributor-free-zen` | Muse Spark 1.3 Contributor Free (Zen) | 1,048,576 | low,medium,high,xhigh | 原生 | 原生 |
| 34 | `muse-spark-1.2-contributor-free-zen` | Muse Spark 1.2 Free (Zen) | 1,048,576 | low,medium,high,xhigh | 原生 | 原生 |
| 35 | `mimo-v2.5-free-zen` | MiMo V2.5 Free (Zen) | 200,000 | low,high,max | 桥接 | 边车 |
| 36 | `ling-3.0-flash-fin-free-zen` | Ling 3.0 Flash Fin Free (Zen) | 262,144 | high | 桥接 | 边车 |
| 37 | `nemotron-3-ultra-free-zen` | Nemotron 3 Ultra Free (Zen) | 1,000,000 | high | 桥接 | 边车 |
| 38 | `nemotron-3.5-lightning-free-zen` | Nemotron 3.5 Lightning Free (Zen) | 262,144 | high | 桥接 | 边车 |

## 图例
- **协议**：原生=直透 `/responses`；桥接=/responses 不可用时自动切 chat；无条件桥=改走 chat 的原生端点
- **搜索**：原生=网关真联网；边车=注入 synthetic `web_search` → deepseek 代搜
- **档位**：目录声明（models.dev / `reasoning_overrides.json` 手工实测）→ 代理 `reasoning_registry.json`
- **图片**：图片由模型原生处理；不声明 `image` 的模型发图会失败（换有视觉的模型即可）

## 接入决策（SOP 第2步）
- P1=200 → 原生；P1=500/P2=200 → 桥接；P1=4xx 穿透 → 无条件桥
- P4=200 → 搜索列改「原生」；否则边车已生效
- P3 档位被拒的 → 从条目删除
