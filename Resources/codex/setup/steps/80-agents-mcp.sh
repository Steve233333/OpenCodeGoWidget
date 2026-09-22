#!/bin/zsh
# 步骤：7. AGENTS.md 全局规则 + MCP 搜索
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径：zsh 默认会把被 source 文件的 $0 换掉，
#    路径推导统一放在主脚本（SCRIPT_DIR 已算好，直接用）。

# ---------------------------------------------------------------------------
# 7. AGENTS.md 全局规则 + MCP 搜索（opencode hosted, 仅 27 个无搜模型用）
# ---------------------------------------------------------------------------
cp -p "$RES_DIR/templates/AGENTS.md" "$CODEX_HOME/AGENTS.md"
cp -p "$RES_DIR/templates/AGENTS.md" "$HOME/.codex/AGENTS.md"
log "AGENTS.md 已安装"
# websearch MCP (Exa/Parallel hosted, no API key, 25s)
MCP_DIR="$HOME/.config/opencode/mcp"
MCP_SRC="$RES_DIR/mcp/websearch-server.py"
MCP_DST="$MCP_DIR/websearch-server.py"
if [[ -f "$MCP_SRC" ]]; then
  mkdir -p "$MCP_DIR"
  sync_newer_file "$MCP_SRC" "$MCP_DST"
  chmod +x "$MCP_DST"
  python3 -m py_compile "$MCP_DST" 2>/dev/null || true
  # 注入到副本 config.toml (mcp_servers.websearch)
  if ! grep -q "mcp_servers.websearch" "$CODEX_HOME/config.toml" 2>/dev/null; then
    cat >> "$CODEX_HOME/config.toml" <<MCP_EOF

[mcp_servers.websearch]
command = "python3"
args = ["-u", "$MCP_DST"]
MCP_EOF
    log "MCP 搜索已注入 (websearch → $MCP_DST, 27 个无搜模型用)"
  else
    log "MCP 搜索已存在，跳过注入"
  fi
fi
