#!/bin/bash
# 迁移链路的离线回归：
# ① 必须先写新 Key，再跑旧服务迁移，否则迁移会拿上一把 Key 做自检；
# ② 新 env 已存在时，迁移绝不能拿旧 env 覆盖；
# ③ 成功标记存在后必须幂等，不再反复搬旧运行态。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIGRATE="$ROOT/Resources/codex/scripts/migrate-to-agent-relay.sh"
STEP85="$ROOT/Resources/codex/setup/steps/85-preflight-heal.sh"
STEP90="$ROOT/Resources/codex/setup/steps/90-proxy.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "  ✅ $1"; }
bad() { echo "  ❌ $1"; fail=1; }

echo "==> 安装顺序护栏"
env_line="$(grep -nF 'mv "$ENV_FILE.new" "$ENV_FILE"' "$STEP90" | head -1 | cut -d: -f1)"
mig_line="$(grep -nF '"$_migrate" >>"$LOG"' "$STEP90" | head -1 | cut -d: -f1)"
if [ -n "$env_line" ] && [ -n "$mig_line" ] && [ "$env_line" -lt "$mig_line" ]; then
  ok "90-proxy 先落盘本次 Key（第 $env_line 行），再迁移（第 $mig_line 行）"
else
  bad "迁移早于新 Key 写入（env=${env_line:-无}, migrate=${mig_line:-无}）"
fi
if grep -qF 'stop_legacy' "$STEP85" || grep -qF 'bootout' "$STEP85"; then
  bad "85-preflight 在 Key 落盘前停旧服务（中途失败会没有可用代理）"
else
  ok "85-preflight 只报告，不在 Key 落盘前迁移/停旧服务"
fi

echo "==> 迁移不覆盖新 env / 新日志"
TEST_HOME="$TMP/home"
OLD="$TEST_HOME/.local/share/agent-vision-toolkit"
NEW="$TEST_HOME/.local/share/agent-relay"
OLD_CFG="$TEST_HOME/.config/agent-vision-toolkit"
NEW_CFG="$TEST_HOME/.config/agent-relay"
mkdir -p "$OLD" "$NEW" "$OLD_CFG" "$NEW_CFG" "$TEST_HOME/Library/LaunchAgents"
printf 'ZEN_API_KEY=old-expired-key\nVISION_MUSE_SCHEMA_FIX=1\n' > "$OLD_CFG/env"
printf 'ZEN_API_KEY=new-good-key\nRELAY_MUSE_SCHEMA_FIX=1\n' > "$NEW_CFG/env"
printf 'old-log\n' > "$OLD/relay.err.log"
printf 'new-log\n' > "$NEW/relay.err.log"
printf '<plist>old service</plist>\n' > "$TEST_HOME/Library/LaunchAgents/com.agent-vision-toolkit.proxy.plist"

out="$(HOME="$TEST_HOME" bash "$MIGRATE" --sandbox 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then ok "sandbox 迁移成功退出"; else bad "sandbox 迁移失败（rc=${rc}）：${out}"; fi
if grep -qF 'ZEN_API_KEY=new-good-key' "$NEW_CFG/env" && ! grep -qF 'old-expired-key' "$NEW_CFG/env"; then
  ok "新 env 的新 Key 未被旧 env 覆盖"
else
  bad "新 env 被旧 Key 覆盖：$(cat "$NEW_CFG/env")"
fi
if [ "$(cat "$NEW/relay.err.log")" = "new-log" ]; then
  ok "新服务日志未被旧日志覆盖"
else
  bad "新服务日志被旧日志覆盖"
fi
if [ ! -f "$TEST_HOME/Library/LaunchAgents/com.agent-vision-toolkit.proxy.plist" ] \
   && [ -f "$TEST_HOME/Library/LaunchAgents/com.agent-vision-toolkit.proxy.plist.bak-relay" ]; then
  ok "旧 plist 已摘除并留备份"
else
  bad "旧 plist 的退场/备份不正确"
fi

touch "$NEW/.legacy-vision-toolkit-migrated"
out2="$(HOME="$TEST_HOME" bash "$MIGRATE" --sandbox 2>&1)"
if echo "$out2" | grep -q '无需迁移'; then
  ok "完成标记存在时迁移幂等退出"
else
  bad "完成标记未阻止重复迁移：$out2"
fi

if [ "$fail" -eq 0 ]; then
  echo "全部通过 ✅"
  exit 0
fi
echo "有失败项 ❌"
exit 1
