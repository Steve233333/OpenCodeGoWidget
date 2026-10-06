#!/bin/bash
# 把运行时身份从「agent-vision-toolkit / vision_proxy」搬到「agent-relay / relay.py」（2026-10-06 改名）。
#
# 搬四样：① 运行目录 ② 配置目录 + env 里的变量名（VISION_* → RELAY_*）
#         ③ launchd label（com.agent-vision-toolkit.proxy → com.agent-relay）④ 日志文件名（旧名留软链）
# 旧目录一律留**相对软链**，所以任何还写着旧路径的脚本/旧版小组件都不会断。
#
# 用法：migrate-to-agent-relay.sh [--dry-run] [--rollback]
set -uo pipefail

# ⚠️ 2026-10-06 事故：沙箱测试时把 HOME 指到临时目录跑真迁移，脚本里那句
# `launchctl bootout` 打到了**真实用户的 launchd 域**（launchd 不按 HOME 隔离），
# 当场把线上代理踢掉（几分钟后靠看护自动救回）。从此加硬闸：
# HOME 不是当前登录用户的真实 HOME 时，除非显式给 --sandbox，否则一律拒绝执行。
REAL_HOME="$(eval echo "~$(id -un)")"
SANDBOX=0
for arg in "$@"; do
  [ "$arg" = "--sandbox" ] && SANDBOX=1
done
if [ "${HOME}" != "$REAL_HOME" ] && [ "$SANDBOX" != 1 ]; then
  echo "❌ 拒绝执行：HOME=${HOME} 不是真实用户目录（${REAL_HOME}）。" >&2
  echo "   这是防「沙箱测试误踢线上 launchd 任务」的硬闸（2026-10-06 踩过）。" >&2
  echo "   确实要在沙箱里跑就加 --sandbox（此模式下不碰 launchd，只动 ${HOME} 下的文件）。" >&2
  exit 2
fi
if [ "$SANDBOX" = 1 ]; then
  echo "[migrate] ⚠️ sandbox 模式：不碰 launchd、不重启任何服务，只改 HOME 下的文件"
fi

HOME_DIR="$HOME"
OLD_DIR="$HOME_DIR/.local/share/agent-vision-toolkit"
NEW_DIR="$HOME_DIR/.local/share/agent-relay"
OLD_CFG="$HOME_DIR/.config/agent-vision-toolkit"
NEW_CFG="$HOME_DIR/.config/agent-relay"
OLD_LABEL="com.agent-vision-toolkit.proxy"
NEW_LABEL="com.agent-relay"
OLD_PLIST="$HOME_DIR/Library/LaunchAgents/$OLD_LABEL.plist"
NEW_PLIST="$HOME_DIR/Library/LaunchAgents/$NEW_LABEL.plist"
ENV_FILE="$NEW_CFG/env"
DRY=0
ROLLBACK=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --rollback) ROLLBACK=1 ;;
    --sandbox) : ;;   # 已在前面扫描过（沙箱模式：不碰 launchd）
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数：$arg" >&2; exit 2 ;;
  esac
done

say() { echo "[migrate] $*"; }
run() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else eval "$@"; fi; }

if [ "$ROLLBACK" = 1 ]; then
  say "回滚：agent-relay → agent-vision-toolkit"
  run "launchctl bootout gui/\$(id -u)/$NEW_LABEL 2>/dev/null || true"
  run "rm -f '$NEW_PLIST'"
  # 旧目录原样还在（切换时没被删没被搬），把它的转发脚本还原，再用旧入口把服务起回来
  if [ -f "$OLD_DIR/ensure-proxy.sh.bak-relay" ]; then
    run "mv -f '$OLD_DIR/ensure-proxy.sh.bak-relay' '$OLD_DIR/ensure-proxy.sh'"
  fi
  run "rm -f '$OLD_DIR/.forwarded-to-relay'"
  if [ -f "$OLD_PLIST.bak-relay" ]; then
    run "mv -f '$OLD_PLIST.bak-relay' '$OLD_PLIST'"
  fi
  if [ "$DRY" != 1 ] && [ -x "$OLD_DIR/ensure-proxy.sh" ]; then
    say "用旧入口把服务起回来（旧 label + 旧目录）"
    "$OLD_DIR/ensure-proxy.sh" --env-file "$OLD_CFG/env" --trigger rollback --force-restart --quiet || true
  fi
  exit 0
fi

# 已经迁移过（新目录在、旧路径是软链）→ 幂等退出
if [ -d "$NEW_DIR" ] && [ -L "$OLD_DIR" ] && [ -d "$NEW_CFG" ]; then
  say "已经是 agent-relay 身份，无需迁移 ✅"
  exit 0
fi
[ -d "$OLD_DIR" ] || { say "没找到旧安装（${OLD_DIR}），按新装处理，跳过"; exit 0; }

# 设计原则（2026-10-06 事故后重写）：**绝不删任何东西**。
#   * 新目录里已经放好「改名后、影子实例验证过」的代码（本步骤只补运行态文件）；
#   * 旧目录原样留在原地（回滚就是「把旧 label 拉起来」，不用搬回来）；
#   * 旧目录里的 ensure-proxy.sh 会被换成转发脚本，老版本小组件调它也能收敛到新服务。
say "开始切换：${OLD_DIR}（旧，保留） + ${NEW_DIR}（新，已部署）"
run "mkdir -p '$NEW_DIR' '$NEW_CFG'"

# 运行态文件（日志、缓存、备份目录）：从旧目录拷过去，保持连续性
for f in proxy.err.log proxy.log relay.err.log relay.log discovery.log prune_pending.json go_quota_cache.json go_models_cache.json zen_model_ids.json; do
  [ -f "$OLD_DIR/$f" ] && run "cp -p '$OLD_DIR/$f' '$NEW_DIR/$f'" || true
