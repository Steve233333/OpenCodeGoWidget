#!/bin/zsh
# 步骤：9. ChatGPT-Patched.app 副本（patch）
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径：zsh 默认会把被 source 文件的 $0 换掉，
#    路径推导统一放在主脚本（SCRIPT_DIR 已算好，直接用）。

# ---------------------------------------------------------------------------
# 9. ChatGPT-Patched.app 副本（patch）
# ---------------------------------------------------------------------------
# 确保证书存在（新机）
if [[ "$SKIP_PATCH" -eq 0 ]]; then
  ensure_codex_signing_cert || log "WARN: 证书生成失败，仍将尝试 patch（可能回退 ad-hoc）"
fi

# 安装 codex-picker-patch 1h 常驻（skill §架构）
install_picker_patch_agent() {
  # 冻结策略（2026-09-04）：副本不再跟随官方自动更新，手动升级唯一入口为小组件配置按钮。
  # 此处只清理残留定时任务，不再写入/加载 plist，避免下次点配置又把自动更新装回来。
  local plist="$HOME/Library/LaunchAgents/com.steve233.codex-picker-patch.plist"
  launchctl bootout "gui/$(id -u)/com.steve233.codex-picker-patch" 2>/dev/null || launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || launchctl unload "$plist" 2>/dev/null || true
  rm -f "$plist" 2>/dev/null || true
  log "codex-picker-patch 自动更新已停用（副本冻结，手动升级走配置按钮）"
}

PATCH_OK=0
PATCH_VER_MSG=""
if [[ "$SKIP_PATCH" -eq 0 ]]; then
  mkdir -p "$PATCH_BASE/certs" "$PATCH_BASE/scripts"
  sync_newer_file "$RES_DIR/patch/patch.sh" "$PATCH_BASE/patch.sh"
  sync_newer_file "$RES_DIR/patch/ent2.plist" "$PATCH_BASE/certs/ent2.plist"
  # 预编译启动器：没装命令行工具（clang）的机器也能打出带 --user-data-dir 的副本
  sync_newer_file "$RES_DIR/patch/launcher-universal" "$PATCH_BASE/launcher-universal"
  chmod +x "$PATCH_BASE/launcher-universal" 2>/dev/null || true
  chmod 755 "$PATCH_BASE/patch.sh"
  if [[ -n "$PASS" ]]; then
    printf '%s' "$PASS" > "$PASS_FILE"
    chmod 600 "$PASS_FILE"
  fi
  install_picker_patch_agent
  # 版本感知重建：避免 --install 的 is_patched 短路
  SRC_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/ChatGPT.app/Contents/Info.plist 2>/dev/null | grep -v "Will Create" || true)"; if [[ -z "$SRC_VER" || "$SRC_VER" == "unknown" ]]; then SRC_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HOME/Applications/ChatGPT.app/Contents/Info.plist" 2>/dev/null | grep -v "Will Create" || true)"; fi; [[ -z "$SRC_VER" ]] && SRC_VER="unknown"
  MARKER_VER="$(sed -nE 's/.*"sourceVersion": *"([^"]*)".*/\1/p' "$PATCH_BASE/patch-state.json" 2>/dev/null | head -1)"
  NEED_REBUILD=0
  if [[ -z "$MARKER_VER" || "$SRC_VER" != "$MARKER_VER" ]]; then
    NEED_REBUILD=1
  fi
  # 注意：必须带括号匹配 "(patched)"，裸 "patched" 会连 "patched copy:" 未 patch 行也命中
  if ! bash "$PATCH_BASE/patch.sh" --status 2>&1 | grep -q "(patched)"; then
    NEED_REBUILD=1
  fi
  if [[ "$NEED_REBUILD" -eq 1 ]]; then
    log "阶段：重建副本（约需 1~2 分钟，期间日志较少请耐心等待，不要重复点击配置）…"
    # 官方已升级时副本常驻会阻止重建，更新模式下自动退出
    # 注意：匹配完整 bundle 路径，避免误杀安装器自身或其它含关键字的进程
    if pgrep -f "ChatGPT-Patched.app/Contents/MacOS" >/dev/null 2>&1; then
      if [[ "$MODE" == "update" ]]; then
        log "检测到官方已升级（$MARKER_VER -> $SRC_VER），副本仍在运行，尝试自动退出重建..."
        pkill -f "ChatGPT-Patched.app/Contents/MacOS" 2>/dev/null || true
        for _ in {1..10}; do pgrep -f "ChatGPT-Patched.app/Contents/MacOS" >/dev/null 2>&1 || break; sleep 0.5; done
      else
        log "WARN: 副本正在运行，重建将延后；请退出副本后重试 patch.sh --auto-update"
      fi
    fi
    if bash "$PATCH_BASE/patch.sh" --auto-update; then
      # --auto-update 在已是最新时无输出，仍视为成功
      PATCH_OK=1
      PATCH_VER_MSG="（$SRC_VER）"
      log "ChatGPT-Patched.app 已同步至 $SRC_VER"
    else
      # 回退：auto-update 可能因运行中 defer，尝试 --install
      if bash "$PATCH_BASE/patch.sh" --install; then
        PATCH_OK=1
        PATCH_VER_MSG="（$SRC_VER）"
        log "ChatGPT-Patched.app 已生成（fallback --install）"
      else
        log "WARN: patch.sh 执行失败，详见 $PATCH_BASE/patch.log"
      fi
    fi
  else
    log "副本已是最新（$SRC_VER），跳过重建"
    PATCH_OK=1
    PATCH_VER_MSG="（$SRC_VER 已是最新）"
  fi
else
  log "跳过副本 patch（--skip-patch）"
fi
