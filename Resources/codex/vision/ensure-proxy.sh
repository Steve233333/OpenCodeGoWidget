#!/bin/bash
# 本地代理的生命周期**唯一实现**（2026-09-23）。
#
# 为什么要有它：以前"挑解释器 + 写 launchd plist + 起服务 + 等 30 秒"整套逻辑写在安装器里，
# 而且用 `command -v python3` 挑解释器。App 点「配置」时 PATH 很干净，命中的是 /usr/bin/python3
# （Xcode 自带的 Python 3.9），刚升完 macOS 27 它一时起不来，plist 就这么写死了 ——
# 代理 5 分钟没监听，Codex 侧表现成 "Reconnecting… waiting for network"。
#
# 现在：安装器（配置时）和 App 的看护（启动 / 每 5 分钟 / 唤醒后发现代理死了）都调这一份，
# 规则只有一处：**挑一个真能跑的解释器 → 写/刷新 plist → 起服务 → 探活验证**。
#
# 用法：
#   ensure-proxy.sh [--env-file PATH] [--vision-dir PATH] [--port N]
#                   [--trigger installer|watchdog|manual] [--check-only] [--dry-run] [--quiet]
#                   [--force-restart]
# 退出码：0 = 代理已验证在跑；1 = 这次没能让它跑起来；2 = 参数/环境问题
#
# 测试用的两个口子（正常跑不用管）：
#   ENSURE_PROXY_CANDIDATES=/a/python3:/b/python3   覆盖候选解释器清单
#   PROXY_LABEL / PROXY_PLIST                       覆盖 launchd label 与 plist 路径
set -uo pipefail

VISION_DIR="$HOME/.local/share/agent-vision-toolkit"
ENV_FILE="$HOME/.config/agent-vision-toolkit/env"
PORT=19100
TRIGGER=manual
CHECK_ONLY=0
DRY_RUN=0
FORCE_RESTART=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)   ENV_FILE="$2"; shift 2 ;;
    --vision-dir) VISION_DIR="$2"; shift 2 ;;
    --port)       PORT="$2"; shift 2 ;;
    --trigger)    TRIGGER="$2"; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --force-restart) FORCE_RESTART=1; shift ;;
    --quiet)      QUIET=1; shift ;;
    *) echo "ensure-proxy: 不认识的参数 $1" >&2; exit 2 ;;
  esac
done

LABEL="${PROXY_LABEL:-com.agent-vision-toolkit.proxy}"
PLIST="${PROXY_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
RUNTIME="$VISION_DIR/proxy-runtime"
LOG="$VISION_DIR/ensure-proxy.log"
UID_NUM="$(/usr/bin/id -u)"

say() { [ "$QUIET" = 1 ] || echo "$@"; }
logline() {
  # --dry-run 不落任何文件（连日志也不写），只从 stdout 报它"会做什么"
  if [ "$DRY_RUN" != 1 ]; then
    mkdir -p "$VISION_DIR" 2>/dev/null
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
  fi
  say "$@"
}
state_get() { [ -f "$RUNTIME" ] && sed -n "s/^$1=//p" "$RUNTIME" | head -1; }

# 端口探活：有 HTTP 响应（哪怕是 401）就算活着 —— 我们要的是"代理在监听"
probe() {
  local code
  code="$(/usr/bin/curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models" 2>/dev/null)"
  [ -n "$code" ] && [ "$code" != "000" ]
}

# macOS 没有 timeout 命令，自己看着闹钟杀（/usr/bin/python3 在没装 CLT 时会弹窗卡住）。
# 注意：不要用"另开一个后台子进程 sleep 再杀"的写法 —— 那个 sleep 会活下来占着 stdout，
# 把调用方的管道挂住十几秒（实测）。
run_timed() {
  local t="$1"; shift
  local out="/tmp/.ensure-proxy.$$.out"
  "$@" >"$out" 2>/dev/null &
  local pid=$!
  local i=0 max=$((t * 5))
  while [ "$i" -lt "$max" ] && kill -0 "$pid" 2>/dev/null; do
    /bin/sleep 0.2
    i=$((i + 1))
  done
  local rc=0
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null      # 超时（解释器卡住/弹窗）
    rc=124
  else
    wait "$pid" 2>/dev/null; rc=$?
  fi
  cat "$out" 2>/dev/null
  rm -f "$out"
  return $rc
}

