#!/bin/zsh
# =============================================================================
# Codex 一键配置安装器（macOS）
# 双击本文件即可；也可在终端手动运行：
#   ./codex-oneclick-setup.command
# 交互：双击后会先让你选“安装 / 更新”；更新模式无需重填 Key
# 高级参数（测试/无人值守）：
#   --noninteractive     使用 ONECLICK_GO_KEY / ONECLICK_DS_KEY /
#                        ONECLICK_GLM_KEY / ONECLICK_PASS 环境变量，不弹窗
#   --skip-patch         不重建 ChatGPT-Patched.app（只生成配置）
#   --skip-proxy-start   生成代理文件但不启动 launchd 服务
#   --update               直接进入更新模式（不弹窗，复用旧 Key）
#   --install              直接进入安装模式（弹窗填 Key）
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$HOME/Library/Logs/codex-oneclick-setup.log"
mkdir -p "$(dirname "$LOG")"

NONINTERACTIVE=0
SKIP_PATCH=0
SKIP_PROXY_START=0
for arg in "$@"; do
  case "$arg" in
    --noninteractive) NONINTERACTIVE=1 ;;
    --skip-patch) SKIP_PATCH=1 ;;
    --skip-proxy-start) SKIP_PROXY_START=1 ;;
  esac
done

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

die() {
  log "ERROR: $*"
  if [[ "$NONINTERACTIVE" -eq 0 ]]; then
    osascript - "$*" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display dialog (item 1 of argv) with title "Codex 一键配置安装器" buttons {"好"} default button "好" with icon stop
end run
APPLESCRIPT
  fi
  exit 1
}

ask_hidden() {
  osascript - "$1" "$2" "$3" <<'APPLESCRIPT'
on run argv
  set thePrompt to item 1 of argv
  set theTitle to item 2 of argv
  set theDefault to item 3 of argv
  set oldDelims to AppleScript's text item delimiters
  set AppleScript's text item delimiters to "\\n"
  set theParts to every text item of thePrompt
  set AppleScript's text item delimiters to linefeed
  set thePrompt to theParts as text
  set AppleScript's text item delimiters to oldDelims
  try
    set theAnswer to text returned of (display dialog thePrompt with title theTitle default answer theDefault with hidden answer buttons {"取消", "继续"} default button "继续" cancel button "取消")
    return theAnswer
  on error
    return "__CANCEL__"
  end try
end run
APPLESCRIPT
}

ask_plain() {
  osascript - "$1" "$2" "$3" <<'APPLESCRIPT'
on run argv
  set thePrompt to item 1 of argv
  set theTitle to item 2 of argv
  set theDefault to item 3 of argv
  set oldDelims to AppleScript's text item delimiters
  set AppleScript's text item delimiters to "\\n"
  set theParts to every text item of thePrompt
  set AppleScript's text item delimiters to linefeed
  set thePrompt to theParts as text
  set AppleScript's text item delimiters to oldDelims
  try
    set theAnswer to text returned of (display dialog thePrompt with title theTitle default answer theDefault buttons {"取消", "继续"} default button "继续" cancel button "取消")
    return theAnswer
  on error
    return "__CANCEL__"
  end try
end run
APPLESCRIPT
}

show_info() {
  osascript - "$1" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display dialog (item 1 of argv) with title "Codex 一键配置安装器" buttons {"好"} default button "好" with icon note
end run
APPLESCRIPT
}

ask_choice() {
  osascript - "$1" "$2" <<'APPLESCRIPT'
on run argv
  set thePrompt to item 1 of argv
  set theTitle to item 2 of argv
  try
    set theAnswer to button returned of (display dialog thePrompt with title theTitle buttons {"更新", "安装"} default button "安装" with icon note)
    return theAnswer
  on error
    return "__CANCEL__"
  end try
end run
APPLESCRIPT
}

# ---------------------------------------------------------------------------
# 0. 模式选择：安装 / 更新
# ---------------------------------------------------------------------------
MODE="install"
# CLI 指定
for arg in "$@"; do
  case "$arg" in
    --update) MODE="update" ;;
    --install) MODE="install" ;;
  esac
done

if [[ "$NONINTERACTIVE" -eq 0 ]]; then
  # 如果未通过 CLI 指定，弹窗让用户选择
  NEED_CHOICE=1
  for arg in "$@"; do
    case "$arg" in
      --update|--install) NEED_CHOICE=0 ;;
    esac
  done
  if [[ "$NEED_CHOICE" -eq 1 ]]; then
    CHOICE="$(ask_choice "请选择操作：\n\n● 安装：全新安装/重装，需要填写 Key（留空沿用旧 Key）\n● 更新：已安装过的机器，一键更新修复/模板/视觉代理，无需重新填 Key" "Codex 一键配置安装器")"
    if [[ "$CHOICE" == "__CANCEL__" ]]; then
      die "已取消"
    elif [[ "$CHOICE" == "更新" ]]; then
      MODE="update"
    else
      MODE="install"
    fi
  fi
