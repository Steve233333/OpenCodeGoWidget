#!/bin/zsh
# 步骤：6. 选择默认模型 / 记忆模型 / base_url / bearer
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径：zsh 默认会把被 source 文件的 $0 换掉，
#    路径推导统一放在主脚本（SCRIPT_DIR 已算好，直接用）。

# ---------------------------------------------------------------------------
# 6. 选择默认模型 / 记忆模型 / base_url / bearer
# ---------------------------------------------------------------------------
DEFAULT_MODEL=""
DEFAULT_REASONING_EFFORT="max"
# 2026-10-24：用户指定所有新配置默认使用 DeepSeek V4.1 Flash 的最高推理档。
# 仍然先看真正可用列表，避免“只有 DeepSeek 直连 Key”的机器生成不存在的 Go 模型。
pick_available_model() {
  local slug
  for slug in "$@"; do
    case " $AVAIL_SLUGS " in
      *" $slug "*) printf '%s' "$slug"; return 0 ;;
    esac
  done
  return 1
}

if DEFAULT_MODEL="$(pick_available_model \
  deepseek-v4.1-flash-go \
  deepseek-v4-flash-go \
  deepseek-v4-flash-vision-exp-go \
  deepseek-v4-flash-vision-exp \
  deepseek-v4-pro-go \
  deepseek-v4-pro)"; then
  :
else
  DEFAULT_MODEL="${AVAIL_SLUGS%% *}"
fi

# 记忆提取/合并也跟随同一个默认模型，避免新会话与后台记忆任务使用不同模型。
EXTRACT_MODEL="$DEFAULT_MODEL"

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

# 空列表不应该继续往下写一个空 config；给出明确病因并让安装器失败。
if [[ -z "${AVAIL_SLUGS:-}" ]]; then
  die "可用模型列表为空：模板/当前 Key 过滤后没有任何模型，配置文件未覆盖。"
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
  # 2026-10-14：以前这里拿 Go Key 顶替 → 写进 experimental_bearer_token 后
  # ① 配置页把它当成"用户的 DeepSeek Key"显示出来（用户看到"莫名其妙多了个 key"）；
  # ② HAS_DS 被误判为真 → 官方直连模型不会被剔除，清掉 key 后下拉框里还在。
  # 现在写一个**可识别的占位**：中继会把 Authorization 换成真实 key，Codex 只要有个凭据就够；
  # 配置页 / 自检见到这个占位一律当"未设置"。
  BEARER="sk-relay-placeholder"
fi

_config_out="$(python3 - "$RES_DIR/templates/config.toml" "$CODEX_HOME/config.toml" \
  "$DEFAULT_MODEL" "$DEFAULT_REASONING_EFFORT" "$EXTRACT_MODEL" "$BASE_URL" "$BEARER" 2>&1 <<'PY'
import os, re, sys, tempfile
src, dst, default_model, default_effort, extract_model, base_url, bearer = sys.argv[1:8]

try:
    existing = ""
    if os.path.exists(dst):
        with open(dst, encoding="utf-8") as handle:
            existing = handle.read()
    if existing.strip():
        out = existing
    else:
        with open(src, encoding="utf-8") as handle:
            text = handle.read()
        text = text.replace("__DEFAULT_MODEL__", default_model)
        text = text.replace("__REASONING_EFFORT__", default_effort)
        text = text.replace("__BASE_URL__", base_url)
        text = text.replace("__BEARER__", bearer)
        text = text.replace("__EXTRACT_MODEL__", extract_model)
        text = text.replace("__CONSOLIDATION_MODEL__", extract_model)
        out = text

    if existing.strip():
        out = re.sub(r"^model\s*=.*", f'model = "{default_model}"', out, flags=re.MULTILINE)
        effort_line = f'model_reasoning_effort = "{default_effort}"'
        if re.search(r"(?m)^model_reasoning_effort\s*=", out):
            out = re.sub(r"^model_reasoning_effort\s*=.*", effort_line, out, flags=re.MULTILINE)
        else:
            out = re.sub(r"(?m)^(model\s*=.*)$", rf"\1\n{effort_line}", out, count=1)
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
        memory_lines = {
            "extract_model": f'extract_model = "{extract_model}"',
            "consolidation_model": f'consolidation_model = "{extract_model}"',
            "generate_memories": "generate_memories = false",
            "use_memories": "use_memories = false",
            "disable_on_external_context": "disable_on_external_context = true",
            "max_rollouts_per_startup": "max_rollouts_per_startup = 2",
        }
        memory_header = re.search(r"(?m)^\[memories\]\s*$", out)
        if memory_header:
            next_header = re.search(r"(?m)^\[[^\]]+\]\s*$", out[memory_header.end():])
            section_end = memory_header.end() + (next_header.start() if next_header else len(out) - memory_header.end())
            block = out[memory_header.start():section_end]
            for key, line in memory_lines.items():
                if re.search(rf"(?m)^[ \t]*{re.escape(key)}[ \t]*=", block):
                    block = re.sub(rf"(?m)^[ \t]*{re.escape(key)}[ \t]*=.*$", line, block)
                else:
                    block = re.sub(r"(?m)^(\[memories\]\s*)$", rf"\1\n{line}", block, count=1)
            out = out[:memory_header.start()] + block + out[section_end:]
        else:
            out = out.rstrip("\n") + (
                "\n\n[memories]\n"
                f'extract_model = "{extract_model}"\n'
                f'consolidation_model = "{extract_model}"\n'
                "generate_memories = false\n"
                "use_memories = false\n"
                "disable_on_external_context = true\n"
                "max_rollouts_per_startup = 2\n"
            )
        # 默认关闭记忆以省 token，用户可在 config.toml 手动改回 true
        out = re.sub(r"^generate_memories\s*=.*", 'generate_memories = false', out, flags=re.MULTILINE)
        out = re.sub(r"^use_memories\s*=.*", 'use_memories = false', out, flags=re.MULTILINE)
        out = re.sub(r"^disable_on_external_context\s*=.*", 'disable_on_external_context = true', out, flags=re.MULTILINE)
        out = re.sub(r"^\[features\]\s*\nmemories\s*=.*", '[features]\nmemories = false', out, flags=re.MULTILINE)
        if 'max_rollouts_per_startup' not in out:
            out = re.sub(r"^(disable_on_external_context\s*=.*)", r"\1\nmax_rollouts_per_startup = 2", out, flags=re.MULTILINE)

    if not out.strip():
        raise ValueError("生成的 config.toml 为空")

    parent = os.path.dirname(dst) or "."
    os.makedirs(parent, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".config.toml.", suffix=".tmp", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(out)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, dst)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
except Exception as exc:
    print(f"CONFIG_WRITE_FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
    raise
PY
)"
_config_rc=$?
if [[ "$_config_rc" -ne 0 || ! -s "$CODEX_HOME/config.toml" ]]; then
  die "config.toml 写入失败：${_config_out:-未知错误}（目标：${CODEX_HOME}/config.toml）"
fi
chmod 600 "$CODEX_HOME/config.toml" 2>/dev/null || die "config.toml 已写入，但无法设置 600 权限：${CODEX_HOME}/config.toml"
log "config.toml 已生成（默认模型 ${DEFAULT_MODEL} / ${DEFAULT_REASONING_EFFORT}，记忆模型 ${EXTRACT_MODEL}，base_url ${BASE_URL}，记忆默认关闭）"
