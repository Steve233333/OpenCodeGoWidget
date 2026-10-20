#!/bin/bash
# 安装器安全护栏：用户数据不能被“点一次配置”悄悄覆盖。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "  ✅ $1"; }
bad() { echo "  ❌ $1"; fail=1; }

echo "==> 安装器安全自检"

# AGENTS.md：行为级验证“只在缺失时安装”，已有用户内容必须原样保留。
snippet="$(sed -n '/^install_agents_template()/,/^}/p' "$ROOT/Resources/codex/setup/steps/80-agents-mcp.sh")"
if [ -n "$snippet" ]; then
  (
    set -uo pipefail
    RES_DIR="$TMP/res"
    mkdir -p "$RES_DIR/templates"
    printf 'template\n' > "$RES_DIR/templates/AGENTS.md"
    log() { :; }
    eval "$snippet"
    printf 'my custom rules\n' > "$TMP/user.md"
    install_agents_template "$TMP/user.md"
    [ "$(cat "$TMP/user.md")" = "my custom rules" ] || exit 1
    install_agents_template "$TMP/new.md"
    [ "$(cat "$TMP/new.md")" = "template" ] || exit 2
  )
  rc=$?
  if [ "$rc" = 0 ]; then ok "AGENTS.md：保留用户内容，仅缺失时写入模板"; else bad "AGENTS.md 被覆盖或未安装（rc=${rc}）"; fi
else
  bad "找不到 install_agents_template（80-agents-mcp 结构变了）"
fi

# 退出码：关键项失败时安装器不能以 0 结束。
if grep -qF '_critical_fail' "$ROOT/Resources/codex/codex-oneclick-setup.command" \
   && grep -qF 'exit 1' "$ROOT/Resources/codex/codex-oneclick-setup.command"; then
  ok "关键项失败会返回非 0"
else
  bad "安装器仍可能把失败报成成功"
fi

# 纯 DeepSeek 模式：没有 Go Key 时不能拿代理状态判失败。
if grep -qF '${USE_PROXY:-0}" -eq 1 && "$SKIP_PROXY_START" -eq 0' "$ROOT/Resources/codex/codex-oneclick-setup.command"; then
  ok "纯 DeepSeek 模式不会因代理未启动而报失败"
else
  bad "纯 DeepSeek 模式仍会被代理状态误判"
fi

# 旧服务：必须只按完整旧入口路径结束，不能模糊杀 python。
if grep -qF 'agent-vision-toolkit/vision_proxy.py' "$ROOT/Resources/codex/relay/ensure-relay.sh"; then
  ok "旧 vision_proxy 仅按精确路径识别"
else
  bad "旧服务收口规则缺失"
fi

if [ "$fail" = 0 ]; then echo "全部通过 ✅"; exit 0; fi
echo "有失败项 ❌"; exit 1
