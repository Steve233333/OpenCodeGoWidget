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
#   ensure-relay.sh [--env-file PATH] [--vision-dir PATH] [--port N]
#                   [--trigger installer|watchdog|manual] [--check-only] [--dry-run] [--quiet]
#                   [--force-restart]
# 退出码：0 = 代理已验证在跑；1 = 这次没能让它跑起来；2 = 参数/环境问题
#
# 测试用的两个口子（正常跑不用管）：
#   ENSURE_PROXY_CANDIDATES=/a/python3:/b/python3   覆盖候选解释器清单
#   PROXY_LABEL / PROXY_PLIST                       覆盖 launchd label 与 plist 路径
set -uo pipefail

RELAY_DIR="$HOME/.local/share/agent-relay"
ENV_FILE="$HOME/.config/agent-relay/env"
PORT=19100
TRIGGER=manual
CHECK_ONLY=0
DRY_RUN=0
FORCE_RESTART=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --env-file)   ENV_FILE="$2"; shift 2 ;;
    --vision-dir) RELAY_DIR="$2"; shift 2 ;;
    --port)       PORT="$2"; shift 2 ;;
    --trigger)    TRIGGER="$2"; shift 2 ;;
    --check-only) CHECK_ONLY=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --force-restart) FORCE_RESTART=1; shift ;;
    --quiet)      QUIET=1; shift ;;
    *) echo "ensure-proxy: 不认识的参数 $1" >&2; exit 2 ;;
  esac
done

LABEL="${PROXY_LABEL:-com.agent-relay}"
PLIST="${PROXY_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
LEGACY_LABEL="${LEGACY_PROXY_LABEL:-com.agent-vision-toolkit.proxy}"
LEGACY_PLIST="${LEGACY_PROXY_PLIST:-$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist}"
RUNTIME="$RELAY_DIR/relay-runtime"
LOG="$RELAY_DIR/ensure-relay.log"
UID_NUM="$(/usr/bin/id -u)"

say() { [ "$QUIET" = 1 ] || echo "$@"; }
logline() {
  # --dry-run 不落任何文件（连日志也不写），只从 stdout 报它"会做什么"
  if [ "$DRY_RUN" != 1 ]; then
    mkdir -p "$RELAY_DIR" 2>/dev/null
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

# 2026-10-19：**端口通 ≠ 跑的是我们的代码**。
#
# 老机器升级时的坑：改名前的旧 launchd 任务（com.agent-vision-toolkit.proxy）可能还活着、
# 还占着 19100；而 probe() 只看"端口有没有响应"，于是这里判定"代理已在运行"、直接 exit 0 ——
# 安装器刚同步的新代码根本没被加载，用户看到的就是「配置了没效果」。
#
# 这个函数回答："监听端口的是不是从 ${RELAY_DIR}/relay.py 跑起来的？"
#   0 = 是；1 = 没人监听，或明显是别的程序。
port_owned_by_relay() {
  local pids
  pids="$(/usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u)"
  [ -z "$pids" ] && return 1                      # 没人监听
  local pid
  for pid in $pids; do
    local cmd
    cmd="$(/bin/ps -p "$pid" -o command= 2>/dev/null)"
    case "$cmd" in
      *"$RELAY_DIR/relay.py"*) return 0 ;;
    esac
  done
  return 1                                        # 端口被别的进程占着
}

listener_commands() {
  local pids pid cmd
  pids="$(/usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u)"
  [ -z "$pids" ] && return 0
  for pid in $pids; do
    cmd="$(/bin/ps -p "$pid" -o command= 2>/dev/null)"
    printf 'pid=%s %s\n' "$pid" "$cmd"
  done
}

