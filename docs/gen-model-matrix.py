#!/usr/bin/env python3
"""生成 docs/MODEL-MATRIX.md（模型 × 调整矩阵）。

数据源：Resources/codex/templates/models.json（模型清单）+ Resources/codex/vision/vision_proxy.py（协议/搜索名单）
2026-09-10：视觉转文字链路下线，矩阵不再有「视觉」列。

用法：python3 docs/gen-model-matrix.py
"""

from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "Resources/codex/templates/models.json"
PROXY = ROOT / "Resources/codex/vision/vision_proxy.py"
OUT = ROOT / "docs/MODEL-MATRIX.md"


def slug_set(source: str, name: str) -> set[str]:
    """从 vision_proxy.py 里抠出 frozenset 常量里的模型名。"""
    m = re.search(rf"{name}\s*=\s*frozenset\(\{{(.*?)\}}\)", source, re.S)
    if not m:
        return set()
    return set(re.findall(r'"([^"]+)"', m.group(1)))


def main() -> int:
    catalog = json.loads(MODELS.read_text())
    models = catalog.get("models", [])
    proxy_src = PROXY.read_text()
    fallback = slug_set(proxy_src, "RESPONSES_FALLBACK_MODELS")
    always = slug_set(proxy_src, "RESPONSES_ALWAYS_BRIDGE")

    def bare(slug: str) -> str:
        for suffix in ("-go", "-zen"):
            if slug.endswith(suffix):
                return slug[: -len(suffix)]
        return slug

    def proto(slug: str) -> str:
        name = bare(slug)
        if name in always:
            return "无条件桥"
        return "桥接" if name in fallback else "原生"

    def search(slug: str) -> str:
        name = bare(slug)
        return "原生" if name.startswith(("deepseek-", "gpt-5.6-luna", "muse-spark")) else "边车"

    go = [m for m in models if m["slug"].endswith("-go")]
    zen = [m for m in models if m["slug"].endswith("-zen")]
    official = [m for m in models if not m["slug"].endswith(("-go", "-zen"))]

    lines = [
        f"# 模型 × 调整矩阵（基线 {time.strftime('%Y-%m-%d')}）",
        "",
        "> 由 `docs/gen-model-matrix.py` 生成：模型清单来自 `Resources/codex/templates/models.json`，",
        "> 协议/搜索列来自 `vision_proxy.py` 的名单。新增模型按 SOP 接入后重跑本脚本。",
        "",
        f"总数 {len(models)}（Go {len(go)} + Zen {len(zen)} + 官方 {len(official)}）",
        "",
        "| # | Slug | 显示名 | Context | 档位 | 协议 | 搜索 |",
        "|---|---|---|---|---|---|---|",
    ]
    for i, m in enumerate(models, start=1):
        levels = ",".join(lv.get("effort", "") for lv in (m.get("supported_reasoning_levels") or []))
        ctx = f"{m.get('context_window', 0):,}"
        lines.append(
            f"| {i} | `{m['slug']}` | {m.get('display_name', '')} | {ctx} | {levels} "
            f"| {proto(m['slug'])} | {search(m['slug'])} |"
        )

    lines += [
        "",
        "## 图例",
        "- **协议**：原生=直透 `/responses`；桥接=/responses 不可用时自动切 chat；无条件桥=改走 chat 的原生端点",
        "- **搜索**：原生=网关真联网；边车=注入 synthetic `web_search` → deepseek 代搜",
        "- **档位**：目录声明（models.dev / `reasoning_overrides.json` 手工实测）→ 代理 `reasoning_registry.json`",
        "- **图片**：图片由模型原生处理；不声明 `image` 的模型发图会失败（换有视觉的模型即可）",
        "",
        "## 接入决策（SOP 第2步）",
        "- P1=200 → 原生；P1=500/P2=200 → 桥接；P1=4xx 穿透 → 无条件桥",
        "- P4=200 → 搜索列改「原生」；否则边车已生效",
        "- P3 档位被拒的 → 从条目删除",
        "",
    ]
    OUT.write_text("\n".join(lines))
    print(f"已生成 {OUT.relative_to(ROOT)}（{len(models)} 个模型）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
