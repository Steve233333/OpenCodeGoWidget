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
VISION_SRC="$ROOT/Resources/codex/vision"
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

ensure="$VISION_SRC/ensure-proxy.sh"

echo "==> 代理生命周期自检（ensure-proxy.sh）"

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
cp "$VISION_SRC/vision_proxy.py" "$TMP/v4/vision_proxy.py"
: > "$TMP/env4"
out="$(PROXY_LABEL="$TEST_LABEL" PROXY_PLIST="$TMP/proxytest.plist" bash "$ensure" \
        --port "$TEST_PORT" --vision-dir "$TMP/v4" --env-file "$TMP/env4" --trigger test 2>&1)"
rc=$?
interp="$(sed -n 's/^interpreter=//p' "$TMP/v4/proxy-runtime" 2>/dev/null | head -1)"
result="$(sed -n 's/^last_result=//p' "$TMP/v4/proxy-runtime" 2>/dev/null | head -1)"
repair_at="$(sed -n 's/^last_repair_at=//p' "$TMP/v4/proxy-runtime" 2>/dev/null | head -1)"
code="$(/usr/bin/curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$TEST_PORT/v1/models" 2>/dev/null)"
if [ "$rc" = 0 ] && [ -n "$code" ] && [ "$code" != "000" ] && [ "$result" = "ok" ] && [ -n "$repair_at" ]; then
  ok "④ 真起成功：端口 $TEST_PORT 有响应（HTTP ${code}），状态文件记了 $interp / last_result=ok"
else
  bad "④ 真起失败（rc=${rc}，HTTP ${code:-无}，result=${result:-?}）：$out"
fi
if echo "$interp" | grep -q "^/Library/Frameworks/Python.framework"; then
  ok "④b 优先用了 python.org 的解释器（不是 /usr/bin/python3）"
else
  bad "④b 解释器优先级不对：${interp:-空}"
fi

# ⑤ 幂等：已经在跑时再跑一次 → rc=0，且不再往日志里刷行
before="$(wc -l < "$TMP/v4/ensure-proxy.log" 2>/dev/null | tr -d ' ')"
PROXY_LABEL="$TEST_LABEL" PROXY_PLIST="$TMP/proxytest.plist" bash "$ensure" \
  --port "$TEST_PORT" --vision-dir "$TMP/v4" --env-file "$TMP/env4" --trigger test >/dev/null 2>&1
rc=$?
after="$(wc -l < "$TMP/v4/ensure-proxy.log" 2>/dev/null | tr -d ' ')"
if [ "$rc" = 0 ] && [ "$before" = "$after" ]; then
  ok "⑤ 已在跑时幂等：退出码 0、日志不刷（$before 行不变）"
else
  bad "⑤ 幂等性不对（rc=${rc}，日志 $before → $after 行）"
fi

if [ "$fail" = 0 ]; then
  echo "全部通过 ✅"
  exit 0
fi
echo "有失败项 ❌"
exit 1
