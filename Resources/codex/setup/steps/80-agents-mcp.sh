#!/bin/zsh
# 步骤：7. AGENTS.md 全局规则 + MCP 搜索
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径：zsh 默认会把被 source 文件的 $0 换掉，
#    路径推导统一放在主脚本（SCRIPT_DIR 已算好，直接用）。

# ---------------------------------------------------------------------------
# 7. AGENTS.md 全局规则 + MCP 搜索（opencode hosted, 仅 27 个无搜模型用）
# ---------------------------------------------------------------------------
# 2026-10-20：用户可能已经在 AGENTS.md 写了自己的规则；安装器不能每次点配置都覆盖。
# 只补缺失，或把内容完全相同的模板视为无需变更；有差异时保留用户文件并备份模板副本。
install_agents_template() {
  local dst="$1" src="$RES_DIR/templates/AGENTS.md"
  if [ ! -f "$dst" ]; then
    cp -p "$src" "$dst" 2>/dev/null && log "AGENTS.md 已安装：${dst}" || log "WARN: AGENTS.md 安装失败：${dst}"
  elif cmp -s "$src" "$dst"; then
    log "AGENTS.md 已是模板内容，无需变更：${dst}"
  else
    log "AGENTS.md 已有自定义内容，保留不覆盖：${dst}（模板见 ${src}）"
  fi
}
install_agents_template "$CODEX_HOME/AGENTS.md"
install_agents_template "$HOME/.codex/AGENTS.md"
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
