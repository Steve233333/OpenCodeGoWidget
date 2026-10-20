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

# ① 改名前的旧 launchd 任务：这里只报告，不提前停。
#    真正停服务必须等 90-proxy 把新 Key 落盘之后，否则中途失败会让机器没有可用代理。
if launchctl list 2>/dev/null | grep -q "$STALE_OLD_LABEL"; then
  log "  发现旧任务 ${STALE_OLD_LABEL} 仍在运行；稍后由代理步骤停掉并接管"
fi
if [[ -f "$STALE_OLD_PLIST" ]]; then
  log "  发现旧 plist ${STALE_OLD_PLIST}；稍后由代理步骤备份并摘除"
fi

# ② 旧安装目录：这里只停运行时，不在这里迁移。
#    迁移必须等 90-proxy 把“本次刚输入的 Key”写进新 env 之后再做；以前迁移跑在写 Key
#    之前，会拿旧 env 里的过期 Key 做真机自检，401 后自动回滚到旧服务（2026-10-20 事故）。
if [[ -d "$OLD_APP_DIR" && ! -L "$OLD_APP_DIR" ]]; then
  log "  检测到未迁移的旧安装（${OLD_APP_DIR}）→ 等新 Key/新代码同步后由代理步骤迁移"
fi

# ③ 端口占用体检：确保 19100 上没有"别的进程"（不是我们的 agent-relay）
_port_pids="$(lsof -nP -iTCP:19100 -sTCP:LISTEN -t 2>/dev/null | sort -u)"
if [[ -n "$_port_pids" ]]; then
  _unexpected=""
  _ours=0
  for _pid in ${(f)_port_pids}; do
    _cmd="$(ps -p "$_pid" -o command= 2>/dev/null || true)"
    case "$_cmd" in
      *"$HOME/.local/share/agent-relay/relay.py"*) _ours=1 ;;
      *) _unexpected="${_unexpected}pid=${_pid} ${_cmd}; " ;;
    esac
  done
  if [[ -n "$_unexpected" ]]; then
    log "  WARN: 19100 还被这些非预期进程占着：${_unexpected}"
    log "        下一步：代理步骤会停掉已知旧任务；未知进程需手动退出后重跑配置"
  elif [[ "$_ours" -eq 1 ]]; then
    log "  19100 由 agent-relay 占用（稍后会被强制重启换成新代码）"
  fi
fi

# ④ /Applications 里的旧版备份：只统计、不删（用户可能还要回退）。
#    这些副本带同 bundle id，会干扰 LaunchServices 解析（磁贴不刷新那次就是死登记害的）。
_old_backups="$(ls -d /Applications/OpenCode\ 小组件.app.bak-* 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$_old_backups" != "0" ]]; then
  log "  提示：/Applications 里有 ${_old_backups} 个旧版备份（不删，可留作回退）；若磁贴/启动异常可手动清理"
fi

log "升级前自愈完成"
