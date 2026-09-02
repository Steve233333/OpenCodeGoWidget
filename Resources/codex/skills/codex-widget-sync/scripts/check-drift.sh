#!/bin/bash
# 说大白话：比一下老大和小弟是不是一样，不一样就报错不让打包
set -euo pipefail

WIDGET_DIR="$(cd "$(dirname "$0")/../../../../.." && pwd)"
if [ ! -d "$WIDGET_DIR/Resources/codex" ]; then
  WIDGET_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
fi

RED="\033[0;31m"
GREEN="\033[0;32m"
NC="\033[0m"

fail=0

say_ok() { echo -e "${GREEN}没问题：$1${NC}"; }
say_bad() { echo -e "${RED}不一样：$1${NC}"; fail=1; }

echo "开始比：电脑 vs 小组件"
echo "================================"

# 1. 看看搬大对话的开关是不是关掉了
ARCHIVE="$WIDGET_DIR/Resources/codex/scripts/archive-large-rollouts.sh"
if [ -f "$ARCHIVE" ]; then
  if grep -q "已停用" "$ARCHIVE" && grep -q "exit 0" "$ARCHIVE"; then
    say_ok "搬大对话的开关已关掉"
  elif grep -q "THRESHOLD" "$ARCHIVE"; then
    say_bad "搬大对话的开关还开着（小组件里还有 THRESHOLD）"
    echo "   去改 $ARCHIVE，改成已停用的版本"
  else
    say_ok "搬大对话脚本看起来没问题"
  fi
else
  say_bad "找不到 $ARCHIVE"
fi

# 2. 看看安装器里还有没有自动安装归档的
INSTALLER="$WIDGET_DIR/Resources/codex/codex-oneclick-setup.command"
if grep -q "com.steve233.codex-archive-rollouts" "$INSTALLER" && grep -q "START.*3600" "$INSTALLER" 2>/dev/null; then
  # 老的安装器会写定时任务
  if grep -q "已停用" "$INSTALLER"; then
    say_ok "安装器里已改成停用并会清理旧任务"
  else
    say_bad "安装器里还在安装定时任务（会重新打开开关）"
  fi
else
  if grep -q "已清理旧的自动归档" "$INSTALLER"; then
    say_ok "安装器已改成清理旧任务"
  else
    say_bad "安装器里找不到清理旧任务的代码"
  fi
fi

# 3. 比一下几个重要文件是不是跟电脑上一样（只比有没有大不同，不比 key）
for pair in \
  "vision/vision_proxy.py:$HOME/.local/share/agent-vision-toolkit/vision_proxy.py" \
  "patch/patch.sh:$HOME/.codex/picker-patch/patch.sh" \
  "mcp/websearch-server.py:$HOME/.config/opencode/mcp/websearch-server.py"
do
  rel="${pair%%:*}"
  home_path="${pair##*:}"
  widget_path="$WIDGET_DIR/Resources/codex/$rel"
  if [ ! -f "$widget_path" ]; then
    say_bad "$rel 小组件里没有"
    continue
  fi
  if [ ! -f "$home_path" ]; then
    echo "跳过比 $rel（电脑上没有 $home_path）"
    continue
  fi
  if diff -q "$widget_path" "$home_path" >/dev/null 2>&1; then
    say_ok "$rel 跟电脑上一样"
  else
    # 允许一点点不一样（比如占位符），只报大不同
    lines_diff=$(diff -u "$widget_path" "$home_path" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$lines_diff" -gt 20 ]; then
      say_bad "$rel 跟电脑上差很多（$lines_diff 行）"
      echo "   跑 sync-from-home.sh 同步一下"
    else
      say_ok "$rel 只有一点小不同（$lines_diff 行），算过"
    fi
  fi
done

# 4. 看看搜索那块是不是双路的
WSS="$WIDGET_DIR/Resources/codex/mcp/websearch-server.py"
if [ -f "$WSS" ]; then
  if grep -q "_delegate_via_deepseek" "$WSS" && grep -q "DIRECT_OPENER" "$WSS"; then
    say_ok "搜索是双路的（会托给 deepseek 代搜）"
  else
    say_bad "搜索还是老版（没双路/代搜）"
  fi
else
  say_bad "找不到 mcp/websearch-server.py"
fi

# 5. 看看 models.json 是不是正常的
if [ -f "$WIDGET_DIR/Resources/codex/templates/models.json" ]; then
  cnt=$(python3 -c 'import json;print(len(json.load(open("'"$WIDGET_DIR/Resources/codex/templates/models.json"'") )["models"]))' 2>/dev/null || echo 0)
  if [ "$cnt" -gt 10 ]; then
    say_ok "models.json 有 $cnt 个模型"
  else
    say_bad "models.json 只有 $cnt 个模型，可能不全"
  fi
else
  say_bad "找不到 templates/models.json"
fi

echo "================================"
if [ "$fail" -eq 0 ]; then
  echo -e "${GREEN}都对上了，可以打包了${NC}"
  exit 0
else
  echo -e "${RED}还有不一样的，改完再打包${NC}"
  exit 1
fi