fi

# 更新模式：提前校验是否存在旧安装
CODEX_HOME="$HOME/.codex-deepseek"
ENV_FILE="$HOME/.config/agent-vision-toolkit/env"
PATCH_BASE="$HOME/.codex/picker-patch"
PASS_FILE="$PATCH_BASE/.keychain-pass"

if [[ "$MODE" == "update" ]]; then
  if [[ ! -f "$CODEX_HOME/config.toml" && ! -f "$ENV_FILE" ]]; then
    if [[ "$NONINTERACTIVE" -eq 1 ]]; then
      die "更新模式下未检测到现有安装（~/.codex-deepseek/config.toml 与 ~/.config/agent-vision-toolkit/env 均不存在），请改用 安装 模式。"
    else
      # 友好提示并切回安装
      osascript - "未检测到现有安装，将为你切换到“安装”模式。\n\n请继续填写 Key 完成首次安装。" "Codex 一键配置安装器" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display dialog (item 1 of argv) with title "Codex 一键配置安装器" buttons {"好"} default button "好" with icon note
end run
APPLESCRIPT
      MODE="install"
    fi
  else
    log "模式：更新（复用现有 Key，不重新输入）"
  fi
else
  log "模式：安装"
fi

# ---------------------------------------------------------------------------
# 1. 读取/收集三个 Key（全可选，但 Go 与 DeepSeek 至少一个）
# ---------------------------------------------------------------------------
EXISTING_GO="$(grep '^ZEN_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
EXISTING_DS="$(awk -F'"' '/^experimental_bearer_token *=/{print $2}' "$CODEX_HOME/config.toml" 2>/dev/null | head -1 || true)"
EXISTING_GLM="$(grep '^VISION_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"

GO_KEY=""
DS_KEY=""
GLM_KEY=""
PASS=""

if [[ "$MODE" == "update" ]]; then
  # 更新模式：直接沿用现有 Key，不弹窗
  GO_KEY="$EXISTING_GO"
  DS_KEY="$EXISTING_DS"
  GLM_KEY="$EXISTING_GLM"
  # 去空格
  GO_KEY="${GO_KEY// /}"
  DS_KEY="${DS_KEY// /}"
  GLM_KEY="${GLM_KEY// /}"
  if [[ -z "$GO_KEY" && -z "$DS_KEY" ]]; then
    die "更新模式下未找到任何 Key（Go 与 DeepSeek 均为空）。请改用“安装”并填写至少一个 Key。"
  fi
  log "更新模式：沿用 Go=\${#GO_KEY}位 DeepSeek=\${#DS_KEY}位 GLM=\${#GLM_KEY}位（不重新输入）"
  # 更新模式下密码也直接复用，不再询问（除非缺失）
  if [[ -f "$PASS_FILE" && -z "$PASS" ]]; then
    PASS="$(cat "$PASS_FILE" 2>/dev/null || true)"
  fi
else
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    GO_KEY="${ONECLICK_GO_KEY:-}"
    DS_KEY="${ONECLICK_DS_KEY:-}"
    GLM_KEY="${ONECLICK_GLM_KEY:-}"
    PASS="${ONECLICK_PASS:-}"
  else
    GO_KEY="$(ask_hidden "OpenCode Go / Zen 订阅 Key（必填其一）\n\n请粘贴你的 sk-... key。\n\n缺这个 key 的后果：所有 *-go 模型（deepseek-go / mimo / glm / luna / muse 等）不会安装，只能使用官方 DeepSeek。" "① OpenCode Go Key" "")"
    [[ "$GO_KEY" == "__CANCEL__" ]] && die "已取消安装"
    DS_KEY="$(ask_hidden "DeepSeek 官方 API Key（可选）\n\n请粘贴 sk-... key。\n\n缺这个 key 的后果：官方 deepseek-v4-flash-vision-exp / deepseek-v4-pro 两个模型不会显示，默认模型会自动改走 Go 模型。" "② DeepSeek Key" "")"
    [[ "$DS_KEY" == "__CANCEL__" ]] && die "已取消安装"
    GLM_KEY="$(ask_hidden "智谱 GLM 视觉 Key（可选）\n\n请粘贴 open.bigmodel.cn 的 key（格式类似 1234.xxxx）。\n\n缺这个 key 的后果：Codex 文本对话不受影响，但发图片会失败；之后可随时补填到 ~/.config/agent-vision-toolkit/env。" "③ 智谱 GLM 视觉 Key" "")"
    [[ "$GLM_KEY" == "__CANCEL__" ]] && die "已取消安装"
  fi

  # 去空格；留空时回落到现有配置（重复安装/更新 key 场景）
  GO_KEY="${GO_KEY// /}"
  DS_KEY="${DS_KEY// /}"
  GLM_KEY="${GLM_KEY// /}"
  GO_KEY="${GO_KEY:-$EXISTING_GO}"
  DS_KEY="${DS_KEY:-$EXISTING_DS}"
  GLM_KEY="${GLM_KEY:-$EXISTING_GLM}"

  if [[ -z "$GO_KEY" && -z "$DS_KEY" ]]; then
    die "至少需要 OpenCode Go 或 DeepSeek 其中一个 key，请重新运行安装器。"
  fi
