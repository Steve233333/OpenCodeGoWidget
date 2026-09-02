---
name: context-reasoning-audit
description: 核对 Codex Go 模型上下文与推理档位的上网交叉验证技能。触发场景：用户说“核对上下文/推理档位”“审计 Go 模型”“检查档位”“context 档位核对”等。逐个核对 models.json 与官方来源，输出一致/缺表/偏差表与补 registry 的 patch 预览。
---

# 上下文与推理档位核对

## 概述

对 `~/.codex-deepseek/models.json` 中全部 Go 模型逐个核对 `context_window` 与 `supported_reasoning_levels`，与本地 `reasoning_registry.json`、远端 `https://opencode.ai/docs/zh-cn/go/` 配额表及厂商文档交叉验证，输出全量比对表与缺表项的补丁预览。默认只读不出写，需用户确认后才写表。

## 执行步骤

### 第一步：本地快照

```bash
python3 ~/.config/opencode/skills/context-reasoning-audit/audit.py --report
```
读取 `~/.codex-deepseek/models.json:27` 与 `~/.local/share/agent-vision-toolkit/reasoning_registry.json:28`，列 `slug, ctx, levels, default`。

### 第二步：远端交叉（配额表 + 厂商文档）

- 配额表 `https://opencode.ai/docs/zh-cn/go/` 仅校验 `谁进谁不进`（25 真源），不校验 `ctx`
- `上下文` 以 `registry` 为准，`通用 high` 兜底；`档位` 缺表项上网 2-3 源核对（z.ai / tencent/Hy3 / qwencloud / kimi.ai）

### 第三步：输出比对表

| slug | 当前 ctx | 当前档位 | 官方期望 | 判定 |
`缺表+一致` 25/27 / `缺表` 2/27 为正常；`偏差` 需手写补 registry。

### 第四步：补丁预览（可选）

```
python3 audit.py --fix --dry-run   # 预览将新增的 registry 条目
python3 audit.py --fix             # 写入 registry，models.json 随下次 sync 重刷
```

## 用法示例

用户输入：
> "帮我核对一下现在这些 go 模型的上下文和推理档位"

执行 `python3 audit.py --report` 并打印表格，缺表项提示 `将新增 qwen3.8-flash: ["high"]` 的 patch。

## 注意事项

- `https://opencode.ai/zen/go/v1/models` 只回 `id`，不回 `ctx/档位`，不能作为核对源
- `上下文` 官方无表，以 `registry` + `1000000/262144` 模板为准
- `generic high` 为零探针兜底，新模型不在表也先 `high` 单档
