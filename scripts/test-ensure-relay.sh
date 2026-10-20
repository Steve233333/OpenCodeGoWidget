#!/bin/bash
# 说大白话：把"挑解释器 + 起代理 + 探活"这套逻辑离线验一遍（不碰你正在跑的代理）。
# 2026-09-23：macOS 27 升级后 App 点「配置」挑到了 Xcode 自带的 Python 3.9，代理 5 分钟没起来，
# Codex 就一直 "Reconnecting… waiting for network"。这个测试锁住修复后的行为：
#   ① 坏的解释器会被跳过，选第一个真能跑的
#   ② 全都不行时退出码非 0，且不写脏文件
#   ③ 只剩 /usr/bin/python3 时给明确警告
#   ④ 真起一次（临时 label + 临时端口 + 临时目录）：状态文件写对、端口真的有响应
#   ⑤ 已经在跑时再跑一次是幂等的（不重启、不刷日志）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VISION_SRC="$ROOT/Resources/codex/relay"
TMP="$(mktemp -d)"
TEST_LABEL="com.steve233.opencodego.proxytest.$$"
TEST_PORT=19531
fail=0

cleanup() {
  /bin/launchctl bootout "gui/$(/usr/bin/id -u)/$TEST_LABEL" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

ok()   { echo "  ✅ $1"; }
bad()  { echo "  ❌ $1"; fail=1; }

# 假的解释器存根：broken 立刻失败，hang 卡住（模拟 /usr/bin/python3 弹窗），good 报版本
mkdir -p "$TMP/bin"
printf '#!/bin/bash\nexit 3\n' > "$TMP/bin/broken"
printf '#!/bin/bash\nsleep 30\n' > "$TMP/bin/hang"
printf '#!/bin/bash\necho 3.99.0\n' > "$TMP/bin/good"
chmod +x "$TMP/bin/"*

ensure="$VISION_SRC/ensure-relay.sh"

echo "==> 代理生命周期自检（ensure-relay.sh）"

# ① 坏的在前面 → 选 good
out="$(ENSURE_PROXY_CANDIDATES="$TMP/bin/broken:$TMP/bin/good" bash "$ensure" \
        --port 19999 --vision-dir "$TMP/v1" --env-file "$TMP/env1" --dry-run --trigger test 2>&1)"
rc=$?
if [ "$rc" = 0 ] && echo "$out" | grep -q "$TMP/bin/good" && echo "$out" | grep -q "解释器不可用"; then
  ok "① 跳过跑不起来的解释器，选第一个能跑的"
else
  bad "① 解释器挑选不对（rc=${rc}）：$out"
fi

# ② 全坏 → rc=1 且不写任何文件
ENSURE_PROXY_CANDIDATES="$TMP/bin/broken" bash "$ensure" \
  --port 19999 --vision-dir "$TMP/v2" --env-file "$TMP/env2" --dry-run --trigger test >/dev/null 2>&1
rc=$?
wrote="$(ls -A "$TMP/v2" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$rc" = 1 ] && [ "$wrote" = 0 ]; then
  ok "② 没有可用解释器时退出码 1，且不写脏文件"
else
  bad "② 全坏时行为不对（rc=${rc}，写了 $wrote 个文件）"
fi

# ③ 只有系统兜底解释器 → 明确警告（dry-run，不会真起服务）
out="$(ENSURE_PROXY_CANDIDATES="/usr/bin/python3" bash "$ensure" \
        --port 19999 --vision-dir "$TMP/v3" --env-file "$TMP/env3" --dry-run --trigger test 2>&1)"
if echo "$out" | grep -q "系统兜底解释器"; then
  ok "③ 只剩 /usr/bin/python3 时给出「依赖 Xcode/命令行工具」的警告"
else
  bad "③ 没给出兜底警告：$out"
fi

# ④ 真起一次：临时 label + 临时端口 + 临时目录（跑完 cleanup 里 bootout）
mkdir -p "$TMP/v4"
cp -R "$VISION_SRC/proxy" "$TMP/v4/proxy"
cp "$VISION_SRC/relay.py" "$TMP/v4/relay.py"
: > "$TMP/env4"
out="$(PROXY_LABEL="$TEST_LABEL" PROXY_PLIST="$TMP/proxytest.plist" RELAY_SKIP_FUNCTIONAL_CHECK=1 bash "$ensure" \
        --port "$TEST_PORT" --vision-dir "$TMP/v4" --env-file "$TMP/env4" --trigger test 2>&1)"