# 只退场已知的改名前服务。未知进程绝不自动杀，避免 “修复代理” 误伤别的软件。
stop_legacy_job() {
  if [ "$DRY_RUN" = 1 ]; then
    say "dry-run：会停用旧服务 ${LEGACY_LABEL} 并摘掉 ${LEGACY_PLIST}（不写任何文件）"
    return 0
  fi
  if /bin/launchctl print "gui/$UID_NUM/$LEGACY_LABEL" >/dev/null 2>&1; then
    logline "停用旧服务 ${LEGACY_LABEL}"
    /bin/launchctl bootout "gui/$UID_NUM/$LEGACY_LABEL" >/dev/null 2>&1 || true
  fi
  if [ -f "$LEGACY_PLIST" ]; then
    [ -f "$LEGACY_PLIST.bak-legacy" ] || cp -p "$LEGACY_PLIST" "$LEGACY_PLIST.bak-legacy" 2>/dev/null || true
    /bin/launchctl bootout "gui/$UID_NUM" "$LEGACY_PLIST" >/dev/null 2>&1 \
      || /bin/launchctl unload "$LEGACY_PLIST" >/dev/null 2>&1 || true
    rm -f "$LEGACY_PLIST"
    logline "旧 plist 已退场（备份 ${LEGACY_PLIST}.bak-legacy）"
  fi
  # 旧 label 可能已经被摘掉，但进程仍从旧目录运行；只按完整旧入口路径收口。
  # 路径拆成变量拼接：旧版更新器的“外部路径”规则会误把相对段当成开发目录引用。
  local legacy_dir_name="agent-vision-toolkit"
  local legacy_entry_name="vision_proxy.py"
  local pids pid cmd
  pids="$(/usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u)"
  for pid in $pids; do
    cmd="$(/bin/ps -p "$pid" -o command= 2>/dev/null)"
    case "$cmd" in
      *"$HOME/.local/share/${legacy_dir_name}/${legacy_entry_name}"*)
        logline "结束仍在占用端口的旧 vision_proxy（pid ${pid}）"
        kill -TERM "$pid" 2>/dev/null || true
        local i=0
        while [ "$i" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
          /bin/sleep 0.2
          i=$((i + 1))
        done
        kill -KILL "$pid" 2>/dev/null || true
        ;;
    esac
  done
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
    <string>$RELAY_DIR/relay.py</string>
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
  <key>StandardOutPath</key><string>$RELAY_DIR/relay.log</string>
  <key>StandardErrorPath</key><string>$RELAY_DIR/relay.err.log</string>
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

wait_relay_ready() {
  local i=0 n="$1"
  while [ "$i" -lt "$n" ]; do
    if probe && port_owned_by_relay; then return 0; fi
    /bin/sleep 1
    i=$((i + 1))
  done
  return 1
}

relay_functional_ready() {
  # /v1/models 在本代理里固定回 401，只证明 HTTP 活着，不能证明上游 Key 有效。
  # 真正发一条 8-token 请求：200 才算端到端可用；429 说明 Key 有效但限流。
  local out code
  out="$(mktemp)"
  code="$(/usr/bin/curl -s -o "$out" -w '%{http_code}' -m 30 \
    -X POST "http://127.0.0.1:$PORT/v1/responses" \
    -H 'Authorization: Bearer relay-functional-check' \
    -H 'Content-Type: application/json' \
    -d '{"model":"deepseek-v4.1-flash-go","stream":false,"max_output_tokens":8,"input":"reply OK"}' 2>/dev/null || true)"
  case "$code" in
    2??|429) rm -f "$out"; return 0 ;;
    401|403)
      say "上游拒绝 Key（HTTP ${code}）：$(head -c 200 "$out" 2>/dev/null | tr '\n' ' ')"
      rm -f "$out"; return 1 ;;
    402|404|410)
      # 探测模型可能已下线；这是“探针过时”，不是当前 Key 失效。
      say "功能自检跳过（HTTP ${code}：探针模型可能已下线，不代表 Key 失效）：$(head -c 160 "$out" 2>/dev/null | tr '\n' ' ')"
      rm -f "$out"; return 2 ;;
    5??)
      # 上游网关偶发 5xx，不能据此报“配置失败”；监听与 Key 检查照常保留。
      say "功能自检暂不可用（HTTP ${code} 上游故障，稍后自动重试）：$(head -c 160 "$out" 2>/dev/null | tr '\n' ' ')"
      rm -f "$out"; return 2 ;;
    *)
      say "功能自检异常（HTTP ${code:-无响应}）：$(head -c 160 "$out" 2>/dev/null | tr '\n' ' ')"
      rm -f "$out"; return 1 ;;
  esac
}

