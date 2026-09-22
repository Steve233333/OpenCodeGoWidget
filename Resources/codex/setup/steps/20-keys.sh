#!/bin/zsh
# 步骤：1. 读取/收集 Key（Go 与 DeepSeek 至少一个）
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径：zsh 默认会把被 source 文件的 $0 换掉，
#    路径推导统一放在主脚本（SCRIPT_DIR 已算好，直接用）。

# ---------------------------------------------------------------------------
# 1. 读取/收集两个 Key（Go 与 DeepSeek 至少一个）
# ---------------------------------------------------------------------------
EXISTING_GO="$(grep '^ZEN_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)"
EXISTING_DS="$(awk -F'"' '/^experimental_bearer_token *=/{print $2}' "$CODEX_HOME/config.toml" 2>/dev/null | head -1 || true)"

GO_KEY=""
DS_KEY=""
PASS=""

if [[ "$MODE" == "update" ]]; then
  # 更新模式：默认沿用现有 Key，不弹窗。
  # 但如果调用方显式传入了非空的新 Key（小组件设置页「替换 Key 后点配置」场景），
  # 新 Key 优先——修复「替换了 Key 却没有生效」：之前这里无条件覆盖成旧 Key，
  # 导致 ONECLICK_GO_KEY / ONECLICK_DS_KEY 输入被静默丢弃。
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    GO_KEY="${ONECLICK_GO_KEY:-}"
    DS_KEY="${ONECLICK_DS_KEY:-}"
  fi
  # 去空格
  GO_KEY="${GO_KEY// /}"
  DS_KEY="${DS_KEY// /}"
  GO_KEY="${GO_KEY:-$EXISTING_GO}"
  DS_KEY="${DS_KEY:-$EXISTING_DS}"
  if [[ -z "$GO_KEY" && -z "$DS_KEY" ]]; then
    die "更新模式下未找到任何 Key（Go 与 DeepSeek 均为空）。请改用“安装”并填写至少一个 Key。"
  fi
  if [[ "$NONINTERACTIVE" -eq 1 && ( -n "${ONECLICK_GO_KEY:-}" || -n "${ONECLICK_DS_KEY:-}" ) ]]; then
    log "更新模式：使用本次传入的新 Key（替换旧值；未传入的 Key 沿用现有）"
  else
    log "更新模式：沿用现有 Go / DeepSeek Key（不重新输入）"
  fi
  # 更新模式下密码仍复用文件里的（改密码需要重建本地签名钥匙串，暂不在更新流程里做）
  if [[ -f "$PASS_FILE" && -z "$PASS" ]]; then
    PASS="$(cat "$PASS_FILE" 2>/dev/null || true)"
  fi
else
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    GO_KEY="${ONECLICK_GO_KEY:-}"
    DS_KEY="${ONECLICK_DS_KEY:-}"
    PASS="${ONECLICK_PASS:-}"
  else
    GO_KEY="$(ask_hidden "OpenCode Go / Zen 订阅 Key（必填其一）\n\n请粘贴你的 sk-... key。\n\n缺这个 key 的后果：所有 *-go 模型（deepseek-go / mimo / glm / luna / muse 等）不会安装，只能使用官方 DeepSeek。" "① OpenCode Go Key" "")"
    [[ "$GO_KEY" == "__CANCEL__" ]] && die "已取消安装"
    DS_KEY="$(ask_hidden "DeepSeek 官方 API Key（可选）\n\n请粘贴 sk-... key。\n\n缺这个 key 的后果：官方 deepseek-v4-flash-vision-exp / deepseek-v4-pro 两个模型不会显示，默认模型会自动改走 Go 模型。" "② DeepSeek Key" "")"
    [[ "$DS_KEY" == "__CANCEL__" ]] && die "已取消安装"
  fi

  # 去空格；留空时回落到现有配置（重复安装/更新 key 场景）
  GO_KEY="${GO_KEY// /}"
  DS_KEY="${DS_KEY// /}"
  GO_KEY="${GO_KEY:-$EXISTING_GO}"
  DS_KEY="${DS_KEY:-$EXISTING_DS}"

  if [[ -z "$GO_KEY" && -z "$DS_KEY" ]]; then
    die "至少需要 OpenCode Go 或 DeepSeek 其中一个 key，请重新运行安装器。"
  fi
fi
for k in "$GO_KEY" "$DS_KEY"; do
  if [[ -n "$k" && "${#k}" -lt 8 ]]; then
    die "检测到疑似无效的 key（长度过短），请检查后重试。"
  fi
done

HAS_GO=0; HAS_DS=0
[[ -n "$GO_KEY" ]] && HAS_GO=1
[[ -n "$DS_KEY" ]] && HAS_DS=1

log "输入校验通过：Go=$HAS_GO DeepSeek=$HAS_DS"
