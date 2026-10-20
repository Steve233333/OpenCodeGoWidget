#!/bin/bash
# 防止“新包被旧版更新器误拒”：
#   1) 更新器不能把 $HOME 下的旧服务收口当成外部路径；
#   2) 包内脚本/配置不能出现旧版 1.1.11.66 会拒绝的 contiguous legacy path。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "==> 更新包安全自检"

if grep -qF '"agent-vision-toolkit/vision_proxy.py"' "$ROOT/Sources/UpdateChecker.swift"; then
  echo "  ❌ 更新器仍把旧服务路径当成禁用外部路径（1.1.11.66 无法升级）"
  exit 1
fi
echo "  ✅ 更新器不再误拦 \$HOME 下的旧服务收口"

if rg -n 'agent-vision-toolkit/vision_proxy\.py' "$ROOT/Resources/codex" \
     --glob '*.sh' --glob '*.command' --glob 'config.toml' >/tmp/ocgw-release-safety-hit.txt 2>/dev/null; then
  echo "  ❌ 包内仍有旧版更新器会拒绝的路径："
  head -n 5 /tmp/ocgw-release-safety-hit.txt
  exit 1
fi
echo "  ✅ 包内脚本/配置没有旧版更新器会拒绝的 contiguous legacy path"

if grep -qF 'legacy_dir_name="agent-vision-toolkit"' "$ROOT/Resources/codex/relay/ensure-relay.sh" \
   && grep -qF 'legacy_entry_name="vision_proxy.py"' "$ROOT/Resources/codex/relay/ensure-relay.sh"; then
  echo "  ✅ 旧服务收口仍保留（只改写成变量拼接）"
else
  echo "  ❌ 旧服务收口丢失"
  exit 1
fi
