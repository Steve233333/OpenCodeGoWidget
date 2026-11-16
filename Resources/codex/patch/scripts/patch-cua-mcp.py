#!/usr/bin/env python3
"""Keep node_repl under OpenAI-signed Node processes in the patched app.

The browser-use native pipe checks the peer, its parent, and its grandparent.
In ChatGPT-Patched, node_repl is currently a direct child of the self-signed
Electron helper, so the indigenous runtime check rejects the connection. Insert
an OpenAI-signed Node wrapper between the official Codex CLI and node_repl.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 5:
        print(
            "usage: patch-cua-mcp.py MCP_JSON NODE_BIN WRAPPER NODE_REPL",
            file=sys.stderr,
        )
        return 2

    manifest = Path(sys.argv[1])
    node_bin = sys.argv[2]
    wrapper = sys.argv[3]
    node_repl = sys.argv[4]

    with manifest.open(encoding="utf-8") as handle:
        config = json.load(handle)

    server = config.get("mcpServers", {}).get("cua_repl")
    if not isinstance(server, dict):
        print(f"{manifest}: cua_repl server not found")
        return 1

    wanted_args = [wrapper, node_repl]
    if server.get("command") == node_bin and server.get("args") == wanted_args:
        print(f"{manifest}: CUA wrapper already installed")
        return 0

    server["command"] = node_bin
    server["args"] = wanted_args

    fd, temp_name = tempfile.mkstemp(
        prefix=f".{manifest.name}.", suffix=".tmp", dir=manifest.parent
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(config, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temp_name, manifest)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass

    print(f"{manifest}: CUA wrapper installed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
