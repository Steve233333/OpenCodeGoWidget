#!/bin/bash
set -euo pipefail

SOURCE="/Applications/ChatGPT.app"
PATCHED="$HOME/Applications/ChatGPT-Patched.app"
BASE="$HOME/.codex/picker-patch"
MARKER="$BASE/patch-state.json"
LOG="$BASE/patch.log"
AGENT_LABEL="com.steve233.codex-picker-patch"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
CODEX_HOME_DIR="$HOME/.codex-deepseek"

# Self-signed code signing identity (Plan B): stable TCC authorization across
# rebuilds. Keychain lives at ~/Library/Keychains/codex-signing.keychain-db.
SIGN_IDENTITY="Codex Patched Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/codex-signing.keychain-db"
SIGN_KEYCHAIN_PASS="$(cat "$HOME/.codex/picker-patch/.keychain-pass" 2>/dev/null | tr -d " \n\r" || true)"; [[ -z "$SIGN_KEYCHAIN_PASS" ]] && SIGN_KEYCHAIN_PASS="0000"  # fallback 兼容旧机，回退后 TCC 会提示重授

# 26.810+: model visibility filter was rewritten. Old pattern was
# 'i&&t!==`amazonBedrock`' (26.803-); new code is
# n.filter(e=>i.useHiddenModels&&r!==`amazonBedrock`?i.availableModels.has(e.model):!e.hidden)
# 26.825: variables renamed to a.useHiddenModels&&i!==`amazonBedrock`
# Patch flips `!==` -> `===` so the non-Bedrock filter path is skipped and
# custom (DeepSeek) models are never filtered out by availableModels.
# Keep both candidates for compatibility; auto-detect which exists.
PATTERNS=('a.useHiddenModels&&i!==`amazonBedrock`' 'i.useHiddenModels&&r!==`amazonBedrock`')
PATTERN_REGEX='useHiddenModels&&[^`]*!==`amazonBedrock`'
PATTERN="$PATTERN_REGEX"
PATCH_FROM='!=='
PATCH_TO='==='
SILENT=0

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  mkdir -p "$BASE"
  echo "$msg" >> "$LOG"
  if [ "$SILENT" -ne 1 ]; then echo "$msg"; fi
}

resolve_source() {
  if [ -d "$SOURCE" ] && [ -f "$SOURCE/Contents/Info.plist" ]; then
    echo "$SOURCE"
  elif [ -d "$HOME/Applications/ChatGPT.app" ] && [ -f "$HOME/Applications/ChatGPT.app/Contents/Info.plist" ]; then
    echo "$HOME/Applications/ChatGPT.app"
  else
    echo "$SOURCE"
  fi
}

app_version() {
  local src
  src=$(resolve_source)
  local plist="$src/Contents/Info.plist"
  if [ ! -f "$plist" ]; then echo "unknown"; return; fi
  # PlistBuddy prints "File Doesn't Exist, Will Create..." to stdout on missing file,
  # so pre-check existence and silence both stdout/stderr on error paths
  local v
  v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null) || v="unknown"
  # filter out PlistBuddy's creation message if it leaked
  if [[ "$v" == *"Will Create"* ]] || [[ "$v" == *"Does Not Exist"* ]]; then echo "unknown"; else echo "$v"; fi
}

patched_running() {
  pgrep -f "$PATCHED/Contents/MacOS" >/dev/null 2>&1
}

get_marker_version() {
  if [ -f "$MARKER" ]; then
    sed -nE 's/.*"sourceVersion": *"([^"]*)".*/\1/p' "$MARKER" 2>/dev/null | head -1 || true
  fi
}

is_patched() {
  local asar="$PATCHED/Contents/Resources/app.asar"
  [ -f "$asar" ] || return 1
  grep -aqE 'useHiddenModels&&[^`]*===`amazonBedrock`' "$asar" 2>/dev/null
}