# 真跑一次才算数：能 import ssl/json/asyncio 并报出自己版本的解释器才可用
test_interpreter() {
  local py="$1" out
  [ -x "$py" ] || return 1
  out="$(run_timed 6 "$py" -c 'import ssl,json,asyncio,urllib.request,sys;print(sys.version.split()[0])' 2>/dev/null)"
  [ -n "$out" ] || return 1
  printf '%s' "$out"
  return 0
}

# 候选解释器（固定优先级，不再看 PATH 里第一个）
candidates() {
  local p
  if [ -n "${ENSURE_PROXY_CANDIDATES:-}" ]; then
    # 测试口子：用调用方给的候选清单（冒号分隔）
    local _rest="$ENSURE_PROXY_CANDIDATES"
    while [ -n "$_rest" ]; do
      p="${_rest%%:*}"
      if [ "$p" = "$_rest" ]; then _rest=""; else _rest="${_rest#*:}"; fi
      [ -n "$p" ] && echo "$p"
    done
    return 0
  fi
  # 只认数字版本号的目录：`Versions/Current` 只是软链，写进 plist 会让"到底用哪个版本"变模糊
  for p in $(ls -d /Library/Frameworks/Python.framework/Versions/[0-9]*/bin/python3 2>/dev/null | LC_ALL=C sort -Vr); do
    echo "$p"
  done
  for p in /usr/local/bin/python3 /opt/homebrew/bin/python3; do
    [ -x "$p" ] && echo "$p"
  done
  echo /usr/bin/python3   # 兜底：依赖 Xcode/命令行工具，永远排在最后
}

write_plist() {
  local py="$1"
  mkdir -p "$HOME/Library/LaunchAgents" 2>/dev/null
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$py</string>
    <string>$VISION_DIR/vision_proxy.py</string>
    <string>--port</string><string>$PORT</string>
    <string>--upstream</string><string>https://api.deepseek.com/</string>
    <string>--env-file</string><string>$ENV_FILE</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SSL_CERT_FILE</key><string>/etc/ssl/cert.pem</string>
  </dict>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$VISION_DIR/proxy.log</string>
  <key>StandardErrorPath</key><string>$VISION_DIR/proxy.err.log</string>
</dict>
</plist>
EOF
}

restart_job() {
  /bin/launchctl bootout "gui/$UID_NUM" "$PLIST" >/dev/null 2>&1 \
    || /bin/launchctl unload "$PLIST" >/dev/null 2>&1 || true
  /bin/sleep 1
  /bin/launchctl bootstrap "gui/$UID_NUM" "$PLIST" >/dev/null 2>&1 \
    || /bin/launchctl load -w "$PLIST" >/dev/null 2>&1 || true
}

wait_port() {
  local i=0 n="$1"
  while [ "$i" -lt "$n" ]; do
    probe && return 0
    /bin/sleep 1
    i=$((i + 1))
  done
  return 1
}

# 状态文件：只由本脚本写（App 只读它显示"当前解释器 / 上次自动修复时间"）
write_state() {
  local interp="$1" version="$2" result="$3" detail="$4" repair_at="$5"
  mkdir -p "$VISION_DIR" 2>/dev/null
  {
    printf 'interpreter=%s\n'   "$interp"
    printf 'version=%s\n'       "$version"
    printf 'port=%s\n'          "$PORT"
    printf 'trigger=%s\n'       "$TRIGGER"
    printf 'last_result=%s\n'   "$result"
    printf 'last_detail=%s\n'   "$detail"
    printf 'last_repair_at=%s\n' "$repair_at"
    printf 'verified_at=%s\n'   "$(date '+%Y-%m-%d %H:%M:%S')"
  } > "$RUNTIME"
}

# ---- 参数/环境收尾 ----
if [ "$DRY_RUN" != 1 ]; then
  mkdir -p "$VISION_DIR" "$(dirname "$ENV_FILE")" 2>/dev/null
  if [ ! -f "$ENV_FILE" ]; then
    : > "$ENV_FILE" 2>/dev/null
  fi
  chmod 600 "$ENV_FILE" 2>/dev/null || true
