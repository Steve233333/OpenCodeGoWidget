# 模型 × 调整矩阵（基线 2026-09-05）

> 自动生成自 `~/.codex-deepseek/models.json` + `vision_proxy.py` 名单。新增模型按 SOP 接入后更新此表.

总数 37（Go 27 + Zen 8 + 官方 2)

| # | Slug | 显示名 | Context | 档位 | 协议 | 搜索 | 视觉 |
|---|---|---|---|---|---|---|---|
| 1 | `grok-4.6-go` | Grok-4.6 (Go) | 500,000 | low,high,max | 桥接 | 原生 | GLM描述 |
| 2 | `gpt-5.6-luna-go` | GPT-5.6 Luna (Go) | 1,050,000 | low,medium,high,xhigh,max | 原生 | 原生 | 原生 |
| 3 | `glm-5.3-flash-go` | GLM-5.3-Flash (Go) | 1,000,000 | low,high,max | 桥接 | 边车 | GLM描述 |
| 4 | `glm-5.3-go` | GLM-5.3 (Go) | 1,000,000 | low,high,max | 桥接 | 边车 | 原生 |
| 5 | `glm-5.2-go` | GLM-5.2 (Go) | 1,000,000 | high,max | 桥接 | 边车 | 原生 |
| 6 | `glm-5.1-go` | GLM-5.1 (Go) | 202,752 | high,max | 桥接 | 边车 | 原生 |
| 7 | `kimi-k3-go` | Kimi-K3 (Go) | 1,048,576 | low,high,max | 桥接 | 边车 | GLM描述 |
| 8 | `kimi-k2.7-code-go` | Kimi-K2.7-Code (Go) | 262,144 | low,high,max | 桥接 | 边车 | GLM描述 |
| 9 | `kimi-k2.6-go` | Kimi-K2.6 (Go) | 262,144 | low,high,max | 桥接 | 边车 | GLM描述 |
| 10 | `longcat-2.0-go` | Longcat-2.0 (Go) | 1,000,000 | low,high,max | 桥接 | 边车 | — |
| 11 | `mimo-v2.5-go` | MiMo-V2.5 (Go) | 1,000,000 | low,high,max | 桥接 | 边车 | 原生 |
| 12 | `mimo-v2.5-pro-go` | MiMo-V2.5-Pro (Go) | 1,048,576 | high | 桥接 | 边车 | 原生 |
| 13 | `minimax-m3-go` | Minimax-M3 (Go) | 1,000,000 | low,high,max | 桥接 | 边车 | GLM描述 |
| 14 | `minimax-m2.7-go` | Minimax-M2.7 (Go) | 204,800 | low,high,max | 桥接 | 边车 | — |
| 15 | `muse-spark-1.3-contributor-go` | Muse Spark-1.3-Contributor (Go) | 1,048,576 | low,medium,high,xhigh | 原生 | 原生 | 原生 |
| 16 | `muse-spark-1.2-contributor-go` | Muse Spark 1.2 Contributor (Go) | 1,048,576 | low,medium,high,xhigh | 原生 | 原生 | 原生 |
| 17 | `qwen3.8-max-go` | Qwen3.8-Max (Go) | 1,000,000 | low,medium,xhigh | 桥接 | 边车 | GLM描述 |
| 18 | `qwen3.8-flash-go` | Qwen3.8-Flash (Go) | 1,000,000 | high | 桥接 | 边车 | GLM描述 |
| 19 | `qwen3.7-max-go` | Qwen3.7-Max (Go) | 1,000,000 | high | 桥接 | 边车 | — |
| 20 | `qwen3.7-plus-go` | Qwen3.7-Plus (Go) | 1,000,000 | high | 桥接 | 边车 | GLM描述 |
| 21 | `qwen3.6-plus-go` | Qwen3.6-Plus (Go) | 1,000,000 | high | 桥接 | 边车 | GLM描述 |
| 22 | `deepseek-v4-pro` | DeepSeek-V4-Pro | 1,000,000 | high,max | 原生 | 原生 | 原生 |
| 23 | `deepseek-v4-pro-go` | DeepSeek-V4-Pro (Go) | 1,000,000 | high,max | 原生 | 原生 | 原生 |
| 24 | `deepseek-v4-flash-go` | DeepSeek-V4-Flash (Go) | 1,000,000 | low,high,max | 原生 | 原生 | — |
| 25 | `deepseek-v4-flash-vision-exp` | DeepSeek-V4-Flash Vision Exp | 1,000,000 | low,high,max | 原生 | 原生 | 原生 |
| 26 | `deepseek-v4-flash-vision-exp-go` | DeepSeek-V4-Flash Vision Exp (Go) | 1,000,000 | low,high,max | 原生 | 原生 | 原生 |
| 27 | `hy4-preview-go` | Hy4-Preview (Go) | 1,024,000 | high | 桥接 | 边车 | — |
| 28 | `hy3-go` | Hy3 (Go) | 262,144 | high | 桥接 | 边车 | — |
| 29 | `omen-alpha-go` | Omen-Alpha (Go) | 500,000 | low,high | 无条件桥 | 边车 | 原生 |
| 30 | `big-pickle-zen` | Big Pickle Free (Zen) | 200,000 | high | 桥接 | 边车 | — |
| 31 | `deepseek-v4-flash-free-zen` | DeepSeek V4 Flash Free (Zen) | 200,000 | low,high,max | 原生 | 原生 | — |
| 32 | `muse-spark-1.3-contributor-free-zen` | Muse Spark 1.3 Contributor Free (Zen) | 1,048,576 | low,medium,high,xhigh | 原生 | 原生 | GLM描述 |
| 33 | `muse-spark-1.2-contributor-free-zen` | Muse Spark 1.2 Free (Zen) | 1,048,576 | low,medium,high,xhigh | 原生 | 原生 | GLM描述 |
| 34 | `mimo-v2.5-free-zen` | MiMo V2.5 Free (Zen) | 200,000 | low,high,max | 桥接 | 边车 | GLM描述 |
| 35 | `ling-3.0-flash-fin-free-zen` | Ling 3.0 Flash Fin Free (Zen) | 262,144 | high | 桥接 | 边车 | — |
| 36 | `nemotron-3-ultra-free-zen` | Nemotron 3 Ultra Free (Zen) | 1,000,000 | high | 桥接 | 边车 | — |
| 37 | `nemotron-3.5-lightning-free-zen` | Nemotron 3.5 Lightning Free (Zen) | 262,144 | high | 桥接 | 边车 | — |

## 图例
- **协议**：原生=直透 `/responses`；桥接=500自动切 chat；无条件桥=omen 式（400也切）
- **搜索**：原生=网关真联网；边车=注入 synthetic `web_search` → deepseek 代搜
- **视觉**：原生=`NATIVE_VISION_MODELS` 直通 image_url；GLM描述=经智谱 GLM 转文字；—=纯文本
- **档位**：registry 手工实测优先，其次 models.dev，再 opencodex

## 接入决策（SOP 第2步）
- P1=200 → 原生；P1=500/P2=200 → 桥接；P1=400穿透 → 无条件桥
- P4=200 → 搜索列改"原生"；否则边车已生效
- P5b 对且答对 → 视觉列改"原生"
- P3 档位被拒的 → 从条目删除