rc=$?
interp="$(sed -n 's/^interpreter=//p' "$TMP/v4/relay-runtime" 2>/dev/null | head -1)"
result="$(sed -n 's/^last_result=//p' "$TMP/v4/relay-runtime" 2>/dev/null | head -1)"
repair_at="$(sed -n 's/^last_repair_at=//p' "$TMP/v4/relay-runtime" 2>/dev/null | head -1)"
code="$(/usr/bin/curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/v1/models" 2>/dev/null)"
if [ "$rc" = 0 ] && [ -n "$code" ] && [ "$code" != "000" ] && [ "$result" = "ok" ] && [ -n "$repair_at" ]; then
  ok "④ 真起成功：端口 $TEST_PORT 有响应（HTTP ${code}），状态文件记了 $interp / last_result=ok"
else
  bad "④ 真起失败（rc=${rc}，HTTP ${code:-无}，result=${result:-?}）：$out"
fi
listener_cmd="$(/usr/sbin/lsof -nP -iTCP:"$TEST_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 | xargs -I{} /bin/ps -p {} -o command= 2>/dev/null || true)"
if echo "$listener_cmd" | grep -qF "$TMP/v4/relay.py"; then
  ok "④a 监听者确实是临时目录里的 relay.py"
else
  bad "④a 监听者不是预期的 relay.py：${listener_cmd:-无}"
fi
if echo "$interp" | grep -q "^/Library/Frameworks/Python.framework"; then
  ok "④b 优先用了 python.org 的解释器（不是 /usr/bin/python3）"
else
  bad "④b 解释器优先级不对：${interp:-空}"
fi

# ④c 功能探针必须真的发出 POST /v1/responses，并把 401/403 判失败、200/429 判通过。
if awk '/^relay_functional_ready\(\)/{p=1} p{print} p&&/^}$/{exit}' "$ensure" \
     | grep -qF '/usr/bin/curl' \
   && awk '/^relay_functional_ready\(\)/{p=1} p{print} p&&/^}$/{exit}' "$ensure" \
     | grep -qF '2??|429' \
   && awk '/^relay_functional_ready\(\)/{p=1} p{print} p&&/^}$/{exit}' "$ensure" \
     | grep -qF '401|403'; then
  ok "④c 功能探针使用真实请求，401/403 拒绝、2xx/429 通过"
else
  bad "④c 功能探针逻辑缺失或被改回只看端口"
fi

# ⑤ 幂等：已经在跑时再跑一次 → rc=0，且不再往日志里刷行
before="$(wc -l < "$TMP/v4/ensure-relay.log" 2>/dev/null | tr -d ' ')"
PROXY_LABEL="$TEST_LABEL" PROXY_PLIST="$TMP/proxytest.plist" RELAY_SKIP_FUNCTIONAL_CHECK=1 bash "$ensure" \
  --port "$TEST_PORT" --vision-dir "$TMP/v4" --env-file "$TMP/env4" --trigger test >/dev/null 2>&1
rc=$?
after="$(wc -l < "$TMP/v4/ensure-relay.log" 2>/dev/null | tr -d ' ')"
if [ "$rc" = 0 ] && [ "$before" = "$after" ]; then
  ok "⑤ 已在跑时幂等：退出码 0、日志不刷（$before 行不变）"
else
  bad "⑤ 幂等性不对（rc=${rc}，日志 $before → $after 行）"
fi

# ⑥ --force-restart：配置刚同步完新代码，跑着的旧进程必须被换掉（否则新代码永远不生效）
pid_before="$(/bin/launchctl list | awk -v l="$TEST_LABEL" '$3 == l {print $1}')"
PROXY_LABEL="$TEST_LABEL" PROXY_PLIST="$TMP/proxytest.plist" RELAY_SKIP_FUNCTIONAL_CHECK=1 bash "$ensure" \
  --port "$TEST_PORT" --vision-dir "$TMP/v4" --env-file "$TMP/env4" \
  --trigger installer --force-restart >/dev/null 2>&1
