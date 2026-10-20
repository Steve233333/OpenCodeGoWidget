#!/bin/bash
# 更新模式下 config.toml 缺失/为空时必须从模板生成，而不是在生成前提前失败。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
ok(){ echo "  ✅ $1"; }
bad(){ echo "  ❌ $1"; fail=1; }

run_case() {
  local name="$1" seed="$2"
  local home="$TMP/$name"
  mkdir -p "$home/codex" "$home/res/templates"
  cp "$ROOT/Resources/codex/templates/config.toml" "$home/res/templates/config.toml"
  case "$seed" in
    empty) : > "$home/codex/config.toml" ;;
    existing) printf 'model = "old"\nmodel_provider = "deepseek"\n[model_providers.deepseek]\nbase_url = "https://old.example"\nwire_api = "responses"\nexperimental_bearer_token = "old"\n' > "$home/codex/config.toml" ;;
  esac
  TMPROOT="$home" zsh -c '
    log(){ :; }; die(){ echo "$*"; exit 1; }
    CODEX_HOME="$TMPROOT/codex"; RES_DIR="$TMPROOT/res"
    HAS_DS=0; HAS_GO=1; DS_KEY=""; DEFAULT_MODEL=""
    AVAIL_SLUGS="mimo-v2.5-go glm-5.3-go"
    source "'"$ROOT"'/Resources/codex/setup/steps/70-defaults.sh"
  ' >/tmp/ocgw-config-case.log 2>&1 || { bad "${name}：脚本失败：$(tail -2 /tmp/ocgw-config-case.log | tr '\n' ' ')"; return; }
  local cfg="$home/codex/config.toml"
  if [ -s "$cfg" ] && grep -q '^model = "mimo-v2.5-go"' "$cfg" \
     && grep -q '^base_url = "http://127.0.0.1:19100"' "$cfg" \
     && grep -q '^experimental_bearer_token = "sk-relay-placeholder"' "$cfg"; then
    ok "${name}：config.toml 可生成且关键字段正确"
  else
    bad "${name}：config.toml 内容不对"
  fi
}

echo "==> config.toml 生成自检（缺失 / 空 / 已有）"
run_case missing none
run_case empty empty
run_case existing existing

if [ "$fail" -eq 0 ]; then echo "全部通过 ✅"; exit 0; fi
echo "有失败项 ❌"; exit 1
