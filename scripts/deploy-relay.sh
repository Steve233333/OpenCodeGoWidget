#!/bin/bash
# 部署代理到运行目录 —— **自带冒烟 + 失败自动回滚**（2026-09-23）。
#
# 为什么要它：今天我把 `pipeline.py` 的重构直接部署上去才跑冒烟，结果四家族全 502
# （`NameError: incoming_headers`），你的 Codex 先踩到了。以后统一走这个脚本：
#   备份 → 同步 → 强制重启 → 冒烟 → 失败就恢复备份并重启 → 非 0 退出
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Resources/codex/relay"
RELAY_HOME="${RELAY_HOME:-$HOME/.local/share/agent-relay}"
BACKUP="$RELAY_HOME/.backup-$(date +%Y%m%d%H%M%S)"

echo "==> 备份当前运行目录 → $BACKUP"
mkdir -p "$BACKUP"
(cd "$RELAY_HOME" && find . -type f -not -path './.backup-*/*' -print0 | while IFS= read -r -d '' rel; do
  mkdir -p "$BACKUP/$(dirname "$rel")"; cp -p "$rel" "$BACKUP/$rel"
done)

echo "==> 同步新代码"
(cd "$SRC" && find . -type f -not -path './__pycache__/*' -not -path '*/__pycache__/*' -not -name '*.pyc' -print0 |
  while IFS= read -r -d '' rel; do mkdir -p "$RELAY_HOME/$(dirname "$rel")"; cp -p "$rel" "$RELAY_HOME/$rel"; done)
chmod +x "$RELAY_HOME/ensure-relay.sh" 2>/dev/null || true

echo "==> 强制重启代理（换新代码）"
"$RELAY_HOME/ensure-relay.sh" --trigger manual --force-restart --quiet

echo "==> 冒烟（四家族）"
if "$ROOT/scripts/smoke-conversion.sh"; then
  echo "✅ 部署完成并冒烟通过（备份留在 ${BACKUP}）"
  exit 0
fi

echo "!! 冒烟没过 → 回滚到备份"
(cd "$BACKUP" && find . -type f -print0 | while IFS= read -r -d '' rel; do
  mkdir -p "$RELAY_HOME/$(dirname "$rel")"; cp -p "$rel" "$RELAY_HOME/$rel"
done)
"$RELAY_HOME/ensure-relay.sh" --trigger manual --force-restart --quiet
if "$ROOT/scripts/smoke-conversion.sh"; then
  echo "已回滚，代理恢复可用（坏的代码没上线）"
else
  echo "!! 回滚后仍冒烟失败，人工介入：$RELAY_HOME"
fi
exit 1
