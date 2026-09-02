#!/bin/bash
# 归档超大 rollout（>8MB），防止记忆管线 JSON 截断反复重试烧 mimo 额度
set -euo pipefail
THRESHOLD="+8M"
SRC_BASE="${CODEX_HOME:-$HOME/.codex-deepseek}/sessions"
DST_BASE="${CODEX_HOME:-$HOME/.codex-deepseek}/failed_rollouts"
LOG_FILE="${CODEX_HOME:-$HOME/.codex-deepseek}/failed_rollouts/archive.log"
mkdir -p "$DST_BASE"
now="$(date +%Y-%m-%dT%H:%M:%S%z)"
found=0
while IFS= read -r -d '' f; do
  base="$(basename "$f")"
  ts="$(date +%Y%m%d-%H%M%S)"
  dst="$DST_BASE/${base%.jsonl}.archived-${ts}.jsonl"
  if [ -f "$dst" ]; then continue; fi
  size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo "?")
  echo "[$now] archive $f (${size} bytes) -> $dst" | tee -a "$LOG_FILE" 2>/dev/null || echo "[$now] archive $f -> $dst"
  mv "$f" "$dst" 2>/dev/null && found=$((found+1)) || echo "failed to mv $f"
done < <(find "$SRC_BASE" -type f -name "rollout-*.jsonl" -size "$THRESHOLD" -print0 2>/dev/null)
if [ "$found" -gt 0 ]; then
  echo "[$now] done, archived $found file(s)" | tee -a "$LOG_FILE" 2>/dev/null || true
fi
if command -v sqlite3 >/dev/null 2>&1; then
  DB="${CODEX_HOME:-$HOME/.codex-deepseek}/memories_1.sqlite"
  if [ -f "$DB" ]; then
    sqlite3 "$DB" "DELETE FROM jobs WHERE kind='memory_stage1' AND status IN ('error','running');" 2>/dev/null || true
  fi
fi
