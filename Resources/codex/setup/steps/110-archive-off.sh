#!/bin/zsh
# 步骤：9b. 已停用：超大对话自动归档
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径：zsh 默认会把被 source 文件的 $0 换掉，
#    路径推导统一放在主脚本（SCRIPT_DIR 已算好，直接用）。

# ---------------------------------------------------------------------------
# 9b. 已停用：超大对话自动归档（原来 >8MB 搬走导致恢复失败，2026-09-02 起停用）
#     更新时会清理旧的定时任务，并把之前搬走的对话搬回来
# ---------------------------------------------------------------------------
ARCHIVE_PLIST="$HOME/Library/LaunchAgents/com.steve233.codex-archive-rollouts.plist"
if [ -f "$ARCHIVE_PLIST" ]; then
  launchctl bootout "gui/$(id -u)" "$ARCHIVE_PLIST" 2>/dev/null || launchctl unload "$ARCHIVE_PLIST" 2>/dev/null || true
  rm -f "$ARCHIVE_PLIST"
  log "已清理旧的自动归档定时任务（>8MB 已停用）"
fi
# 也同步更新脚本为停用版（防止旧脚本残留继续搬）
ARCHIVE_SCRIPT="$CODEX_HOME/scripts/archive-large-rollouts.sh"
mkdir -p "$CODEX_HOME/scripts" "$CODEX_HOME/failed_rollouts"
if [ -f "$RES_DIR/scripts/archive-large-rollouts.sh" ]; then
  cp -p "$RES_DIR/scripts/archive-large-rollouts.sh" "$ARCHIVE_SCRIPT"
  chmod +x "$ARCHIVE_SCRIPT"
fi
# 把之前被搬走的对话搬回来（有就搬，没有就跳过）
if [ -d "$CODEX_HOME/failed_rollouts" ]; then
  restored=0
  setopt local_options null_glob 2>/dev/null || setopt null_glob 2>/dev/null || true
  for f in "$CODEX_HOME"/failed_rollouts/*.archived-*.jsonl; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    orig="${base%%.archived-*.jsonl}.jsonl"
    # 从文件名里取日期 2026-09-02
    if [[ "$orig" =~ rollout-([0-9]{4})-([0-9]{2})-([0-9]{2})T ]]; then
      y="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"; d="${BASH_REMATCH[3]}"
      dst_dir="$CODEX_HOME/sessions/$y/$m/$d"
      mkdir -p "$dst_dir"
      dst="$dst_dir/$orig"
      if [ ! -f "$dst" ]; then
        cp -p "$f" "$dst" 2>/dev/null && restored=$((restored+1))
        log "已恢复对话：$orig"
      fi
      # 搬回来后把旧的存档另存一份再删，避免重复
      mkdir -p "$CODEX_HOME/failed_rollouts.bak.$(date +%Y%m%d)"
      cp -p "$f" "$CODEX_HOME/failed_rollouts.bak.$(date +%Y%m%d)/" 2>/dev/null || true
      rm -f "$f"
    fi
  done
  if [ "$restored" -gt 0 ]; then
    log "共恢复 $restored 个之前被搬走的对话"
  fi
fi
log "自动归档已停用（>8MB 不再搬走）"