fi
for k in "$GO_KEY" "$DS_KEY" "$GLM_KEY"; do
  if [[ -n "$k" && "${#k}" -lt 8 ]]; then
    die "检测到疑似无效的 key（长度过短），请检查后重试。"
  fi
done

HAS_GO=0; HAS_DS=0; HAS_GLM=0
[[ -n "$GO_KEY" ]] && HAS_GO=1
[[ -n "$DS_KEY" ]] && HAS_DS=1
[[ -n "$GLM_KEY" ]] && HAS_GLM=1

log "输入校验通过：Go=$HAS_GO DeepSeek=$HAS_DS GLM=$HAS_GLM"

# ---------------------------------------------------------------------------
# 2. 签名密码：强制自定义（不允许 0000 默认）
#    已有 PASS_FILE 则复用；否则必须让用户输入自定义密码（≥4位，且≠0000）
# ---------------------------------------------------------------------------
if [[ "$SKIP_PATCH" -eq 0 ]]; then
  if [[ -f "$PASS_FILE" && -z "$PASS" ]]; then
    PASS="$(cat "$PASS_FILE" 2>/dev/null || true)"
    PASS="${PASS// /}"
    if [[ -n "$PASS" && "$PASS" == "0000" ]]; then
      if [[ "$MODE" == "update" ]]; then
        log "WARN: 检测到旧密码 0000（更新模式暂沿用，下次安装请改为自定义）"
        # keep 0000 for this update round to not break existing 0000 keychain
      else
        log "WARN: 检测到旧密码为 0000，请重新设置为自定义密码"
        PASS=""
      fi
    fi
  fi
  if [[ -z "$PASS" && "$NONINTERACTIVE" -eq 1 ]]; then
    PASS="${ONECLICK_PASS:-}"
    PASS="${PASS// /}"
    if [[ -z "$PASS" ]]; then
      die "缺少签名钥匙串密码：请设置环境变量 ONECLICK_PASS 后重试。"
    fi
  fi
  if [[ -z "$PASS" && "$MODE" == "update" && -f "$HOME/Library/Keychains/codex-signing.keychain-db" ]]; then
    # 老机器无 PASS_FILE 但钥匙串已是 0000，更新时静默沿用避免打断
    log "WARN: 未找到密码文件，检测到现有钥匙串，更新模式暂沿用 0000（建议下次安装改为自定义）"
    PASS="0000"
  fi
  if [[ -z "$PASS" ]]; then
    while true; do
      _tmp_pass="$(ask_hidden "请设置签名钥匙串密码（必填）\n\n将保存在 ~/.codex/picker-patch/.keychain-pass（600），用于创建本地签名钥匙串。请务必记好，副本升级时会复用。" "签名钥匙串密码" "")"
      [[ "$_tmp_pass" == "__CANCEL__" ]] && die "已取消安装"
      _tmp_pass="${_tmp_pass// /}"
      if [[ -z "$_tmp_pass" ]]; then
        osascript - "密码不能为空，请重新输入。" "Codex 一键配置安装器" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display dialog (item 1 of argv) with title "Codex 一键配置安装器" buttons {"好"} default button "好" with icon stop
end run
APPLESCRIPT
        continue
      fi
      PASS="$_tmp_pass"
      break
    done
  fi
  log "签名钥匙串密码：已设置（${#PASS} 位，自定义）"
fi

