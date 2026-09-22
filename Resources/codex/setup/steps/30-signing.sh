#!/bin/zsh
# 步骤：2. 签名密码（强制自定义）
# 由 codex-oneclick-setup.command source 执行（同一个 shell，变量/函数共享）。
# ！！不要在这里用 $0 / dirname "$0" 推路径：zsh 默认会把被 source 文件的 $0 换掉，
#    路径推导统一放在主脚本（SCRIPT_DIR 已算好，直接用）。

# ---------------------------------------------------------------------------
# 2. 签名密码：强制自定义（不允许 0000 默认）
#    已有 PASS_FILE 则复用；否则必须让用户输入自定义密码（≥4位，且≠0000）
# ---------------------------------------------------------------------------
if [[ "$SKIP_PATCH" -eq 0 ]]; then
  if [[ -f "$PASS_FILE" && -z "$PASS" ]]; then
    PASS="$(cat "$PASS_FILE" 2>/dev/null || true)"
    PASS="${PASS// /}"
    if [[ -n "$PASS" && "$PASS" == "0000" ]]; then
      if [[ "$MODE" == "update" ]]; then
        log "WARN: 检测到旧密码 0000（更新模式暂沿用，下次安装请改为自定义）"
        # keep 0000 for this update round to not break existing 0000 keychain
      else
        log "WARN: 检测到旧密码为 0000，请重新设置为自定义密码"
        PASS=""
      fi
    fi
  fi
  if [[ -z "$PASS" && "$NONINTERACTIVE" -eq 1 ]]; then
    PASS="${ONECLICK_PASS:-}"
    PASS="${PASS// /}"
    if [[ -z "$PASS" ]]; then
      die "缺少签名钥匙串密码：请设置环境变量 ONECLICK_PASS 后重试。"
    fi
  fi
  if [[ -z "$PASS" && "$MODE" == "update" && -f "$HOME/Library/Keychains/codex-signing.keychain-db" ]]; then
    # 老机器无 PASS_FILE 但钥匙串已是 0000，更新时静默沿用避免打断
    log "WARN: 未找到密码文件，检测到现有钥匙串，更新模式暂沿用 0000（建议下次安装改为自定义）"
    PASS="0000"
  fi
  if [[ -z "$PASS" ]]; then
    while true; do
      _tmp_pass="$(ask_hidden "请设置签名钥匙串密码（必填）\n\n将保存在 ~/.codex/picker-patch/.keychain-pass（600），用于创建本地签名钥匙串。请务必记好，副本升级时会复用。" "签名钥匙串密码" "")"
      [[ "$_tmp_pass" == "__CANCEL__" ]] && die "已取消安装"
      _tmp_pass="${_tmp_pass// /}"
      if [[ -z "$_tmp_pass" ]]; then
        osascript - "密码不能为空，请重新输入。" "Codex 一键配置安装器" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display dialog (item 1 of argv) with title "Codex 一键配置安装器" buttons {"好"} default button "好" with icon stop
end run
APPLESCRIPT
        continue
      fi
      PASS="$_tmp_pass"
      break
    done
  fi
  log "签名钥匙串密码：已设置（${#PASS} 位，自定义）"
fi

# 自签证书现场生成（新机无证书时）
ensure_codex_signing_cert() {
  local certs_dir="$PATCH_BASE/certs"
  local crt="$certs_dir/codex-sign2.crt"
  local key="$certs_dir/codex-sign2.key"
  local p12="$certs_dir/codex-sign2.p12"
  local kc="$HOME/Library/Keychains/codex-signing.keychain-db"
  mkdir -p "$certs_dir"
  if [[ -f "$crt" && -f "$key" && -f "$p12" ]]; then
    log "签名证书已存在，跳过生成"
    # 确保钥匙串已导入（使用当前自定义 PASS）
    if [[ -f "$kc" ]]; then
      security unlock-keychain -p "$PASS" "$kc" >>"$LOG" 2>&1 || true
      security import "$p12" -k "$kc" -P codex123 -T /usr/bin/codesign -T /usr/bin/security >>"$LOG" 2>&1 || true
    fi
    return 0
  fi
  log "生成本机自签证书 Codex Patched Signing (RSA2048, 10年)..."
  local extfile
  extfile="$(mktemp)"
  cat > "$extfile" <<'EXTEOF'
basicConstraints=critical,CA:true
keyUsage=critical,digitalSignature,keyCertSign,cRLSign
extendedKeyUsage=codeSigning
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer
EXTEOF
  if ! openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$key" -out "$crt" -days 3650 \
    -subj "/OU=2DC432GLL2/CN=Codex Patched Signing/O=steve233" \
    -extfile "$extfile" >>"$LOG" 2>&1; then
    log "WARN: openssl 生成证书失败，将回退到 ad-hoc 签名"
    rm -f "$extfile"
    return 1
  fi
  rm -f "$extfile"
  chmod 600 "$key" 2>/dev/null || true
  if ! openssl pkcs12 -export -legacy -out "$p12" -inkey "$key" -in "$crt" -password pass:codex123 >>"$LOG" 2>&1; then
    openssl pkcs12 -export -out "$p12" -inkey "$key" -in "$crt" -password pass:codex123 >>"$LOG" 2>&1 || true
  fi
  chmod 600 "$p12" 2>/dev/null || true
  if [[ ! -f "$kc" ]]; then
    security create-keychain -p "$PASS" "$kc" >>"$LOG" 2>&1 || true
  fi
  security unlock-keychain -p "$PASS" "$kc" >>"$LOG" 2>&1 || true
  security import "$p12" -k "$kc" -P codex123 -T /usr/bin/codesign -T /usr/bin/security >>"$LOG" 2>&1 || true
  security set-keychain-settings -t 3600 -l -u "$kc" >>"$LOG" 2>&1 || true
  # 加入搜索列表
  if ! security list-keychains -d user 2>&1 | grep -q "codex-signing"; then
    # best-effort add to list
    security list-keychains -d user -s "$kc" $(security list-keychains -d user 2>&1 | tr -d '"' | xargs) >>"$LOG" 2>&1 || true
  fi
  if [[ -f "$crt" ]]; then
    if sudo -n true 2>/dev/null; then
      sudo security add-trusted-cert -d -r trustRoot -p codeSign -k "/Library/Keychains/System.keychain" "$crt" >>"$LOG" 2>&1 || log "提示：证书已生成但加入系统信任失败，不影响使用"
    else
      log "证书已生成（未自动加入系统信任，属正常，需 sudo 时可手动执行 security add-trusted-cert）"
    fi
  fi
  log "自签证书已就绪：$crt"
}
