#!/bin/bash
# 说大白话：把电脑上的老大文件，抄给小组件里的小弟
set -euo pipefail

HOME_DIR="${HOME}"
WIDGET_DIR="$(cd "$(dirname "$0")/../../../../.." && pwd)"
# WIDGET_DIR 指向 OpenCodeGoWidget-main 根
if [ ! -d "$WIDGET_DIR/Resources/codex" ]; then
  WIDGET_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
fi

echo "老大在哪：$HOME_DIR/.codex-deepseek"
echo "小弟在哪：$WIDGET_DIR/Resources/codex"
echo ""

sync_one() {
  local src="$1"
  local dst="$2"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
    echo "已抄：$src -> $dst"
  else
    echo "跳过（老大没有这个文件）：$src"
  fi
}

# 配置
sync_one "$HOME_DIR/.codex-deepseek/config.toml" "$WIDGET_DIR/Resources/codex/templates/config.toml"
# 但模板里要有占位符，不能直接抄真的 key，抄完要替换回占位符
if [ -f "$WIDGET_DIR/Resources/codex/templates/config.toml" ]; then
  # 把真的 key 换回占位符，保持模板干净
  python3 - "$WIDGET_DIR/Resources/codex/templates/config.toml" <<'PY'
import re, pathlib
p = pathlib.Path("/Users/steve233/Desktop/OpenCodeGoWidget-main/Resources/codex/templates/config.toml")
t = p.read_text()
# 把具体值换回占位符，方便下次安装时填
t = re.sub(r'model = ".*"', 'model = "__DEFAULT_MODEL__"', t, count=1)
t = re.sub(r'model_reasoning_effort = ".*"', 'model_reasoning_effort = "__REASONING_EFFORT__"', t, count=1)
t = re.sub(r'base_url = ".*"', 'base_url = "__BASE_URL__"', t, count=1)
t = re.sub(r'experimental_bearer_token = ".*"', 'experimental_bearer_token = "__BEARER__"', t, count=1)
t = re.sub(r'extract_model = ".*"', 'extract_model = "__EXTRACT_MODEL__"', t)
t = re.sub(r'consolidation_model = ".*"', 'consolidation_model = "__CONSOLIDATION_MODEL__"', t)
p.write_text(t)
print("已把 config.toml 换回占位符")
PY
fi

sync_one "$HOME_DIR/.codex-deepseek/models.json" "$WIDGET_DIR/Resources/codex/templates/models.json"
sync_one "$HOME_DIR/.local/share/agent-vision-toolkit/vision_proxy.py" "$WIDGET_DIR/Resources/codex/vision/vision_proxy.py"
sync_one "$HOME_DIR/.codex-deepseek/scripts/archive-large-rollouts.sh" "$WIDGET_DIR/Resources/codex/scripts/archive-large-rollouts.sh"
sync_one "$HOME/.codex/picker-patch/patch.sh" "$WIDGET_DIR/Resources/codex/patch/patch.sh"
sync_one "$HOME/.codex/picker-patch/certs/ent2.plist" "$WIDGET_DIR/Resources/codex/patch/ent2.plist"
sync_one "$HOME/.config/opencode/mcp/websearch-server.py" "$WIDGET_DIR/Resources/codex/mcp/websearch-server.py"

echo ""
echo "抄完了，快跑一下 check-drift.sh 看看还有没有不一样的"