# 自签证书现场生成（新机无证书时）
ensure_codex_signing_cert() {
  local certs_dir="$PATCH_BASE/certs"
  local crt="$certs_dir/codex-sign2.crt"
  local key="$certs_dir/codex-sign2.key"
  local p12="$certs_dir/codex-sign2.p12"
  local kc="$HOME/Library/Keychains/codex-signing.keychain-db"
  mkdir -p "$certs_dir"
  if [[ -f "$crt" && -f "$key" && -f "$p12" ]]; then
    log "签名证书已存在，跳过生成"
    # 确保钥匙串已导入（使用当前自定义 PASS）
    if [[ -f "$kc" ]]; then
      security unlock-keychain -p "$PASS" "$kc" >>"$LOG" 2>&1 || true
      security import "$p12" -k "$kc" -P codex123 -T /usr/bin/codesign -T /usr/bin/security >>"$LOG" 2>&1 || true
    fi
    return 0
  fi
  log "生成本机自签证书 Codex Patched Signing (RSA2048, 10年)..."
  local extfile
  extfile="$(mktemp)"
  cat > "$extfile" <<'EXTEOF'
basicConstraints=critical,CA:true
keyUsage=critical,digitalSignature,keyCertSign,cRLSign
extendedKeyUsage=codeSigning
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer
EXTEOF
  if ! openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$key" -out "$crt" -days 3650 \
    -subj "/OU=2DC432GLL2/CN=Codex Patched Signing/O=steve233" \
    -extfile "$extfile" >>"$LOG" 2>&1; then
    log "WARN: openssl 生成证书失败，将回退到 ad-hoc 签名"
    rm -f "$extfile"
    return 1
  fi
  rm -f "$extfile"
  chmod 600 "$key" 2>/dev/null || true
  if ! openssl pkcs12 -export -legacy -out "$p12" -inkey "$key" -in "$crt" -password pass:codex123 >>"$LOG" 2>&1; then
    openssl pkcs12 -export -out "$p12" -inkey "$key" -in "$crt" -password pass:codex123 >>"$LOG" 2>&1 || true
  fi
  chmod 600 "$p12" 2>/dev/null || true
  if [[ ! -f "$kc" ]]; then
    security create-keychain -p "$PASS" "$kc" >>"$LOG" 2>&1 || true
  fi
  security unlock-keychain -p "$PASS" "$kc" >>"$LOG" 2>&1 || true
  security import "$p12" -k "$kc" -P codex123 -T /usr/bin/codesign -T /usr/bin/security >>"$LOG" 2>&1 || true
  security set-keychain-settings -t 3600 -l -u "$kc" >>"$LOG" 2>&1 || true
  # 加入搜索列表
  if ! security list-keychains -d user 2>&1 | grep -q "codex-signing"; then
    # best-effort add to list
    security list-keychains -d user -s "$kc" $(security list-keychains -d user 2>&1 | tr -d '"' | xargs) >>"$LOG" 2>&1 || true
  fi
  if [[ -f "$crt" ]]; then
    if sudo -n true 2>/dev/null; then
      sudo security add-trusted-cert -d -r trustRoot -p codeSign -k "/Library/Keychains/System.keychain" "$crt" >>"$LOG" 2>&1 || log "提示：证书已生成但加入系统信任失败，不影响使用"
    else
      log "证书已生成（未自动加入系统信任，属正常，需 sudo 时可手动执行 security add-trusted-cert）"
    fi
  fi
  log "自签证书已就绪：$crt"
}

# ---------------------------------------------------------------------------
# 3. 依赖检查
# ---------------------------------------------------------------------------
for tool in python3 openssl clang security codesign; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    die "缺少依赖：$tool。请先运行 xcode-select --install 安装命令行工具后重试。"
  fi
done
if [[ "$SKIP_PATCH" -eq 0 && ! -d "/Applications/ChatGPT.app" && ! -d "$HOME/Applications/ChatGPT.app" ]]; then
  die "没有找到 /Applications/ChatGPT.app 或 ~/Applications/ChatGPT.app。请先安装原版 Codex / ChatGPT 桌面版再运行。"
fi

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

# ---------------------------------------------------------------------------
# 5. 生成 models.json（按 key 过滤 + 重排 priority）
# ---------------------------------------------------------------------------
MODEL_TMPL="$SCRIPT_DIR/resources/templates/models.json"
MODELS_OUT="$CODEX_HOME/models.json"
if [[ "$MODE" == "update" && -f "$MODELS_OUT" ]]; then
  log "更新模式：保留现有 models.json（自动更新），跳过模板"
  MODEL_COUNT="$(python3 -c 'import json;print(len(json.load(open("'"$MODELS_OUT"'"))["models"]))' 2>/dev/null || echo 0)"
  AVAIL_SLUGS="$(python3 -c 'import json;print(" ".join(m["slug"] for m in json.load(open("'"$MODELS_OUT"'"))["models"]))' 2>/dev/null || true)"
else
  python3 - "$MODEL_TMPL" "$MODELS_OUT" "$HAS_GO" "$HAS_DS" <<'PY'
import json, sys
src, dst, has_go, has_ds = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1"
data = json.load(open(src))
models = []
for m in data["models"]:
    is_go = m["slug"].endswith("-go") or m["slug"].endswith("-zen")
    if is_go and not has_go:
        continue
    if not is_go and not has_ds:
        continue
    models.append(m)
for i, m in enumerate(models, 1):
    m["priority"] = i
json.dump({"models": models}, open(dst, "w"), ensure_ascii=False, indent=2)
print(len(models))
PY
fi
MODEL_COUNT="$(python3 -c 'import json;print(len(json.load(open("'"$MODELS_OUT"'"))["models"]))' 2>/dev/null || echo 0)"
AVAIL_SLUGS="$(python3 -c 'import json;print(" ".join(m["slug"] for m in json.load(open("'"$MODELS_OUT"'"))["models"]))' 2>/dev/null || true)"
log "models.json 已生成：$MODEL_COUNT 个模型"

# ---------------------------------------------------------------------------
# 6. 选择默认模型 / 记忆模型 / base_url / bearer
# ---------------------------------------------------------------------------
DEFAULT_MODEL=""
if [[ "$HAS_DS" -eq 1 ]]; then
  DEFAULT_MODEL="deepseek-v4-flash-vision-exp"
