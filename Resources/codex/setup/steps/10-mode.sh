#!/bin/zsh
# 步骤：0. 模式选择（安装 / 更新）
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径：zsh 默认会把被 source 文件的 $0 换掉，
#    路径推导统一放在主脚本（SCRIPT_DIR 已算好，直接用）。

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
