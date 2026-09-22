#!/bin/zsh
# =============================================================================
# Codex 一键配置安装器（macOS）
# 双击本文件即可；也可在终端手动运行：
#   ./codex-oneclick-setup.command
# 交互：双击后会先让你选“安装 / 更新”；更新模式无需重填 Key
# 高级参数（测试/无人值守）：
#   --noninteractive     使用 ONECLICK_GO_KEY / ONECLICK_DS_KEY /
#                        ONECLICK_PASS 环境变量，不弹窗
#   --skip-patch         不重建 ChatGPT-Patched.app（只生成配置）
#   --skip-proxy-start   生成代理文件但不启动 launchd 服务
#   --update               直接进入更新模式（不弹窗，复用旧 Key）
#   --install              直接进入安装模式（弹窗填 Key）
# =============================================================================
set -uo pipefail
# 2026-09-20：zsh 默认 nomatch —— 任何**不匹配的 glob** 会让整个脚本静默退出（status 1），
# 日志里连一句错误都没有，用户只看到"上次配置失败"。实测那台机器没有 python.org 的
# /Applications/Python 3.x/，就死在下面第 ~694 行的证书循环上（正好停在 vision 同步之后、
# "阶段：重启本地代理"之前 —— 和用户截图完全对上）。显式允许空匹配。
setopt null_glob 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 资源目录（2026-09-23 Phase 4）：安装器在 App 包里位于 Contents/Resources/codex/，
# 那一层 build.sh 会建一个 `resources -> .` 软链，所以读写 `resources/templates/...` 都能命中。
# 直接从**仓库**跑时没有这个软链（资源就在同级的 templates/、vision/ 下），这里兜一下 ——
# 否则从仓库跑会在"生成 models.json"那步报"模板文件缺失"。
if [[ -d "$SCRIPT_DIR/resources" ]]; then
  RES_DIR="$SCRIPT_DIR/resources"
else
  RES_DIR="$SCRIPT_DIR"
fi
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

# ---------------------------------------------------------------------------
# I1. 互斥锁：禁止两个配置任务并发重建同一个副本（2026-09-04）。
# 背景：重建耗时约 1~2 分钟且中途日志很少，用户容易连点“配置”；
# 两个实例同时 rm -rf/cp -R 同一个 bundle 必互相破坏。mkdir 原子性保证
# 只有一个能拿到锁；stale 锁（持有进程已死，如被 kill -9）自动清理。
# ---------------------------------------------------------------------------
ONECLICK_LOCK_DIR="$HOME/.codex/picker-patch/.oneclick.lock.d"
mkdir -p "$HOME/.codex/picker-patch" 2>/dev/null || true
if ! mkdir "$ONECLICK_LOCK_DIR" 2>/dev/null; then
  _holder_pid="$(sed -nE 's/^PID=([0-9]+).*/\1/p' "$ONECLICK_LOCK_DIR/info" 2>/dev/null | head -1 || true)"
  if [[ -n "${_holder_pid:-}" ]] && kill -0 "$_holder_pid" 2>/dev/null; then
    _holder_info="$(cat "$ONECLICK_LOCK_DIR/info" 2>/dev/null || echo '?')"
    die "已有配置任务在运行中（${_holder_info}），请等待它完成或取消后再试。本次未做任何更改。"
  fi
  log "WARN: 发现残留锁（持有进程已退出），清理后继续"
  rm -rf "$ONECLICK_LOCK_DIR"
  mkdir "$ONECLICK_LOCK_DIR" 2>/dev/null || die "无法创建锁目录 $ONECLICK_LOCK_DIR"
fi
printf 'PID=%s START=%s\n' "$$" "$(date '+%Y-%m-%d %H:%M:%S')" > "$ONECLICK_LOCK_DIR/info" 2>/dev/null || true
_cleanup_oneclick_lock() {
  local _oc_status=$?
  rm -rf "$ONECLICK_LOCK_DIR"
  # 2026-09-20：异常中断也要留痕（以前 zsh 的 glob 报错会让脚本无声退出，
  # 日志最后一行停在半路，完全查不出原因）
  if [[ "$_oc_status" -ne 0 ]]; then
    log "ERROR: 配置脚本异常中断（退出码 $_oc_status）。请把这一行以上 30 行日志发给开发者。"
  fi
}
trap _cleanup_oneclick_lock EXIT INT TERM