# 官方改布局会让 ~/.local/bin/codex 变成**悬空软链**（26.930 把 CLI 从
# Contents/Resources/codex 挪到 Contents/Resources/codex-cli/bin/codex）—— 手机端
# ccpocket 桥的 PATH 第一项就是这个软链，悬空就起不来会话。只在软链已存在时维护它，
# 绝不主动创建（别人的机器上可能故意没有这个软链）。
ensure_cli_symlink() {
  local link="$HOME/.local/bin/codex" target="" cand
  [ -L "$link" ] || return 0
  for cand in "$PATCHED/Contents/Resources/codex-cli/bin/codex" \
              "$PATCHED/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex" \
              "$PATCHED/Contents/Resources/codex"; do
    [ -s "$cand" ] && { target="$cand"; break; }
  done
  if [ -z "$target" ]; then
    log "WARN: 找不到 CLI 入口，跳过 codex 软链维护"
    return 0
  fi
  if [ "$(readlink "$link")" = "$target" ]; then
    log "codex CLI 软链无需变更 ($target)"
  elif ln -sfn "$target" "$link"; then
    log "codex CLI 软链已重指 → $target"
  else
    log "WARN: codex 软链重指失败 ($link)"
  fi
}

build_patched() {
  log "== build patched copy =="
  # Resolve actual source location (handles /Applications vs ~/Applications installs)
  local actual_source
  actual_source=$(resolve_source)
  if [ "$actual_source" != "$SOURCE" ]; then
    log "source resolved to $actual_source (canonical $SOURCE missing)"
    SOURCE="$actual_source"
  fi
  local version
  version=$(app_version)
  log "source version: $version"

  if [ "$version" = "unknown" ] || [ ! -d "$SOURCE" ]; then
    log "ERROR: cannot read source app"
    exit 1
  fi

  if patched_running; then
    log "ERROR: patched copy is running, cannot rebuild"
    exit 1
  fi

  # Safety: never touch CODEX_HOME. Only the patched app bundle is rebuilt.
  case "$PATCHED" in
    "$CODEX_HOME_DIR"|"$CODEX_HOME_DIR"/*|"$(dirname "$PATCHED")")
      log "FATAL: PATCHED path collides with CODEX_HOME, refusing"
      exit 1 ;;
  esac

  # 2026-10-22：**原子重建**（替换 2026-09-04 的"先备份、再原地重建"）。
  # 旧流程的问题：先把正式路径上的旧副本 mv 成备份，再把官方版 cp 到正式路径原地改。
  # 那一两分钟里，正式路径上是个半成品（asar 已改、签名没重做、启动器没编好）：
  #   * 用户这时双击 ChatGPT-Patched，macOS 直接报"已损坏，无法打开"；
  #   * 任务中途被取消/关机，半成品还会留在正式路径上，之后也开不了。
  # 现在改成：先在暂存目录里建好、验签通过，再原子换入 ——
  # 正式路径上永远是"旧的好的"或"新的好的"，没有半成品窗口。
  local PATCH_BAK="" STAGING=""
  STAGING="$(dirname "$PATCHED")/ChatGPT-Patched.new.$(date '+%Y%m%d-%H%M%S')"
  # 上次任务被 kill 时可能留下暂存目录，先清干净（只清 .new.*，绝不碰正式路径）
  rm -rf "$(dirname "$PATCHED")"/ChatGPT-Patched.new.* 2>/dev/null || true
  mkdir -p "$(dirname "$PATCHED")"

  discard_staging() {
    # $1 = 步骤名。失败只丢暂存目录；正式路径上的旧副本原封不动，不需要"恢复"。
    local step="$1"
    if [ -n "$STAGING" ] && [ -d "$STAGING" ]; then
      rm -rf "$STAGING"
      log "ABORTED:$step (暂存目录已清理，正式路径上的旧副本未受影响)"
    else
      log "ABORTED:$step (正式路径上的旧副本未受影响)"
    fi
    exit 1
  }
  cleanup_backup() {
    if [ -n "$PATCH_BAK" ] && [ -d "$PATCH_BAK" ]; then
      rm -rf "$PATCH_BAK"
      log "backup removed ($PATCH_BAK)"
    fi
  }

  cp -R "$SOURCE" "$STAGING"
  log "copied source -> $STAGING"

  local asar="$STAGING/Contents/Resources/app.asar"
  local plist="$STAGING/Contents/Info.plist"

  # Unique-occurrence check: abort if the pattern moved (upstream rebuild).
  local matches off snippet within
  matches=$(grep -aboE "$PATTERN_REGEX" "$asar" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$matches" -ne 1 ]; then
    log "ERROR: pattern occurrences=$matches (expected 1) for regex $PATTERN_REGEX, refusing to patch. App may have a code change."
    discard_staging "pattern-count"
  fi
  off=$(grep -aboE "$PATTERN_REGEX" "$asar" 2>/dev/null | head -1 | cut -d: -f1)
  snippet=$(grep -aoE "$PATTERN_REGEX" "$asar" 2>/dev/null | head -1)
  within=$(printf '%s' "$snippet" | grep -aboF "$PATCH_FROM" | head -1 | cut -d: -f1)
  if [ -z "$within" ]; then
    log "ERROR: cannot locate $PATCH_FROM within matched pattern, refusing"
    discard_staging "pattern-locate"
  fi
  off=$((off + within))
  printf '%s' "$PATCH_TO" | dd of="$asar" bs=1 seek="$off" count="${#PATCH_TO}" conv=notrunc 2>/dev/null

  # 2026-10-22：必须校验**暂存目录里这份** asar。is_patched() 读的是正式路径，
  # 原子重建后正式路径上还是旧包（甚至还没建），拿它校验会永远失败。
  if ! grep -aqE 'useHiddenModels&&[^`]*===`amazonBedrock`' "$asar" 2>/dev/null; then
    log "ERROR: patch byte verification failed, discarding staged copy"
    discard_staging "byte-verify"
  fi
  log "pattern '$PATTERN' patched ($PATCH_FROM -> $PATCH_TO) at offset $off"

  # Disable Sparkle updates in the patched copy: replace the feed URL with a
  # same-length RFC-2606 reserved host (always fails DNS) so the in-app
  # "Check for Updates" action can never download a fresh official bundle.
  local feed_old='https://persistent.oaistatic.com/codex-app-prod/appcast.xml'
  local feed_new='https://invalid.invalid.invalid/codex-app-prod/appcast.xml'
  local feed_matches
  feed_matches=$(grep -aboF "$feed_old" "$asar" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$feed_matches" -eq 1 ]; then
    local feed_off
    feed_off=$(grep -aboF "$feed_old" "$asar" 2>/dev/null | head -1 | cut -d: -f1)
    printf '%s' "$feed_new" | dd of="$asar" bs=1 seek="$feed_off" count=${#feed_old} conv=notrunc 2>/dev/null
    log "sparkle feed URL disabled (offset $feed_off)"
  elif [ "$feed_matches" -eq 0 ]; then
    log "WARN: sparkle feed URL not found (code change?), skipping"
  else
    log "ERROR: sparkle feed URL occurrences=$feed_matches (expected 1), refusing"
    discard_staging "feed-multi"
  fi

  # 26.901+: Electron validates per-file asar integrity on every read, using the
  # "integrity" objects in the asar header (mismatch => instant silent exit(1),
  # no window -- a rebuilt copy "won't open"). Same-length byte edits keep all
  # offsets valid, so: (1) picker single-line fix with space padding (no asar
  # repack, no npx needed), (2) recompute every per-file integrity hash in
  # place (same length -- the C++ layer FATALs on missing entries, so they
  # cannot be removed), (3) sha256(new header JSON) back into Info.plist
  # ElectronAsarIntegrity (the archive-level gate is fail-closed).
  # python 用 -u 关闭块缓冲，心跳日志才能实时写入文件
  if ! python3 -u - "$asar" "$plist" >>"$LOG" 2>&1 <<'PYEOF'
import struct, json, hashlib, re, plistlib, glob, os
asar, plist = __import__('sys').argv[1], __import__('sys').argv[2]
with open(asar, 'rb') as f:
    raw = f.read()
payload_size, header_size, str_size = struct.unpack('<III', raw[:12])
blob = raw[16:16 + str_size]
text = blob.decode('utf-8')
header, end = json.JSONDecoder().raw_decode(text)
assert 'files' in header, 'asar header parse failed'
hstart, hend = 16, 16 + end
buf = bytearray(raw)
assert len(buf) == len(raw)

def swap(old, new, expect=(1,), name='?'):
    global buf
    n = buf.count(old)
    assert n in expect, '%s: found %d, expected %s' % (name, n, expect)
    if n:
        assert len(old) == len(new), '%s: length %d vs %d' % (name, len(old), len(new))
        buf = buf.replace(old, new)
    print('%s: %d occurrence(s) patched' % (name, n))

# 1. picker: force single-line truncate (space-padded, same length)
P1_OLD = b'g=u?`whitespace-normal`:`truncate`'
swap(P1_OLD, b'g=`truncate`' + b' ' * (len(P1_OLD) - len(b'g=`truncate`')), expect=(0, 1), name='picker cmi')
P2_OLD = b'J(`min-w-0`,P?`whitespace-normal`:`truncate`)'
P2_NEW = b'J(`min-w-0`,P?`truncate`:`truncate`)'
swap(P2_OLD, P2_NEW + b' ' * (len(P2_OLD) - len(P2_NEW)), expect=(0, 1), name='picker lz-1')
P3_OLD = b'J(`min-w-0 text-xs leading-dense text-tertiary`,F?`whitespace-normal`:`truncate`)'
P3_NEW = b'J(`min-w-0 text-xs leading-dense text-tertiary`,F?`truncate`:`truncate`)'
swap(P3_OLD, P3_NEW + b' ' * (len(P3_OLD) - len(P3_NEW)), expect=(0, 1), name='picker lz-2')

# 2. recompute per-file integrity for every archived file.
#    Electron's C++ layer FATALs when a file node lacks integrity, so entries
#    cannot be removed -- but same-size content edits keep block layout stable,
#    letting us refresh every hash in place (header length unchanged).
def walk(node, prefix=''):
    out = []
    for name, entry in node.get('files', {}).items():
        p = (prefix + '/' + name) if prefix else name
        if 'files' in entry:
            out += walk(entry, p)
        else:
            out.append((p, entry))
    return out

base = 8 + header_size
hdr = bytes(buf[hstart:hend])
nfiles = 0
for p, e in walk(header):
    integ = e.get('integrity')
    if not integ or 'offset' not in e:
        continue
    assert integ.get('algorithm') == 'SHA256', 'unexpected algorithm %s' % p
    off = base + int(e['offset'])
    size = int(e['size'])
    content = bytes(buf[off:off + size])
    assert len(content) == size, 'short read %s' % p
    bs = int(integ['blockSize'])
    idx = list(range(0, size, bs)) or [0]
    blocks = [hashlib.sha256(content[i:i + bs]).hexdigest() for i in idx]
    whole = hashlib.sha256(content).hexdigest()
    old_unit = '"hash":"%s","blockSize":%d,"blocks":[%s]' % (
        integ['hash'], bs, ','.join('"%s"' % b for b in integ['blocks']))
    new_unit = '"hash":"%s","blockSize":%d,"blocks":[%s]' % (
        whole, bs, ','.join('"%s"' % b for b in blocks))
    assert len(old_unit) == len(new_unit), 'unit length %s' % p
    ob, nb = old_unit.encode(), new_unit.encode()
    assert hdr.count(ob) >= 1, 'unit missing %s' % p
    hdr = hdr.replace(ob, nb)
    nfiles += 1
    if nfiles % 1000 == 0:
        print('... integrity recomputed %d files' % nfiles, flush=True)
print('per-file integrity recomputed: %d files' % nfiles)
json.loads(hdr.decode('utf-8'))  # still valid JSON
buf[hstart:hend] = hdr

# 3. refresh archive-level header hash in Info.plist
new_hash = hashlib.sha256(bytes(buf[hstart:hend])).hexdigest()
with open(plist, 'rb') as f:
    pl = plistlib.load(f)
pl['ElectronAsarIntegrity']['Resources/app.asar']['hash'] = new_hash
with open(plist, 'wb') as f:
    plistlib.dump(pl, f)
print('header sha256 -> plist: %s...' % new_hash[:16])

# 4. cross-check digest embedded in the framework binary (app 26.930+,
#    Electron >=154): __DATA_CONST,__asar_integrity = 32B sentinel + used +
#    version + sha256 over sorted key+algorithm+hash triples of the plist
#    dict. If the plist hash changed but this digest did not,
#    IsIntegrityDictionaryValid() fails => "Failed to get integrity" FATAL
#    (app shows as damaged / crashes on launch).
root = os.path.dirname(os.path.dirname(plist))
hasher = hashlib.sha256()
for k in sorted(pl['ElectronAsarIntegrity'].keys()):
    ent = pl['ElectronAsarIntegrity'][k]
    hasher.update(k.encode()); hasher.update(ent['algorithm'].encode()); hasher.update(ent['hash'].encode())
digest = hasher.digest()
sentinel = b'AGbevlPCksUGKNL8TSn7wGmJEuJsXb2A'
slots = 0
for fw in glob.glob(root + '/Contents/Frameworks/*.framework/Versions/Current/*'):
    if not os.path.isfile(fw):
        continue
    with open(fw, 'rb') as f:
        data = bytearray(f.read())
    pos = data.find(sentinel)
    if pos < 0 or pos + 66 > len(data):
        continue
    if data[pos + 32] == 1 and data[pos + 33] == 1:  # used=1, version=1
        data[pos + 34:pos + 66] = digest
        with open(fw, 'wb') as f:
            f.write(bytes(data))
        slots += 1
        print('framework integrity digest refreshed: %s @0x%x' % (os.path.basename(fw), pos))
if not slots:
    print('framework integrity digest slot not found (older build) - skipped')
assert len(buf) == len(raw), 'file size changed!'
with open(asar, 'wb') as f:
    f.write(bytes(buf))
print('asar rewritten, size unchanged: %d' % len(buf))
PYEOF
  then
    log "ERROR: asar integrity refresh failed, removing broken copy"
    discard_staging "integrity"
  fi
  log "asar integrity refreshed (picker single-line + per-file recompute + header hash)"

  # Inject CODEX_HOME so the patched copy uses the isolated data directory.
  if ! /usr/libexec/PlistBuddy -c "Print :LSEnvironment" "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$plist"
  fi
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:CODEX_HOME '$CODEX_HOME_DIR'" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:CODEX_HOME string '$CODEX_HOME_DIR'" "$plist"
  log "LSEnvironment CODEX_HOME -> $CODEX_HOME_DIR"

  # Unique bundle id so the official app and the patched copy can run side by side.
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.steve233.codex-patched" "$plist"
  log "CFBundleIdentifier -> com.steve233.codex-patched"

  # Disable Sparkle's automatic update checks for the patched copy.
  /usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool false" "$plist"
  log "SUEnableAutomaticChecks -> false"

  # Separate Chromium userData: wrap the main executable in a tiny Mach-O
  # launcher that injects --user-data-dir=~/Library/Application Support/Codex-Patched.
  # (launchd refuses shell scripts as the main executable; CHROME_USER_DATA_DIR
  # is ignored by Electron, and a space-separated --user-data-dir arg is not
  # forwarded to child processes — use the '=' form.)
  local bindir="$STAGING/Contents/MacOS"
  mv "$bindir/ChatGPT" "$bindir/ChatGPT.bin"
  local uddir="$HOME/Library/Application Support/Codex-Patched"
  cat > "$BASE/scripts/launcher.c" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

int main(int argc, char **argv) {
    char *home = getenv("HOME");
    if (!home) home = "";
    char ud[1100];
    char bin[1100];
    snprintf(ud, sizeof(ud), "--user-data-dir=%s/Library/Application Support/Codex-Patched", home);
    snprintf(bin, sizeof(bin), "%s/Applications/ChatGPT-Patched.app/Contents/MacOS/ChatGPT.bin", home);
    int n = argc + 3;
    char **newargv = malloc(sizeof(char*) * (n + 1));
    newargv[0] = bin;
    newargv[1] = ud;
    /* 2026-10-07：离线启动别退回英文 —— 语言是联网时从账号取的，这里把 zh-CN 钉死在启动参数里 */
    newargv[2] = "--lang=zh-CN";
    newargv[3] = "--accept-lang=zh-CN,zh;q=0.9";
    for (int i = 1; i < argc; i++) newargv[i + 3] = argv[i];
    newargv[n] = NULL;
    execv(bin, newargv);
    perror("execv");
    return 1;
}
EOF
  # 2026-09-19：没装 Xcode 命令行工具（没有 clang）的机器，用随 App 附带的预编译启动器
  # （resources/patch/launcher-universal，arm64+x86_64 通用二进制，源码见 launcher.c）。
  # 这样新电脑不需要命令行工具也能打出双开副本。
  # 同样不能只看 `command -v clang`：没装命令行工具时 /usr/bin/clang 是占位程序
  # 2026-10-03：clang 存在 ≠ 能链接成功（CommandLineTools SDK 损坏时 ld 报
  # unknown architecture 且不产出文件）。必须检查编译产物，失败就回退预编译
  # 启动器，否则主可执行文件缺失 → 系统报"应用程序可能已损坏或不完整"。
  launcher_ok=""
  if command -v clang >/dev/null 2>&1 && clang --version >/dev/null 2>&1; then
    local xc_sdk=""
    xc_sdk="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    [ -d "$xc_sdk" ] || xc_sdk=""
    if clang -O2 ${xc_sdk:+-isysroot "$xc_sdk"} -o "$bindir/ChatGPT" "$BASE/scripts/launcher.c" >> "$LOG" 2>&1 && [ -s "$bindir/ChatGPT" ]; then
      launcher_ok=1
      log "launcher compiled with clang"
    else
      rm -f "$bindir/ChatGPT"
      log "WARN: clang 编译启动器失败（SDK/链接问题），回退预编译启动器"
    fi
  fi
  if [ -z "$launcher_ok" ] && [ -f "$BASE/launcher-universal" ]; then
    cp "$BASE/launcher-universal" "$bindir/ChatGPT"
    chmod +x "$bindir/ChatGPT"
    launcher_ok=1
    log "使用随包附带的预编译启动器（launcher-universal）"
  fi
  if [ -z "$launcher_ok" ]; then
    # 最后兜底：把原二进制放回去，副本仍可运行，只是和官方版共用配置目录
    cp "$bindir/ChatGPT.bin" "$bindir/ChatGPT"
    chmod +x "$bindir/ChatGPT"
    log "WARN: 既没有 clang 也没有预编译启动器，副本将直接运行（未注入独立 --user-data-dir）"
  fi
  # 2026-10-03：`-x` 会放行"存在但 0 字节"的空壳（clang 链接失败就可能留下这种文件），
  # 空壳主可执行文件 = 系统报"应用程序可能已损坏或不完整"。必须按非空校验。
  [ -s "$bindir/ChatGPT" ] || { log "ERROR: launcher 缺失或为空，中止重建"; exit 1; }
  log "main executable wrapped with user-data-dir launcher ($uddir)"

  # The asar header hash in Info.plist was refreshed above (it covers the header
  # JSON, which changed when per-file integrity entries were blanked). The
  # signature still needs refreshing because bundle content changed.
  # Plan B: sign with a self-signed cert (stable TCC identity across rebuilds)
  # instead of ad-hoc (adhoc binds TCC grants to the CDHash, which breaks on
  # every rebuild -> screen recording/accessibility permissions are lost).
  security unlock-keychain -p "$SIGN_KEYCHAIN_PASS" "$SIGN_KEYCHAIN" >> "$LOG" 2>&1 || true
  log "re-signing with cert ($SIGN_IDENTITY)..."
  # Use the stable entitlements file (application-groups + automation etc.)
  # so CUAService bootstrap and appshot work after every rebuild.
  if codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" --entitlements "$BASE/certs/ent2.plist" "$STAGING" >> "$LOG" 2>&1; then
    log "re-signed"
  else
    log "ERROR: cert signing failed (is the keychain unlocked?), falling back to ad-hoc"
    codesign --force --deep --sign - "$STAGING" >> "$LOG" 2>&1
    log "re-signed (ad-hoc fallback)"
  fi

  # 轻量启动确认：验签通过才删备份（B1/B2），失败走同一回滚
  if ! codesign --verify --deep --strict "$STAGING" >> "$LOG" 2>&1; then
    log "ERROR: codesign verify failed on new copy"
    discard_staging "verify"
  fi
  log "codesign verify passed"

  # 换入（原子）：验签通过的新包先占位，再把旧的挪到备份 —— 正式路径上不会出现半成品。
  # 换入前再确认旧副本没在运行（运行中 mv 会把正在跑的程序弄坏）。
  if patched_running; then
    log "ERROR: 副本正在运行，无法换入，放弃本次重建（旧副本仍是好的）"
    discard_staging "swap-running"
  fi
  if [ -d "$PATCHED" ]; then
    # 备份命名：marker 旧 sourceVersion > 旧包 Info.plist 版本 > 时间戳兜底，保证 mv 永不撞名
    local bak_ver bak_base
    bak_ver=$(get_marker_version)
    if [ -z "$bak_ver" ]; then
      bak_ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PATCHED/Contents/Info.plist" 2>/dev/null || true)
      if [[ "$bak_ver" == *"Will Create"* ]] || [[ "$bak_ver" == *"Does Not Exist"* ]]; then bak_ver=""; fi
    fi
    if [ -z "$bak_ver" ]; then
      bak_ver="ts$(date '+%Y%m%d-%H%M%S')"
    fi
    bak_base="$(dirname "$PATCHED")/ChatGPT-Patched.bak.$bak_ver"
    PATCH_BAK="$bak_base"
    rm -rf "$PATCH_BAK"
    mv "$PATCHED" "$PATCH_BAK"
    log "backed up existing patched copy -> $PATCH_BAK"
  fi
  mv "$STAGING" "$PATCHED"
  STAGING=""
  log "swapped staged build into place -> $PATCHED"
  cleanup_backup

  printf '{"sourceVersion":"%s","builtAt":"%s"}\n' "$version" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
  log "marker written: $version"
  # 2026-10-07：离线启动别退回英文 —— 种一份 Chromium locale（账号语言只在联网时可取）
  python3 - "$HOME" << 'PYEOF' || true