elif [[ "$AVAIL_SLUGS" == *"mimo-v2.5-go"* ]]; then
  DEFAULT_MODEL="mimo-v2.5-go"
elif [[ "$AVAIL_SLUGS" == *"deepseek-v4-flash-go"* ]]; then
  DEFAULT_MODEL="deepseek-v4-flash-go"
else
  DEFAULT_MODEL="${AVAIL_SLUGS%% *}"
fi

EXTRACT_MODEL=""
if [[ "$AVAIL_SLUGS" == *"mimo-v2.5-free-zen"* ]]; then
  EXTRACT_MODEL="mimo-v2.5-free-zen"
elif [[ "$AVAIL_SLUGS" == *"mimo-v2.5-free"* ]]; then
  EXTRACT_MODEL="mimo-v2.5-free"
elif [[ "$AVAIL_SLUGS" == *"mimo-v2.5-go"* ]]; then
  EXTRACT_MODEL="mimo-v2.5-go"
elif [[ "$AVAIL_SLUGS" == *"deepseek-v4-flash-vision-exp-go"* ]]; then
  EXTRACT_MODEL="deepseek-v4-flash-vision-exp-go"
elif [[ "$AVAIL_SLUGS" == *"deepseek-v4-flash-vision-exp"* ]]; then
  EXTRACT_MODEL="deepseek-v4-flash-vision-exp"
else
  EXTRACT_MODEL="${AVAIL_SLUGS%% *}"
fi

if [[ -z "$DEFAULT_MODEL" || -z "$EXTRACT_MODEL" ]]; then
  die "models.json 生成为空，请检查 key 是否有效。"
fi

USE_PROXY=0
if [[ "$HAS_GO" -eq 1 || "$HAS_GLM" -eq 1 ]]; then
  USE_PROXY=1
fi
if [[ "$USE_PROXY" -eq 1 ]]; then
  BASE_URL="http://127.0.0.1:19100"
else
  BASE_URL="https://api.deepseek.com/"
fi
if [[ "$HAS_DS" -eq 1 ]]; then
  BEARER="$DS_KEY"
else
  BEARER="$GO_KEY"
fi

python3 - "$SCRIPT_DIR/resources/templates/config.toml" "$CODEX_HOME/config.toml" \
  "$DEFAULT_MODEL" "$EXTRACT_MODEL" "$BASE_URL" "$BEARER" <<'PY'
import os, re, sys
src, dst, default_model, extract_model, base_url, bearer = sys.argv[1:7]
if os.path.exists(dst) and open(dst).read().strip():
    out = open(dst).read()
    out = re.sub(r"^model\s*=.*", f'model = "{default_model}"', out, flags=re.MULTILINE)
    out = re.sub(r"^model_reasoning_effort\s*=.*", 'model_reasoning_effort = "low"', out, flags=re.MULTILINE)
    out = re.sub(r"base_url\s*=.*", f'base_url = "{base_url}"', out)
    out = re.sub(r"experimental_bearer_token\s*=.*", f'experimental_bearer_token = "{bearer}"', out)
    out = re.sub(r"extract_model\s*=.*", f'extract_model = "{extract_model}"', out)
    out = re.sub(r"consolidation_model\s*=.*", f'consolidation_model = "{extract_model}"', out)
    # 默认关闭记忆以省 token，用户可在 config.toml 手动改回 true
    out = re.sub(r"^generate_memories\s*=.*", 'generate_memories = false', out, flags=re.MULTILINE)
    out = re.sub(r"^use_memories\s*=.*", 'use_memories = false', out, flags=re.MULTILINE)
    out = re.sub(r"^disable_on_external_context\s*=.*", 'disable_on_external_context = true', out, flags=re.MULTILINE)
    out = re.sub(r"^\[features\]\s*\nmemories\s*=.*", '[features]\nmemories = false', out, flags=re.MULTILINE)
    if 'max_rollouts_per_startup' not in out:
        out = re.sub(r"^(disable_on_external_context\s*=.*)", r"\1\nmax_rollouts_per_startup = 2", out, flags=re.MULTILINE)
    open(dst, "w").write(out)
else:
    text = open(src).read()
    text = text.replace("__DEFAULT_MODEL__", default_model)
    text = text.replace("__REASONING_EFFORT__", "low")
    text = text.replace("__BASE_URL__", base_url)
    text = text.replace("__BEARER__", bearer)
    text = text.replace("__EXTRACT_MODEL__", extract_model)
    text = text.replace("__CONSOLIDATION_MODEL__", extract_model)
    open(dst, "w").write(text)
PY
chmod 600 "$CODEX_HOME/config.toml"
log "config.toml 已生成（默认模型 $DEFAULT_MODEL，记忆模型 $EXTRACT_MODEL，base_url $BASE_URL，记忆默认关闭）"

