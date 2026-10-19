#!/bin/zsh
# 步骤：8a. 升级前自愈（2026-10-19）
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径。
#
# 为什么要有它：老机器升级时可能带着好几种"脏状态"，任何一种都会让「点配置」看起来没效果：
#   ① **改名残留**：10/06 把 agent-vision-toolkit 改名成 agent-relay，迁移脚本
#      `migrate-to-agent-relay.sh` 写好了却**从没被安装器调用过**。老机器上旧 label
#      `com.agent-vision-toolkit.proxy` 可能还活着、还占着 19100 —— 而 ensure-relay.sh
#      只要探测到端口有响应就认为"已在运行"，于是什么都不做：文件更新了，跑的还是旧进程。
#   ② **多个任务抢端口**：新旧两个 plist 同时登记时，谁先绑上 19100 谁说了算，重启后可能换人。
#   ③ **旧 App 副本**：/Applications 里历次更新留下的 `.bak-*` 会干扰系统解析（磁贴不刷新那次
#      就是死登记害的），也占空间。
#   ④ **旧版安装器的同步 bug**：9/19 之前的安装器按 mtime 判断"本机更新就跳过"，新代码永远落
#      不下来。那个 bug 已经修了，但前提是这台机器跑的是**新安装器**——这一步保证旧残留先清干净。
#
# 设计原则：**只清"运行时状态"，绝不删用户数据**（会话、配置、Key 一律不动）。
# 全部幂等：健康机器上跑一遍就是几行日志，什么都不会变。

STALE_OLD_LABEL="com.agent-vision-toolkit.proxy"
STALE_OLD_PLIST="$HOME/Library/LaunchAgents/${STALE_OLD_LABEL}.plist"
NEW_LABEL_NAME="com.agent-relay"
NEW_PLIST_FILE="$HOME/Library/LaunchAgents/${NEW_LABEL_NAME}.plist"
OLD_APP_DIR="$HOME/.local/share/agent-vision-toolkit"

log "阶段：升级前自愈（清理老版本残留的运行态，不动任何用户数据）…"

# ① 改名前的旧 launchd 任务：停掉并摘掉 plist（备份成 .bak-legacy，不直接删）
if launchctl list 2>/dev/null | grep -q "$STALE_OLD_LABEL"; then
  log "  发现旧任务 ${STALE_OLD_LABEL} 仍在运行 → 停掉（它可能正占着 19100）"
  launchctl bootout "gui/$(id -u)/${STALE_OLD_LABEL}" 2>/dev/null || true
  sleep 1
fi
if [[ -f "$STALE_OLD_PLIST" ]]; then
  cp -p "$STALE_OLD_PLIST" "${STALE_OLD_PLIST}.bak-legacy" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)" "$STALE_OLD_PLIST" 2>/dev/null || launchctl unload "$STALE_OLD_PLIST" 2>/dev/null || true
  rm -f "$STALE_OLD_PLIST"
  log "  旧 plist 已摘下（备份 ${STALE_OLD_PLIST}.bak-legacy）"
fi

# ② 旧安装目录：如果是真目录（不是迁移后的软链），说明这台机器从没跑过迁移。
#    交给迁移脚本处理（它会保留旧目录、把旧入口改成转发）；脚本不在就只记一行。
if [[ -d "$OLD_APP_DIR" && ! -L "$OLD_APP_DIR" ]]; then
  MIGRATE="$RES_DIR/scripts/migrate-to-agent-relay.sh"
  if [[ -x "$MIGRATE" ]]; then
    log "  检测到未迁移的旧安装（${OLD_APP_DIR}）→ 运行迁移脚本"
    if "$MIGRATE" >>"$LOG" 2>&1; then
      log "  迁移完成 ✅（旧目录保留、旧入口已改为转发到 agent-relay）"
    else
      log "  WARN: 迁移脚本返回非 0（详见日志）；继续走正常安装，下面的 ensure-relay 仍会收敛"
    fi
  else
    log "  WARN: 旧安装还在但找不到迁移脚本，跳过（后续步骤会覆盖运行态）"
  fi
fi

# ③ 端口占用体检：确保 19100 上没有"别的进程"（不是我们的 agent-relay）
_port_owners="$(lsof -nP -iTCP:19100 -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1" pid="$2}' | sort -u)"
if [[ -n "$_port_owners" ]]; then
  _unexpected=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      *python*|*Python*|*relay*|*agent*) : ;;   # 我们的代理（或它挑的解释器）属正常
      *) _unexpected="${_unexpected}${line}; " ;;
    esac
  done <<< "$_port_owners"
  if [[ -n "$_unexpected" ]]; then
    log "  WARN: 19100 还被这些非预期进程占着：${_unexpected}"
    log "        下一步：它们会让 Codex 连错地方；可在活动监视器里退出后重跑配置"
  else
    log "  19100 由代理进程占用（正常，稍后会被强制重启换成新代码）"
  fi
fi

# ④ /Applications 里的旧版备份：只统计、不删（用户可能还要回退）。
#    这些副本带同 bundle id，会干扰 LaunchServices 解析（磁贴不刷新那次就是死登记害的）。
_old_backups="$(ls -d /Applications/OpenCode\ 小组件.app.bak-* 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$_old_backups" != "0" ]]; then
  log "  提示：/Applications 里有 ${_old_backups} 个旧版备份（不删，可留作回退）；若磁贴/启动异常可手动清理"
fi

log "升级前自愈完成"