import json, os, sys
p = os.path.join(sys.argv[1], "Library/Application Support/Codex-Patched/Local State")
try:
    d = json.load(open(p)) if os.path.exists(p) else {}
except Exception:
    d = {}
d.setdefault("intl", {}).update({"app_locale": "zh-CN", "accept_languages": "zh-CN,zh,en-US,en"})
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2)
PYEOF

  # 每次重建顺手维护 CLI 软链：官方再改布局，手机端 ccpocket 桥也不会断
  ensure_cli_symlink
}

install() {
  # 2026-10-20：**版本感知**。以前这里只查 is_patched()（"asar 里有没有补丁特征"），
  # 完全不看官方版本。于是官方升级后如果 --auto-update 因"副本正在运行"被 defer，
  # 安装器回退到 --install 就会走进这个分支：日志写 "already patched, skip"、
  # 然后 open 旧副本 —— **假成功**，副本还停在旧版本，用户以为配好了。
  # 现在只要 marker 版本 ≠ 官方版本，就必须重建（运行中则明确报错，绝不静默跳过）。
  local current marker_ver
  current=$(app_version)
  marker_ver=$(get_marker_version)
  if is_patched && [ -n "$current" ] && [ "$current" != "unknown" ] && [ "$current" = "$marker_ver" ]; then
    log "already patched at $current, skip"
  else
    if is_patched; then
      log "version mismatch (patched=$marker_ver, source=$current) → rebuilding"
    else
      log "not patched → building"
    fi
    if patched_running; then
      log "ERROR: patched copy is running, cannot rebuild (quit it and retry)"
      exit 1
    fi
    build_patched || exit 1
  fi
  log "launching patched copy..."
  open "$PATCHED"
  log "launched $PATCHED"
}

