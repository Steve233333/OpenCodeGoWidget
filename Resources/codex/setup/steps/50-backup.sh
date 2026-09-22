#!/bin/zsh
# 步骤：4. 备份旧配置
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径：zsh 默认会把被 source 文件的 $0 换掉，
#    路径推导统一放在主脚本（SCRIPT_DIR 已算好，直接用）。

# ---------------------------------------------------------------------------
# 4. 备份旧配置
# ---------------------------------------------------------------------------
TS="$(date '+%Y%m%d-%H%M%S')"
mkdir -p "$CODEX_HOME" "$HOME/.codex"
for f in config.toml models.json AGENTS.md; do
  if [[ -f "$CODEX_HOME/$f" ]]; then
    cp -p "$CODEX_HOME/$f" "$CODEX_HOME/$f.bak.$TS" 2>/dev/null || true
  fi
done
if [[ -f "$HOME/.codex/AGENTS.md" ]]; then
  cp -p "$HOME/.codex/AGENTS.md" "$HOME/.codex/AGENTS.md.bak.$TS" 2>/dev/null || true
fi