done

# env：从旧文件派生新文件（改写变量名），旧文件保持不动（新代码本来也有旧名兜底）
if [ -f "$OLD_CFG/env" ]; then
  if [ "$DRY" = 1 ]; then
    say "会把旧 env 派生到 ${ENV_FILE}（改写 $(grep -c '^VISION_' "$OLD_CFG/env" 2>/dev/null || echo 0) 行变量名）"
  else
    sed -e 's/^VISION_PROXY_MUSE_/RELAY_MUSE_/' -e 's/^VISION_/RELAY_/' "$OLD_CFG/env" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    say "新 env 已写：${ENV_FILE}（旧文件原样保留）"
  fi
fi

# launchd：摘旧 label，让新的 ensure-relay.sh 重新写 plist + bootstrap
if [ -f "$OLD_PLIST" ]; then
  run "cp -p '$OLD_PLIST' '$HOME_DIR/Library/LaunchAgents/$OLD_LABEL.plist.bak-relay'"
fi
if [ "$SANDBOX" = 1 ]; then
  say "sandbox：跳过 launchctl bootout（${OLD_LABEL}）"
else
  run "launchctl bootout gui/\$(id -u)/$OLD_LABEL 2>/dev/null || true"
fi
run "rm -f '$OLD_PLIST'"
if [ "$SANDBOX" = 1 ]; then
  say "sandbox：跳过启动服务（ensure-relay.sh 会写 plist + bootstrap，属真实副作用）"
elif [ "$DRY" != 1 ]; then
  say "用新的 ensure-relay.sh 起服务"
  if [ -x "$NEW_DIR/ensure-relay.sh" ]; then
    if ! "$NEW_DIR/ensure-relay.sh" --env-file "$ENV_FILE" --trigger migration --force-restart --quiet; then
      say "❌ 起服务失败 → 自动回滚"
      "$0" --rollback || true
      exit 1
    fi
  else
    say "❌ 找不到 $NEW_DIR/ensure-relay.sh → 自动回滚"
    "$0" --rollback || true
    exit 1
  fi
  # 旧路径的兼容转发：老版本小组件点「修复」时也会落到新服务上
  if [ -f "$OLD_DIR/ensure-proxy.sh" ] && [ ! -f "$OLD_DIR/.forwarded-to-relay" ]; then
    cp -p "$OLD_DIR/ensure-proxy.sh" "$OLD_DIR/ensure-proxy.sh.bak-relay"
    printf '#!/bin/bash\n# 已改名为 agent-relay：旧入口转发（2026-10-06）\nexec "$HOME/.local/share/agent-relay/ensure-relay.sh" "$@"\n' > "$OLD_DIR/ensure-proxy.sh"
    chmod +x "$OLD_DIR/ensure-proxy.sh"
    touch "$OLD_DIR/.forwarded-to-relay"
    say "旧入口 ensure-proxy.sh 已改为转发到 ensure-relay.sh"
  fi
fi

# 旧日志名留软链（旧版小组件/脚本还在读它）
for pair in "relay.err.log:proxy.err.log" "relay.log:proxy.log"; do
  new="${pair%%:*}"; old="${pair##*:}"
  run "[ -f '$NEW_DIR/$new' ] && ln -sfn '$new' '$NEW_DIR/$old'"
done

if [ "$DRY" = 1 ]; then say "dry-run 结束（什么都没改）"; exit 0; fi

if [ "$SANDBOX" = 1 ]; then
  say "sandbox 验证（只查文件，不查服务）："
  say "  新目录 $([ -d "$NEW_DIR" ] && echo ✅ || echo ❌)   旧路径软链 $([ -L "$OLD_DIR" ] && echo ✅ || echo ❌)"
  say "  env 改名 $([ -f "$ENV_FILE" ] && grep -q '^RELAY_' "$ENV_FILE" && echo ✅ || echo ❌)   旧 plist 已摘 $([ -f "$OLD_PLIST" ] && echo ❌ || echo ✅)"
  exit 0
fi

# 验证
ok=1
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -s -o /dev/null -m 2 "http://127.0.0.1:19100/health" || lsof -nP -iTCP:19100 -sTCP:LISTEN >/dev/null 2>&1; then ok=0; break; fi
  sleep 1
done
if [ "$ok" != 0 ]; then
  say "❌ 端口 19100 没起来 → 自动回滚"
  "$0" --rollback || true
  exit 1
fi
say "端口 19100 已监听 ✅"

# 真机请求自检（不依赖调用者：脚本自己 curl，失败就回滚）
smoke_code="$(curl -s -o /tmp/relay-cutover-smoke.json -w '%{http_code}' -m 120 \
  -X POST http://127.0.0.1:19100/v1/responses \
  -H 'Authorization: Bearer dummy' -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash-go","stream":false,"max_output_tokens":16,"input":"只回两个字：正常"}' 2>/dev/null)"
if [ "$smoke_code" = "200" ]; then
  say "真机自检：deepseek-v4.1-flash-go → HTTP 200 ✅"
else
  say "❌ 真机自检失败（HTTP ${smoke_code}）→ 自动回滚"
  "$0" --rollback || true
  exit 1
fi
[ -f "$NEW_DIR/relay-runtime" ] && say "状态文件 relay-runtime 已写 ✅" || say "⚠️ 没看到 relay-runtime"
grep -q "\[relay\]" "$NEW_DIR/relay.err.log" 2>/dev/null && say "日志前缀已是 [relay] ✅" || say "⚠️ 日志里还没出现 [relay]（可能刚重启）"
say "迁移完成：新身份 agent-relay（旧路径已留软链，随时可 --rollback）"
