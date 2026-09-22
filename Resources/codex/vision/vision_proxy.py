#!/usr/bin/env python3
"""Local routing proxy for Codex: Go/Zen/DeepSeek upstreams, protocol bridging, search injection.

2026-09-23（Phase 3）：这个文件原来是 **3793 行**的单体脚本（107 个顶层符号），现在拆成
`proxy/` 包，本文件只剩入口 + 兼容层。**纯机械搬移，一行逻辑都没改**：

  * `proxy/config.py`            配置/常量/日志（含 CA 证书兜底、推理档位注册表）
  * `proxy/bridges_chat.py`      Responses ⇄ Chat Completions 桥
  * `proxy/bridges_messages.py`  Responses ⇄ Anthropic Messages 桥（/v1/messages）
  * `proxy/toolfix.py`           工具调用 / JSON 参数 / 历史修正
  * `proxy/search_sidecar.py`    联网旁路（合成 web_search、shell 网络调用）
  * `proxy/muse.py`              Muse 兼容层（schema 修补、空转重试）
  * `proxy/apply_patch.py`       apply_patch 工具描述/参数改写
  * `proxy/sse.py`               SSE 流改写引擎
  * `proxy/server.py`            Proxy 类（路由/上游转发）+ main()

launchd 的入口仍然是 `$VISION_DIR/vision_proxy.py`，路径没变。
"""

from __future__ import annotations

import asyncio
import os
import sys

# 先把自己所在目录塞进 sys.path：老的测试用 spec_from_file_location 直接加载本文件，
# 那种加载方式不会把目录加进 sys.path，`import proxy.*` 会找不到模块。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from proxy import (  # noqa: E402
    apply_patch as _apply_patch,
    bridges_chat as _bridges_chat,
    bridges_messages as _bridges_messages,
    config as _config,
    muse as _muse,
    search_sidecar as _search_sidecar,
    server as _server,
    sse as _sse,
    toolfix as _toolfix,
)
from proxy.server import main  # noqa: E402

# 兼容层：tests/test_robust.py、tests/test_units.py 和 muse-codex-compat 的
# test_muse_compat.py 都是 spec_from_file_location("vp", "vision_proxy.py") 然后取
# `vp.<符号>`（如 vp._sanitize_muse_tool_schemas、vp.ChatBridgeTranslator）。
# 拆包后这些符号住在子模块里，这里把它们的顶层名字重新导出一遍 —— 纯转发，不改行为。
for _module in (_config, _bridges_chat, _bridges_messages, _toolfix, _search_sidecar,
                _muse, _apply_patch, _sse, _server):
    for _name in dir(_module):
        if not _name.startswith("__") and _name not in globals():
            globals()[_name] = getattr(_module, _name)


if __name__ == "__main__":
    asyncio.run(main())