# ---------------------------------------------------------------------------
# 7. AGENTS.md 全局规则 + MCP 搜索（opencode hosted, 仅 27 个无搜模型用）
# ---------------------------------------------------------------------------
cp -p "$SCRIPT_DIR/resources/templates/AGENTS.md" "$CODEX_HOME/AGENTS.md"
cp -p "$SCRIPT_DIR/resources/templates/AGENTS.md" "$HOME/.codex/AGENTS.md"
log "AGENTS.md 已安装"
# websearch MCP (Exa/Parallel hosted, no API key, 25s)
MCP_DIR="$HOME/.config/opencode/mcp"
MCP_SRC="$SCRIPT_DIR/resources/mcp/websearch-server.py"
MCP_DST="$MCP_DIR/websearch-server.py"
if [[ -f "$MCP_SRC" ]]; then
  mkdir -p "$MCP_DIR"
  cp -p "$MCP_SRC" "$MCP_DST"
  chmod +x "$MCP_DST"
  python3 -m py_compile "$MCP_DST" 2>/dev/null || true
  # 注入到副本 config.toml (mcp_servers.websearch)
  if ! grep -q "mcp_servers.websearch" "$CODEX_HOME/config.toml" 2>/dev/null; then
    cat >> "$CODEX_HOME/config.toml" <<MCP_EOF

[mcp_servers.websearch]
command = "python3"
args = ["-u", "$MCP_DST"]
MCP_EOF
    log "MCP 搜索已注入 (websearch → $MCP_DST, 27 个无搜模型用)"
  else
    log "MCP 搜索已存在，跳过注入"
  fi
fi

