#!/bin/zsh
# 步骤：配置后自检（必跑，2026-09-23 Phase 4 新增）
# 为什么要它：以前"配置完成"的汇总只报了模型数/默认模型/双开副本，**运行环境和一个关键服务的状态没写进日志**。
# 出问题时（内存里那条"新电脑刷新不出来"）只能靠用户口述 + 截图，看不到 sysctl/launchctl 的事实。
# 现在把三样东西固定写进日志：① 运行环境 ② 三个关键服务 ③ 每条失败的"下一步"。
# 只报告不中止：装完照样能用，失败项在日志里一眼可见。

log "===== 配置后自检 ====="

# ① 运行环境
_env_macos="$(sw_vers -productVersion 2>/dev/null || echo '?')"
_env_arch="$(uname -m 2>/dev/null || echo '?')"
_env_py="$(python3 -V 2>&1 || echo 'python3 缺失')"
_env_shell="$(ps -p $$ -o comm= 2>/dev/null | xargs basename 2>/dev/null || echo '?')"
log "环境：macOS ${_env_macos} · 架构 ${_env_arch} · ${_env_py} · 配置脚本用 ${_env_shell}"
log "环境：HOME=$HOME"

_sc_fail=0

# ② 三个关键服务/文件
# 2a. 本地代理（launchd）
if [[ "$SKIP_PROXY_START" -eq 1 ]]; then
  log "自检① 本地代理：已按 --skip-proxy-start 跳过启动（属预期）"
else
  _proxy_pid="$(launchctl list 2>/dev/null | awk '/com.agent-vision-toolkit.proxy/ {print $1}' | head -1)"
  if [[ -n "${_proxy_pid:-}" && "${_proxy_pid}" != "-" ]]; then
    log "自检① 本地代理：✅ 运行中（launchd pid ${_proxy_pid}）"
  else
    _sc_fail=$((_sc_fail + 1))
    log "自检① 本地代理：❌ launchd 里没有 com.agent-vision-toolkit.proxy"
    log "        下一步：看 ~/Library/LaunchAgents/com.agent-vision-toolkit.proxy.plist 有没有生成；再手动跑"
    log "        launchctl kickstart -k gui/$(id -u)/com.agent-vision-toolkit.proxy，然后 tail ~/.local/share/agent-vision-toolkit/proxy.err.log"
  fi
fi

# 2b. Codex 配置文件
if [[ -f "$CODEX_HOME/config.toml" ]]; then
  log "自检② Codex 配置：✅ $CODEX_HOME/config.toml 存在"
else
  _sc_fail=$((_sc_fail + 1))
  log "自检② Codex 配置：❌ 找不到 $CODEX_HOME/config.toml"
  log "        下一步：重新点一次「配置」（安装模式），把这次日志的最后 30 行发出来"
fi

# 2c. 双开副本（ChatGPT-Patched.app）
if [[ "$SKIP_PATCH" -eq 1 ]]; then
  log "自检③ 双开副本：已按 --skip-patch 跳过（属预期）"
elif [[ -d "$HOME/Applications/ChatGPT-Patched.app" ]]; then
  log "自检③ 双开副本：✅ ~/Applications/ChatGPT-Patched.app 存在"
else
  _sc_fail=$((_sc_fail + 1))
  log "自检③ 双开副本：❌ 没有 ~/Applications/ChatGPT-Patched.app"
  log "        下一步：看 ~/.codex/picker-patch/patch.log 最后 40 行（常见原因：官方版没装/没跑过一次）"
fi

# ③ 结论（明确下一步）
if [[ "$_sc_fail" -eq 0 ]]; then
  log "自检结论：✅ 全部通过（代理/配置/副本都对上了）"
else
  log "自检结论：❌ ${_sc_fail} 项没通过 —— 上面的「下一步」照着做；还不行就把本日志最后 40 行发出来：$LOG"
fi
log "===== 自检结束 ====="