# ---------------------------------------------------------------------------
# 2026-09-05: 只同步"包里更新"的文件（mtime 比较），禁止旧包降级本机。
# 背景：本机是老大——手动改完还没重打包前点"配置"，旧逻辑会拿包里旧文件覆盖本机新修复。
# cp -p 全程保留 mtime，比较才有意义；缺失文件照常安装。
# ---------------------------------------------------------------------------
sync_newer_file() {
  local src="$1" dst="$2"
  local base
  base="$(basename "$dst")"
  if [[ ! -e "$dst" ]]; then
    mkdir -p "$(dirname "$dst")"
    if cp -p "$src" "$dst" 2>/dev/null; then log "同步新增：${base}"; else log "WARN: 拷贝失败 $src"; fi
    return 0
  fi
  # 2026-09-19：原来只比 mtime（src -nt dst），本机那份只要 mtime 更新就永远跳过覆盖
  # （日志写"本机更新，无需降级"），结果新包装的 vision_proxy.py 永远落不到那台机器上 ——
  # 用户更新了 App、点了配置，跑的却还是旧代理。改成比内容：内容不同就备份旧文件再覆盖。
  if cmp -s "$src" "$dst"; then
    log "无需同步：${base}（内容一致）"
    return 0
  fi
  local backup="${dst}.bak.$(date +%Y%m%d%H%M%S)"
  if cp -p "$dst" "$backup" 2>/dev/null; then
    log "备份旧文件：${base} → $(basename "$backup")"
  fi
  if cp -p "$src" "$dst" 2>/dev/null; then
    log "同步更新：${base}（内容有变）"
  else
    log "WARN: 拷贝失败 $src"
  fi
  return 0
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
# 2026-09-23（Phase 4）：脚本按步骤拆到 setup/steps/*.sh，这里按顺序 source。
# 说明：source 在同一个 shell 里执行，变量/函数与内联代码完全等价；
# SCRIPT_DIR 只在本文件算一次（被 source 的文件里 $0 会变，绝不能在那儿推路径）。
# 某一步失败只记日志不中止 —— 与拆分前的行为一致（原来也是继续往下走）。
# 最后一步「配置后自检」是必跑项：环境 + 三个关键服务的状态都会写进日志。
source "$SCRIPT_DIR/setup/steps/10-mode.sh"   # 0. 模式选择（安装 / 更新）
source "$SCRIPT_DIR/setup/steps/20-keys.sh"   # 1. 读取/收集 Key（Go 与 DeepSeek 至少一个）
source "$SCRIPT_DIR/setup/steps/30-signing.sh"   # 2. 签名密码（强制自定义）
source "$SCRIPT_DIR/setup/steps/40-deps.sh"   # 3. 依赖检查
source "$SCRIPT_DIR/setup/steps/50-backup.sh"   # 4. 备份旧配置
source "$SCRIPT_DIR/setup/steps/60-models.sh"   # 5. 生成 models.json
source "$SCRIPT_DIR/setup/steps/70-defaults.sh"   # 6. 选择默认模型 / 记忆模型 / base_url / bearer
source "$SCRIPT_DIR/setup/steps/80-agents-mcp.sh"   # 7. AGENTS.md 全局规则 + MCP 搜索
source "$SCRIPT_DIR/setup/steps/90-proxy.sh"   # 8. 本地代理（Go/Zen 路由 + 协议桥接）
source "$SCRIPT_DIR/setup/steps/100-patched-app.sh"   # 9. ChatGPT-Patched.app 副本（patch）
source "$SCRIPT_DIR/setup/steps/110-archive-off.sh"   # 9b. 已停用：超大对话自动归档
source "$SCRIPT_DIR/setup/steps/120-summary.sh"   # 10. 汇总
source "$SCRIPT_DIR/setup/steps/130-selfcheck.sh"   # 11. 配置后自检（必跑）