rc=$?
pid_after=""
for _ in $(seq 1 10); do
  pid_after="$(/bin/launchctl list | awk -v l="$TEST_LABEL" '$3 == l {print $1}')"
  if [ -n "$pid_after" ] && [ "$pid_after" != "-" ] && [ "$pid_after" != "$pid_before" ]; then break; fi
  sleep 1
done
if [ "$rc" = 0 ] && [ -n "$pid_after" ] && [ "$pid_after" != "-" ] && [ "$pid_after" != "$pid_before" ]; then
  ok "⑥ --force-restart 会换掉跑着的旧进程（pid $pid_before → ${pid_after}）"
else
  bad "⑥ --force-restart 没换进程（rc=${rc}，pid $pid_before → ${pid_after:-空}）"
fi

# ⑥ 端口被"不是我们"的进程占着 → 不许判定"已在运行"（2026-10-19 老机器升级事故）
#    真实场景：改名前的旧任务 com.agent-vision-toolkit.proxy 还活着并绑着 19100，
#    旧代码只看"端口有响应"就 exit 0，安装器同步的新代码根本没生效。
echo "==> ⑥ 端口被别的进程占用时必须接管"
HEAL_PORT=19577
python3 - "$HEAL_PORT" <<'PY2' &
import socket, sys, time
port = int(sys.argv[1])
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port)); srv.listen(8)
end = time.time() + 25
while time.time() < end:
    try:
        srv.settimeout(1); c, _ = srv.accept()
        c.recv(65536)
        c.sendall(b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n")
        c.close()
    except Exception:
        pass
srv.close()
PY2
SQUATTER=$!
sleep 1
# 用 --port 19531 指向被占端口；进程不是从 vision-dir 起的 → 应判定"不是我们的"并强制接管
out="$(ENSURE_PROXY_CANDIDATES="$TMP/bin/good" bash "$ensure" \
        --port "$HEAL_PORT" --vision-dir "$TMP/v2" --env-file "$TMP/env2" --dry-run --trigger test 2>&1)"
if echo "$out" | grep -q "不是 agent-relay 的进程"; then
  ok "⑥ 端口被别的进程占用时判定为「不是我们的」并强制接管"
else
  bad "⑥ 端口被占用时仍被误判为健康；输出：$(echo "$out" | tail -3)"
fi
handover_line="$(grep -nF '新代理备用端口自检通过' "$ensure" | head -1 | cut -d: -f1)"
stop_line="$(grep -nF 'stop_legacy_job' "$ensure" | tail -1 | cut -d: -f1)"
if [ -n "$handover_line" ] && [ -n "$stop_line" ] && [ "$handover_line" -lt "$stop_line" ]; then
  ok "⑥a 备用端口预检在停旧服务之前"
else
  bad "⑥a 停旧服务早于备用端口预检（handover=${handover_line:-无}, stop=${stop_line:-无}）"
fi

# ⑥b 真跑一次：端口被未知进程占着时，ensure 必须失败，绝不能打印“已修好”。
mkdir -p "$TMP/v6"
cp -R "$VISION_SRC/proxy" "$TMP/v6/proxy"
cp "$VISION_SRC/relay.py" "$TMP/v6/relay.py"
: > "$TMP/env6"
set +e
out="$(ENSURE_PROXY_CANDIDATES="$TMP/bin/good" \
  PROXY_LABEL="$TEST_LABEL" PROXY_PLIST="$TMP/foreign.plist" \
  LEGACY_PROXY_LABEL="com.steve233.opencodego.legacytest.$$" \
  LEGACY_PROXY_PLIST="$TMP/legacy-foreign.plist" \
  bash "$ensure" --port "$HEAL_PORT" --vision-dir "$TMP/v6" --env-file "$TMP/env6" --trigger test 2>&1)"
rc=$?
set -uo pipefail
if [ "$rc" != "0" ] && ! echo "$out" | grep -q "✅ 代理已修好"; then
  ok "⑥b 未知进程占端口时返回非 0，不再报假成功"
else
  bad "⑥b 未知进程占端口仍报成功（rc=${rc}）：${out}"
fi
kill "$SQUATTER" 2>/dev/null || true
wait "$SQUATTER" 2>/dev/null || true

if [ "$fail" = 0 ]; then
  echo "全部通过 ✅"
  exit 0
fi
echo "有失败项 ❌"
exit 1
