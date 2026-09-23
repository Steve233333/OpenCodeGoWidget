#!/bin/zsh
# 步骤：6. 选择默认模型 / 记忆模型 / base_url / bearer
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径：zsh 默认会把被 source 文件的 $0 换掉，
#    路径推导统一放在主脚本（SCRIPT_DIR 已算好，直接用）。

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
# 2026-09-22：不再装 Zen 模型（含免费），下面两个 Zen 分支现在正常情况匹配不到，
# 会自动落到 mimo-v2.5-go（Go 模型）—— 记忆管线的模型必须在 models.json 里真实存在。
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
  # 分清真实原因，别再一律甩锅给 Key（2026-09-19：新机没装命令行工具时就是这里报错的）
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'print(1)' >/dev/null 2>&1; then
    die "python3 跑不起来（macOS 没装命令行工具时 /usr/bin/python3 只是占位程序），所以 models.json 根本没生成。
请先运行：xcode-select --install  然后回来重新点「配置」。"
  elif [[ ! -s "$MODEL_TMPL" ]]; then
    die "模板文件缺失或为空：${MODEL_TMPL}（重装「OpenCode 小组件」App 可修复）。"
  else
    die "models.json 生成为空：模板里按当前 Key 过滤后没有可用模型（Go=$HAS_GO DeepSeek=${HAS_DS}）。请检查 Key 是否有效。"
  fi
fi

USE_PROXY=0
if [[ "$HAS_GO" -eq 1 ]]; then
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

python3 - "$RES_DIR/templates/config.toml" "$CODEX_HOME/config.toml" \
  "$DEFAULT_MODEL" "$EXTRACT_MODEL" "$BASE_URL" "$BEARER" <<'PY'
import os, re, sys
src, dst, default_model, extract_model, base_url, bearer = sys.argv[1:7]
if os.path.exists(dst) and open(dst).read().strip():
    out = open(dst).read()
    out = re.sub(r"^model\s*=.*", f'model = "{default_model}"', out, flags=re.MULTILINE)
    out = re.sub(r"^model_reasoning_effort\s*=.*", 'model_reasoning_effort = "low"', out, flags=re.MULTILINE)
    out = re.sub(r"base_url\s*=.*", f'base_url = "{base_url}"', out)
    # 2026-09-19：以前这行只会"替换已存在的行"。被「清除」按钮删过、或老配置里本来就没这行时，
    # 再点多少次「配置」也补不回来 —— Codex 发的请求于是没有 Authorization，
    # 上游回 401 AuthError: Missing API key（带 cf-ray，看着像网络问题，其实是缺凭据）。
    if re.search(r"(?m)^[ \t]*experimental_bearer_token[ \t]*=", out):
        out = re.sub(r"experimental_bearer_token\s*=.*", f'experimental_bearer_token = "{bearer}"', out)
    elif re.search(r"(?m)^wire_api[ \t]*=", out):
        out = re.sub(r"(?m)^(wire_api[ \t]*=.*)$",
                     lambda m: m.group(1) + f'\nexperimental_bearer_token = "{bearer}"', out, count=1)
    elif re.search(r"(?m)^\[model_providers\.", out):
        out = re.sub(r"(?m)^(\[model_providers\.[^\]]+\]\n)",
                     lambda m: m.group(1) + f'experimental_bearer_token = "{bearer}"\n', out, count=1)
    else:
        out = out.rstrip("\n") + f'\nexperimental_bearer_token = "{bearer}"\n'
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
log "config.toml 已生成（默认模型 ${DEFAULT_MODEL}，记忆模型 ${EXTRACT_MODEL}，base_url ${BASE_URL}，记忆默认关闭）"