# ---------------------------------------------------------------------------
# 8. 视觉代理（有 Go 或 GLM 时安装）
# ---------------------------------------------------------------------------
PROXY_OK=0
if [[ "$USE_PROXY" -eq 1 ]]; then
  VISION_DIR="$HOME/.local/share/agent-vision-toolkit"
  mkdir -p "$VISION_DIR" "$HOME/.config/agent-vision-toolkit"
  cp -R "$SCRIPT_DIR/resources/vision/." "$VISION_DIR/" 2>/dev/null || true
  chmod +x "$VISION_DIR"/bin/* 2>/dev/null || true
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  tmp_env_x="$(mktemp)"
  grep -vE '^(VISION_API_KEY|VISION_BASE_URL|VISION_MODEL|ZEN_API_KEY)=' "$ENV_FILE" 2>/dev/null > "$tmp_env_x" || true
  {
    cat "$tmp_env_x"
    if [[ "$HAS_GLM" -eq 1 ]]; then
      printf 'VISION_API_KEY=%s\n' "$GLM_KEY"
      printf 'VISION_BASE_URL=https://open.bigmodel.cn/api/paas/v4\n'
      printf 'VISION_MODEL=glm-4v-flash\n'
    else
      printf '# VISION_* 未配置：看图功能未启用\n'
    fi
    if ! grep -q '^LANG=' "$tmp_env_x" 2>/dev/null; then printf 'LANG=zh\n'; fi
    if [[ -n "$GO_KEY" ]]; then printf 'ZEN_API_KEY=%s\n' "$GO_KEY"; fi
  } > "$ENV_FILE.new"
  mv "$ENV_FILE.new" "$ENV_FILE"
  rm -f "$tmp_env_x"
  chmod 600 "$ENV_FILE"

  PY_BIN="$(command -v python3)"
  PLIST="$HOME/Library/LaunchAgents/com.agent-vision-toolkit.proxy.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  SKIP_FLAG=""
  if [[ "$HAS_GLM" -eq 0 ]]; then
    SKIP_FLAG="<string>--skip-vision-config-check</string>"
  fi
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.agent-vision-toolkit.proxy</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY_BIN</string>
    <string>$VISION_DIR/vision_proxy.py</string>
    <string>--port</string><string>19100</string>
    <string>--upstream</string><string>https://api.deepseek.com/</string>
    <string>--env-file</string><string>$ENV_FILE</string>
    $SKIP_FLAG
  </array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$VISION_DIR/proxy.log</string>
  <key>StandardErrorPath</key><string>$VISION_DIR/proxy.err.log</string>
</dict>
</plist>
EOF

  if [[ "$SKIP_PROXY_START" -eq 0 ]]; then
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
    for _ in {1..30}; do
      if lsof -nP -iTCP:19100 -sTCP:LISTEN >/dev/null 2>&1; then
        PROXY_OK=1
        break
      fi
      sleep 1
    done
    if [[ "$PROXY_OK" -eq 1 ]]; then
      log "视觉代理已启动（127.0.0.1:19100）"
    else
      log "WARN: 视觉代理未在 30 秒内监听，请查看 $VISION_DIR/proxy.err.log"
    fi
  else
    PROXY_OK=1
    log "代理文件已生成（--skip-proxy-start，未启动服务）"
  fi

  # Go 模型自动发现（quota 表 6h + 启动，跟表自动同步，限免自动识别）
  if [[ "$HAS_GLM" -eq 1 || "$HAS_GO" -eq 1 ]]; then
    DISCOVERY_PLIST="$HOME/Library/LaunchAgents/com.steve233.go-model-discovery.plist"
    cat > "$DISCOVERY_PLIST" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.steve233.go-model-discovery</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY_BIN</string>
    <string>$VISION_DIR/model_discovery.py</string>
    <string>--sync</string>
  </array>
  <key>StartInterval</key><integer>21600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$VISION_DIR/discovery.log</string>
  <key>StandardErrorPath</key><string>$VISION_DIR/discovery.err.log</string>
</dict>
</plist>
EOF2
    launchctl bootout "gui/$(id -u)" "$DISCOVERY_PLIST" 2>/dev/null || launchctl unload "$DISCOVERY_PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$DISCOVERY_PLIST" 2>/dev/null || launchctl load "$DISCOVERY_PLIST" 2>/dev/null || true
    log "Go 模型自动发现已安装（6h + 启动，跟配额表自动同步）"
    # 立即同步一次（quota表 -> models.json）
    "$PY_BIN" "$VISION_DIR/model_discovery.py" --sync --force >>"$LOG" 2>&1 || log "WARN: 首次 Go 模型同步失败，详见 $VISION_DIR/discovery.err.log"
  fi
else
  log "无需视觉代理（纯官方 DeepSeek 直连）"
fi

# ---------------------------------------------------------------------------
# 9. ChatGPT-Patched.app 副本（patch）
# ---------------------------------------------------------------------------
# 确保证书存在（新机）
if [[ "$SKIP_PATCH" -eq 0 ]]; then
  ensure_codex_signing_cert || log "WARN: 证书生成失败，仍将尝试 patch（可能回退 ad-hoc）"
fi

# 安装 codex-picker-patch 1h 常驻（skill §架构）
install_picker_patch_agent() {
  local plist="$HOME/Library/LaunchAgents/com.steve233.codex-picker-patch.plist"
  local cmd
  cmd="$(command -v bash || echo /bin/bash)"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$plist" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.steve233.codex-picker-patch</string>
  <key>ProgramArguments</key>
  <array>
    <string>$cmd</string>
    <string>$PATCH_BASE/patch.sh</string>
    <string>--auto-update</string>
  </array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$PATCH_BASE/patch.log</string>
  <key>StandardErrorPath</key><string>$PATCH_BASE/patch.log</string>
</dict>
</plist>
PLISTEOF
  launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || launchctl unload "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || launchctl load "$plist" 2>/dev/null || true
  log "codex-picker-patch 自动更新已安装（1h）"
}

PATCH_OK=0
PATCH_VER_MSG=""
if [[ "$SKIP_PATCH" -eq 0 ]]; then
  mkdir -p "$PATCH_BASE/certs" "$PATCH_BASE/scripts"
  cp -p "$SCRIPT_DIR/resources/patch/patch.sh" "$PATCH_BASE/patch.sh"
  cp -p "$SCRIPT_DIR/resources/patch/ent2.plist" "$PATCH_BASE/certs/ent2.plist"
  chmod 755 "$PATCH_BASE/patch.sh"
  if [[ -n "$PASS" ]]; then
    printf '%s' "$PASS" > "$PASS_FILE"
    chmod 600 "$PASS_FILE"
  fi
  install_picker_patch_agent
  # 版本感知重建：避免 --install 的 is_patched 短路
  SRC_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/ChatGPT.app/Contents/Info.plist 2>/dev/null | grep -v "Will Create" || true)"; if [[ -z "$SRC_VER" || "$SRC_VER" == "unknown" ]]; then SRC_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HOME/Applications/ChatGPT.app/Contents/Info.plist" 2>/dev/null | grep -v "Will Create" || true)"; fi; [[ -z "$SRC_VER" ]] && SRC_VER="unknown"
  MARKER_VER="$(sed -nE 's/.*"sourceVersion": *"([^"]*)".*/\1/p' "$PATCH_BASE/patch-state.json" 2>/dev/null | head -1)"
  NEED_REBUILD=0
  if [[ -z "$MARKER_VER" || "$SRC_VER" != "$MARKER_VER" ]]; then
    NEED_REBUILD=1
  fi
  if ! bash "$PATCH_BASE/patch.sh" --status 2>&1 | grep -q "patched"; then
    NEED_REBUILD=1
  fi
  if [[ "$NEED_REBUILD" -eq 1 ]]; then
    # 官方已升级时副本常驻会阻止重建，更新模式下自动退出
    if pgrep -f "ChatGPT-Patched" >/dev/null 2>&1; then
      if [[ "$MODE" == "update" ]]; then
        log "检测到官方已升级（$MARKER_VER -> $SRC_VER），副本仍在运行，尝试自动退出重建..."
        pkill -f "ChatGPT-Patched" 2>/dev/null || true
        for _ in {1..10}; do pgrep -f "ChatGPT-Patched" >/dev/null 2>&1 || break; sleep 0.5; done
      else
        log "WARN: 副本正在运行，重建将延后；请退出副本后重试 patch.sh --auto-update"
      fi
    fi
    if bash "$PATCH_BASE/patch.sh" --auto-update; then
      # --auto-update 在已是最新时无输出，仍视为成功
      PATCH_OK=1
      PATCH_VER_MSG="（$SRC_VER）"
      log "ChatGPT-Patched.app 已同步至 $SRC_VER"
    else
      # 回退：auto-update 可能因运行中 defer，尝试 --install
      if bash "$PATCH_BASE/patch.sh" --install; then
        PATCH_OK=1
        PATCH_VER_MSG="（$SRC_VER）"
        log "ChatGPT-Patched.app 已生成（fallback --install）"
      else
        log "WARN: patch.sh 执行失败，详见 $PATCH_BASE/patch.log"
      fi
    fi
  else
    log "副本已是最新（$SRC_VER），跳过重建"
    PATCH_OK=1
    PATCH_VER_MSG="（$SRC_VER 已是最新）"
  fi