# 状态文件：只由本脚本写（App 只读它显示"当前解释器 / 上次自动修复时间"）
write_state() {
  local interp="$1" version="$2" result="$3" detail="$4" repair_at="$5"
  mkdir -p "$RELAY_DIR" 2>/dev/null
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
  mkdir -p "$RELAY_DIR" "$(dirname "$ENV_FILE")" 2>/dev/null
  if [ ! -f "$ENV_FILE" ]; then
    : > "$ENV_FILE" 2>/dev/null
  fi
  chmod 600 "$ENV_FILE" 2>/dev/null || true
fi

if [ "$CHECK_ONLY" = 1 ]; then
  if probe && port_owned_by_relay; then exit 0; else exit 1; fi
fi

PREV_REPAIR="$(state_get last_repair_at)"

# ---- 已经在跑：只更新状态，什么都不动（--force-restart 除外：配置刚同步完新代码，必须换新的）----
# 2026-10-19：先确认端口后面真的是我们的进程；被旧任务/别的程序占着时要抢回来，
# 否则"配置"会静默地什么都不做（老机器升级的经典症状）。
if probe && ! port_owned_by_relay; then
  logline "端口 ${PORT} 有响应但**不是 agent-relay 的进程**（当前监听者：$(listener_commands | tr '\n' ';' )）"
  # 先起新代码的临时实例（不依赖端口），再停旧任务；新实例失败时旧服务仍在。
  if [ "$DRY_RUN" != 1 ]; then
    relay_py="$RELAY_DIR/relay.py"
    relay_port=$((PORT + 17))
    "$relay_py" --port "$relay_port" --upstream https://api.deepseek.com/ --env-file "$ENV_FILE" >>"$RELAY_DIR/relay.err.log" 2>&1 &
    handover_pid=$!
    handover_ok=0
    for _i in 1 2 3 4 5 6 7 8 9 10; do
      if curl -s -o /dev/null -m 1 "http://127.0.0.1:$relay_port/v1/models"; then handover_ok=1; break; fi
      sleep 0.5
    done
    kill "$handover_pid" 2>/dev/null || true
    wait "$handover_pid" 2>/dev/null || true
    if [ "$handover_ok" -ne 1 ]; then
      logline "❌ 新代理在备用端口 ${relay_port} 没起来；旧服务保持原样，不抢端口"
      exit 1
    fi
    logline "新代理备用端口自检通过；现在停旧服务并切到 ${PORT}"
  fi
  stop_legacy_job
  /bin/sleep 1
  if probe && ! port_owned_by_relay; then
    logline "❌ 已知旧服务已尝试退场，但端口仍被其他进程占用：$(listener_commands | tr '\n' ';' )"
    [ "$DRY_RUN" = 1 ] || write_state "unknown" "?" failed "端口被非 agent-relay 进程占用" "$PREV_REPAIR"
    exit 1
  fi
  logline "旧服务已退场，继续启动 agent-relay"
  FORCE_RESTART=1
fi
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
  if wait_relay_ready 12; then
    CHOSEN="$cand"; CHOSEN_VER="$ver"
    break
  fi
  LAST_EXIT="$(/bin/launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null | awk '/last exit code/{print $NF}' | head -1)"
  logline "WARN: $cand 起了但 12 秒内没有出现由 ${RELAY_DIR}/relay.py 监听的就绪端口${LAST_EXIT:+（launchctl 最后退出码 ${LAST_EXIT}）}"
done < <(candidates)

if [ -n "$CHOSEN" ]; then
  if [ "${RELAY_SKIP_FUNCTIONAL_CHECK:-0}" != 1 ] && [ "$TRIGGER" != "watchdog" ]; then
    relay_functional_ready
    _probe_rc=$?
    if [ "$_probe_rc" -eq 1 ]; then
      write_state "$CHOSEN" "$CHOSEN_VER" failed "HTTP 已监听，但上游 Key 无效（401/403）" "$PREV_REPAIR"
      logline "❌ agent-relay 已监听 ${PORT}，但上游 Key 被拒绝（401/403）"
      exit 1
    elif [ "$_probe_rc" -eq 2 ]; then
      logline "⚠️ 代理已监听 ${PORT}；上游功能自检暂时不可用（非 Key 错误），继续保留代理"
    fi
  fi
  write_state "$CHOSEN" "$CHOSEN_VER" ok "修复成功（trigger=${TRIGGER}）" "$(date '+%Y-%m-%d %H:%M:%S')"
  logline "✅ 代理已修好并在跑：${CHOSEN}（Python ${CHOSEN_VER}）"
  exit 0
fi

ERRLINE="$(tail -3 "$RELAY_DIR/relay.err.log" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
if [ "$DRY_RUN" = 1 ]; then
  say "dry-run：没有可用解释器（按候选清单逐个试过）"
  exit 1
fi
write_state "${SKIP:-none}" "?" failed "没有可用解释器，或监听者不是 ${RELAY_DIR}/relay.py" "$PREV_REPAIR"
logline "❌ 代理没能起来。下一步：点「配置」重装一次；日志：$LOG 和 $RELAY_DIR/relay.err.log${ERRLINE:+（最后几行：${ERRLINE}）}"
exit 1