auto_update() {
  SILENT=1
  local current marker_ver
  current=$(app_version)
  marker_ver=$(get_marker_version)

  if [ -z "$current" ] || [ "$current" = "unknown" ]; then
    log "auto-update: cannot read source version, skip"
    exit 0
  fi
  if [ "$current" = "$marker_ver" ] && is_patched; then
    log "auto-update: up to date ($current), no action"
    exit 0
  fi
  if patched_running; then
    log "auto-update: update available ($current vs $marker_ver) but patched copy running, defer"
    exit 0
  fi
  log "auto-update: version changed ($marker_ver -> $current), rebuilding"
  if build_patched; then
    log "auto-update: rebuilt successfully at $current"
  else
    log "auto-update: rebuild FAILED, source app untouched"
    exit 1
  fi
}

uninstall() {
  log "== uninstall =="
  if patched_running; then
    log "patched copy running, killing..."
    pkill -f "$PATCHED/Contents/MacOS" 2>/dev/null || true
    sleep 1
  fi
  if [ -d "$PATCHED" ]; then
    rm -rf "$PATCHED"
    log "removed $PATCHED (official app in /Applications untouched)"
  fi
  # 不留 600MB 僵尸包
  rm -rf "$(dirname "$PATCHED")"/ChatGPT-Patched.bak.* 2>/dev/null || true
  log "removed stale backups (ChatGPT-Patched.bak.*)"
  rm -f "$MARKER"
  if [ -f "$AGENT_PLIST" ]; then
    launchctl unload "$AGENT_PLIST" 2>/dev/null || true
    rm -f "$AGENT_PLIST"
    log "launchd agent removed"
  fi
}

status() {
  local src src_ver patched_ver
  src=$(resolve_source)
  src_ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$src/Contents/Info.plist" 2>/dev/null || echo "unknown")
  if [[ "$src_ver" == *"Will Create"* ]] || [[ "$src_ver" == *"Does Not Exist"* ]]; then src_ver="unknown"; fi
  if [ -d "$PATCHED" ]; then
    patched_ver=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PATCHED/Contents/Info.plist" 2>/dev/null || echo "unknown")
    if [[ "$patched_ver" == *"Will Create"* ]]; then patched_ver="unknown"; fi
    echo "source:        $src ($src_ver)"
    echo "patched copy:  $PATCHED ($patched_ver) ($(is_patched && echo patched || echo unpatched))"
  else
    echo "source:        $src ($src_ver)"
    echo "patched copy:  not built"
  fi
  echo "marker:        $(get_marker_version)"
  echo "agent:         $([ -f "$AGENT_PLIST" ] && echo "plist installed" || echo "not installed")"
}

case "${1:-}" in
  --install)   install ;;
  --auto-update) auto_update ;;
  --uninstall) uninstall ;;
  --status)    status ;;
  *) echo "usage: $0 {--install|--auto-update|--uninstall|--status}"; exit 1 ;;
esac
