#!/bin/zsh
# 步骤：8. 本地代理（Go/Zen 路由 + 协议桥接）
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径：zsh 默认会把被 source 文件的 $0 换掉，
#    路径推导统一放在主脚本（SCRIPT_DIR 已算好，直接用）。

# ---------------------------------------------------------------------------
# 8. 本地代理（有 Go Key 时安装：Go/Zen 路由 + 协议桥接）
# ---------------------------------------------------------------------------
PROXY_OK=0
RELAY_DIR="$HOME/.local/share/agent-relay"
if [[ "$USE_PROXY" -eq 1 ]]; then
  mkdir -p "$RELAY_DIR" "$HOME/.config/agent-relay"
  # 2026-09-05: 逐文件 mtime 比较同步（见 sync_newer_file），旧包不再整体覆盖本机
  if [ -d "$RES_DIR/relay" ]; then
    ( cd "$RES_DIR/relay" && find . -type f -print0 ) | while IFS= read -r -d '' _rel; do
      sync_newer_file "$RES_DIR/relay/$_rel" "$RELAY_DIR/$_rel"
    done
  else
    cp -R "$RES_DIR/relay/." "$RELAY_DIR/" 2>/dev/null || true
  fi
  touch "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
  tmp_env_x="$(mktemp)"
  # 2026-09-10：视觉链路下线，顺手把历史 VISION_* 三行从旧机器的 env 里清掉
  grep -vE '^(RELAY_API_KEY|RELAY_BASE_URL|RELAY_MODEL|ZEN_API_KEY)=' "$ENV_FILE" 2>/dev/null > "$tmp_env_x" || true
  {
    cat "$tmp_env_x"
    if ! grep -q '^LANG=' "$tmp_env_x" 2>/dev/null; then printf 'LANG=zh\n'; fi
    if [[ -n "$GO_KEY" ]]; then printf 'ZEN_API_KEY=%s\n' "$GO_KEY"; fi
  } > "$ENV_FILE.new"
  mv "$ENV_FILE.new" "$ENV_FILE"
  rm -f "$tmp_env_x"
  chmod 600 "$ENV_FILE"

  # 2026-10-20：**先写本次 Key，再迁移旧服务**。
  # 以前迁移在 85-preflight 里先跑，自检读到的是新 env 的上一把 Key；用户刚输入的新 Key
  # 要到这一步才落盘，于是真机自检 401 → 回滚旧服务 → Codex 继续用旧 Key。
  _legacy_dir="$HOME/.local/share/agent-vision-toolkit"
  _migration_marker="$RELAY_DIR/.legacy-vision-toolkit-migrated"
  if [[ -d "$_legacy_dir" && ! -f "$_migration_marker" ]]; then
    _migrate="$RES_DIR/scripts/migrate-to-agent-relay.sh"
    if [[ -x "$_migrate" ]]; then
      log "阶段：迁移旧代理身份（新 Key 已写入，迁移自检会使用本次配置）…"
      if "$_migrate" >>"$LOG" 2>&1; then
        log "旧代理已迁移；旧 launchd 服务已退场"
      else
        log "WARN: 迁移未完成（详见日志）；随后仍会强制启动 agent-relay 并验证监听者"
      fi
    else
      log "WARN: 检测到旧安装，但找不到迁移脚本 ${_migrate}"
    fi
  else
    log "旧代理身份无需迁移（已迁移或没有旧安装）"
  fi
  # 旧目录保留作回滚快照，但旧 launchd plist 不该继续挂载；
  # ensure-relay 会再做一次精确收口，这里只提示。
  if [[ -f "$HOME/Library/LaunchAgents/com.agent-vision-toolkit.proxy.plist" ]]; then
    log "提示：旧 launchd plist 仍存在，随后由 ensure-relay 备份并移除"
  fi

  # 2026-09-19：python.org 的 Python 没跑过 "Install Certificates.command" 时没有 CA 根证书，
  # 代理所有 HTTPS 会 SSL: CERTIFICATE_VERIFY_FAILED（Codex 侧只看到 502，很难查）。
  # 能自动跑官方修复脚本就跑一次，别让用户自己去 /Applications 里双击。
  for _certcmd in /Applications/Python\ 3.*/Install\ Certificates.command; do
    if [[ -x "$_certcmd" ]]; then
      if "$_certcmd" >>"$LOG" 2>&1; then
        log "已自动运行 Python 证书修复：$(basename "$(dirname "$_certcmd")")"
      else
        log "WARN: Python 证书修复脚本执行失败（代理会走 /etc/ssl/cert.pem 兜底）"
      fi
    fi
  done
  # 2026-09-23（Phase 5）：挑解释器 / 写 plist / 起服务 / 探活**只有一份实现** = ensure-relay.sh。
  # 以前这里用 `command -v python3` 挑解释器：App 点「配置」时 PATH 很干净，命中的是
  # /usr/bin/python3（Xcode 自带的 3.9），刚升完 macOS 27 它一时起不来 → 代理 5 分钟没监听 →
  # Codex 侧就是 "Reconnecting… waiting for network"。现在由脚本逐个实测候选解释器再决定。
  if [[ "$SKIP_PROXY_START" -eq 0 ]]; then
    log "阶段：重启本地代理（ensure-proxy：实测挑解释器 → 起服务 → 探活）…"
    # --force-restart：这一步刚把新的代理代码同步下来，跑着的旧进程必须换掉才会生效
    if "$RELAY_DIR/ensure-relay.sh" --vision-dir "$RELAY_DIR" --env-file "$ENV_FILE" \
         --trigger installer --force-restart >>"$LOG" 2>&1; then
      PROXY_OK=1
      log "本地代理已启动并验证（127.0.0.1:19100）"
      if [[ "$HAS_GO" -eq 1 ]]; then
        _probe_out="$(mktemp)"
        _probe_code="$(curl -s -o "$_probe_out" -w '%{http_code}' -m 45 \
          -X POST "http://127.0.0.1:19100/v1/responses" \
          -H 'Authorization: Bearer relay-local-selfcheck' \
          -H 'Content-Type: application/json' \
          -d '{"model":"deepseek-v4.1-flash-go","stream":false,"max_output_tokens":8,"input":"只回两个字：正常"}' 2>/dev/null || true)"
        # ensure-relay 已在同一次启动中做过上游 Key 探测（401/403 会直接非 0）；
        # 这里再测一次只记录证据，不把上游偶发的 5xx 误判成 Key 无效。
        _probe_note="上游非 2xx，细节见 ensure-relay 自检"
        case "$_probe_code" in
          2??) _probe_note="实测通过" ;;
        esac
        log "代理 Key 自检：HTTP ${_probe_code:-无响应}（${_probe_note}）"
        rm -f "$_probe_out"
      fi
    else
      log "WARN: 代理这次没能起来（详见 $RELAY_DIR/ensure-relay.log）——App 的看护每 5 分钟会再试一次"
    fi
  else
    PROXY_OK=1
    log "代理文件已生成（--skip-proxy-start，未启动服务）"
  fi

  # 解释器只挑一次：Go 模型自动发现任务复用 ensure-proxy 挑中的那个（同一个决定，两处用）
  PY_BIN="$(sed -n 's/^interpreter=//p' "$RELAY_DIR/relay-runtime" 2>/dev/null | head -1)"
  if [[ -z "$PY_BIN" || ! -x "$PY_BIN" ]]; then
    for _cand in /Library/Frameworks/Python.framework/Versions/*/bin/python3 \
                 /usr/local/bin/python3 /opt/homebrew/bin/python3 /usr/bin/python3; do
      if [[ -x "$_cand" ]]; then PY_BIN="$_cand"; break; fi
    done
  fi
  log "Go 发现任务用的解释器：$PY_BIN"

  # Go 模型自动发现（quota 表 6h + 启动，跟表自动同步，限免自动识别）
  if [[ "$HAS_GO" -eq 1 ]]; then
    DISCOVERY_PLIST="$HOME/Library/LaunchAgents/com.steve233.go-model-discovery.plist"
    cat > "$DISCOVERY_PLIST" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.steve233.go-model-discovery</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY_BIN</string>
    <string>$RELAY_DIR/model_discovery.py</string>
    <string>--sync</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SSL_CERT_FILE</key><string>/etc/ssl/cert.pem</string>
  </dict>
  <key>StartInterval</key><integer>21600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$RELAY_DIR/discovery.log</string>
  <key>StandardErrorPath</key><string>$RELAY_DIR/discovery.err.log</string>
</dict>
</plist>
EOF2
    launchctl bootout "gui/$(id -u)" "$DISCOVERY_PLIST" 2>/dev/null || launchctl unload "$DISCOVERY_PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$DISCOVERY_PLIST" 2>/dev/null || launchctl load "$DISCOVERY_PLIST" 2>/dev/null || true
    log "Go 模型自动发现已安装（6h + 启动，跟配额表自动同步）"
    # 立即同步一次（quota表 -> models.json，需联网约 10~20 秒，详细输出只写文件日志）
    log "阶段：同步 Go 模型配额表（需联网，请耐心等待）…"
    "$PY_BIN" "$RELAY_DIR/model_discovery.py" --sync --force >>"$LOG" 2>&1 || log "WARN: 首次 Go 模型同步失败，详见 $RELAY_DIR/discovery.err.log"
    # 2026-10-20：只重算派生表（从刚生成的 models.json 生成代理档位表 + 桌面滑杆），
    # 不联网、不改模型列表。以前这一步要等 6 小时定时任务，切模型后档位/上下文会暂时对不上。
    "$PY_BIN" "$RELAY_DIR/model_discovery.py" --sync-derived >>"$LOG" 2>&1 || log "WARN: 档位表重算失败，详见 $RELAY_DIR/discovery.err.log"
    log "配额表同步步骤结束"
  fi
else
  log "无需本地代理（纯官方 DeepSeek 直连）"
  # 2026-09-14：没有 Go Key 时清掉残留的 Go 链路服务——否则旧代理还占着 19100，
  # Go 模型自动发现还会每 6h 把 -go 模型写回 models.json，导致 Codex 里能选到
  # 用不了的 Go 模型（选中会被直连发给 DeepSeek 官方报 model 不支持）。
  # 之后加回 Go Key 再点配置，这两项会自动重新安装。
  STALE_PROXY_PLIST="$HOME/Library/LaunchAgents/com.agent-relay.plist"
  STALE_DISCOVERY_PLIST="$HOME/Library/LaunchAgents/com.steve233.go-model-discovery.plist"
  launchctl bootout "gui/$(id -u)" "$STALE_PROXY_PLIST" 2>/dev/null || launchctl unload "$STALE_PROXY_PLIST" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/com.steve233.go-model-discovery" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)" "$STALE_DISCOVERY_PLIST" 2>/dev/null || launchctl unload "$STALE_DISCOVERY_PLIST" 2>/dev/null || true
  rm -f "$STALE_PROXY_PLIST" "$STALE_DISCOVERY_PLIST"
  log "已停用残留的本地代理与 Go 模型自动发现"
fi