fi

if [ "$CHECK_ONLY" = 1 ]; then
  if probe; then exit 0; else exit 1; fi
fi

PREV_REPAIR="$(state_get last_repair_at)"

# ---- 已经在跑：只更新状态，什么都不动（--force-restart 除外：配置刚同步完新代码，必须换新的）----
if probe && [ "$FORCE_RESTART" != 1 ]; then
  interp="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST" 2>/dev/null || true)"
  ver=""
  [ -n "$interp" ] && ver="$(test_interpreter "$interp" 2>/dev/null)"
  if [ "$DRY_RUN" = 1 ]; then
    say "dry-run：代理已在运行（端口 ${PORT}），解释器：${interp:-未知} ${ver:-}（不写任何文件）"
    exit 0
  fi
  write_state "${interp:-unknown}" "${ver:-?}" ok "已在运行（端口 $PORT 有响应）" "$PREV_REPAIR"
  # 无人值守（看护每 5 分钟一次）不往日志文件里刷"还在跑"的废话 —— 状态文件里的 verified_at
  # 就是新鲜度，日志只留"真出事 / 真修过"；--quiet 时连 stdout 也省掉。
  say "代理已在运行（端口 ${PORT}），解释器：${interp:-未知} ${ver:-}"
  exit 0
fi

# ---- 不在跑（或要求强制重启）：修 ----
if [ "$FORCE_RESTART" = 1 ] && probe; then
  logline "按 --force-restart 重启代理（跑着也要换成刚同步的新代码，trigger=${TRIGGER}）"
else
  logline "代理没在跑（端口 $PORT 无响应）→ 开始修复（trigger=${TRIGGER}）"
fi
SKIP=""
if [ "$(state_get last_result)" = "failed" ]; then
  SKIP="$(state_get interpreter)"
  [ -n "$SKIP" ] && logline "上一轮用 $SKIP 没起来，这一轮跳过它"
fi

CHOSEN=""; CHOSEN_VER=""; LAST_EXIT=""
while IFS= read -r cand; do
  [ -n "$SKIP" ] && [ "$cand" = "$SKIP" ] && continue
  ver="$(test_interpreter "$cand")"
  if [ -z "$ver" ]; then
    logline "解释器不可用（跑不起来或超时），跳过：$cand"
    continue
  fi
  if [ "$cand" = "/usr/bin/python3" ]; then
    logline "只有系统兜底解释器可用：${cand}（Python ${ver}）—— 它依赖 Xcode/命令行工具，建议装 python.org 的 Python"
  fi
  if [ "$DRY_RUN" = 1 ]; then
    logline "dry-run：会选 ${cand}（Python ${ver}），plist 写到 ${PLIST}（不写、不起服务）"
    exit 0
  fi
  logline "用解释器：${cand}（Python ${ver}）"
  write_plist "$cand"
  restart_job
  if wait_port 12; then
    CHOSEN="$cand"; CHOSEN_VER="$ver"
    break
  fi
  LAST_EXIT="$(/bin/launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null | awk '/last exit code/{print $NF}' | head -1)"
  logline "WARN: $cand 起了但 12 秒内端口没响应${LAST_EXIT:+（launchctl 最后退出码 ${LAST_EXIT}）}"
done < <(candidates)

if [ -n "$CHOSEN" ]; then
  write_state "$CHOSEN" "$CHOSEN_VER" ok "修复成功（trigger=${TRIGGER}）" "$(date '+%Y-%m-%d %H:%M:%S')"
  logline "✅ 代理已修好并在跑：${CHOSEN}（Python ${CHOSEN_VER}）"
  exit 0
fi

ERRLINE="$(tail -3 "$VISION_DIR/proxy.err.log" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
if [ "$DRY_RUN" = 1 ]; then
  say "dry-run：没有可用解释器（按候选清单逐个试过）"
  exit 1
fi
write_state "${SKIP:-none}" "?" failed "没有可用解释器，或起来了端口也无响应" "$PREV_REPAIR"
logline "❌ 代理没能起来。下一步：点「配置」重装一次；日志：$LOG 和 $VISION_DIR/proxy.err.log${ERRLINE:+（最后几行：${ERRLINE}）}"
exit 1