else
  log "跳过副本 patch（--skip-patch）"
fi

# ---------------------------------------------------------------------------
# 9b. 超大对话自动归档（>8MB 防重试，skill §25）
# ---------------------------------------------------------------------------
ARCHIVE_SCRIPT="$CODEX_HOME/scripts/archive-large-rollouts.sh"
mkdir -p "$CODEX_HOME/scripts" "$CODEX_HOME/failed_rollouts"
if [ -f "$SCRIPT_DIR/resources/scripts/archive-large-rollouts.sh" ]; then
  cp -p "$SCRIPT_DIR/resources/scripts/archive-large-rollouts.sh" "$ARCHIVE_SCRIPT"
  chmod +x "$ARCHIVE_SCRIPT"
  # 立即归档一次历史超大文件
  bash "$ARCHIVE_SCRIPT" 2>/dev/null || true
fi
ARCHIVE_PLIST="$HOME/Library/LaunchAgents/com.steve233.codex-archive-rollouts.plist"
cat > "$ARCHIVE_PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.steve233.codex-archive-rollouts</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$ARCHIVE_SCRIPT</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$CODEX_HOME/failed_rollouts/archive.log</string>
  <key>StandardErrorPath</key><string>$CODEX_HOME/failed_rollouts/archive.log</string>
</dict>
</plist>
PLISTEOF
launchctl bootout "gui/$(id -u)" "$ARCHIVE_PLIST" 2>/dev/null || launchctl unload "$ARCHIVE_PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$ARCHIVE_PLIST" 2>/dev/null || launchctl load "$ARCHIVE_PLIST" 2>/dev/null || true
log "超大对话自动归档已安装（>8MB → failed_rollouts/，1h/次）"

# ---------------------------------------------------------------------------
# 10. 汇总
# ---------------------------------------------------------------------------
if [[ "$HAS_GLM" -eq 1 ]]; then
  VISION_TEXT="已启用（智谱 GLM）"
else
  VISION_TEXT="未启用：缺少 GLM key，发图片会失败；可稍后补填 $ENV_FILE 后执行 launchctl kickstart -k gui/$(id -u)/com.agent-vision-toolkit.proxy"
fi
if [[ "$SKIP_PATCH" -eq 1 ]]; then
  PATCH_TEXT="已跳过"
elif [[ "$PATCH_OK" -eq 1 ]]; then
  PATCH_TEXT="已完成（~/Applications/ChatGPT-Patched.app）"
else
  PATCH_TEXT="失败，请查看 ~/.codex/picker-patch/patch.log"
fi

if [[ "$MODE" == "update" ]]; then
  SUMMARY=$'更新完成 ✅\n\n可用模型：'"$MODEL_COUNT"$' 个\n默认模型：'"$DEFAULT_MODEL"$'\n看图：'"$VISION_TEXT"$'\n双开副本：'"$PATCH_TEXT"$'\n\n说明：已用现有 Key 复用更新配置/模板/视觉代理/补丁脚本，无需重填 Key。\n下一步：如副本在运行请重启生效；日志：'"$LOG"
else
  SUMMARY=$'安装完成 ✅\n\n可用模型：'"$MODEL_COUNT"$' 个\n默认模型：'"$DEFAULT_MODEL"$'\n看图：'"$VISION_TEXT"$'\n双开副本：'"$PATCH_TEXT"$'\n\n下一步：\n1. 如果副本已启动，先完全退出再重新打开 Codex（生效）。\n2. 可选：gh auth login -h github.com 登录 GitHub；git config --global user.name/email 设置身份。\n3. 日志：'"$LOG"
fi

log "$SUMMARY"
if [[ "$NONINTERACTIVE" -eq 0 ]]; then
  show_info "$SUMMARY"
fi

echo
echo "$SUMMARY"
echo
