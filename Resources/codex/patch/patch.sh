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

  # Rebuild the patched copy from the current (possibly updated) source.
  rm -rf "$PATCHED"
  mkdir -p "$(dirname "$PATCHED")"
  cp -R "$SOURCE" "$PATCHED"
  log "copied source -> $PATCHED"

  local asar="$PATCHED/Contents/Resources/app.asar"
  local plist="$PATCHED/Contents/Info.plist"

  # Unique-occurrence check: abort if the pattern moved (upstream rebuild).
  local matches off snippet within
  matches=$(grep -aboE "$PATTERN_REGEX" "$asar" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$matches" -ne 1 ]; then
    log "ERROR: pattern occurrences=$matches (expected 1) for regex $PATTERN_REGEX, refusing to patch. App may have a code change."
    rm -rf "$PATCHED"
    exit 1
  fi
  off=$(grep -aboE "$PATTERN_REGEX" "$asar" 2>/dev/null | head -1 | cut -d: -f1)
  snippet=$(grep -aoE "$PATTERN_REGEX" "$asar" 2>/dev/null | head -1)
  within=$(printf '%s' "$snippet" | grep -aboF "$PATCH_FROM" | head -1 | cut -d: -f1)
  if [ -z "$within" ]; then
    log "ERROR: cannot locate $PATCH_FROM within matched pattern, refusing"
    rm -rf "$PATCHED"
    exit 1
  fi
  off=$((off + within))
  printf '%s' "$PATCH_TO" | dd of="$asar" bs=1 seek="$off" count="${#PATCH_TO}" conv=notrunc 2>/dev/null

  if ! is_patched; then
    log "ERROR: patch byte verification failed, removing broken copy"
    rm -rf "$PATCHED"
    exit 1
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
    rm -rf "$PATCHED"
    exit 1
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
import struct, json, hashlib, re, plistlib
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
assert len(buf) == len(raw), 'file size changed!'
with open(asar, 'wb') as f:
    f.write(bytes(buf))
print('asar rewritten, size unchanged: %d' % len(buf))
PYEOF
  then
    log "ERROR: asar integrity refresh failed, removing broken copy"
    rm -rf "$PATCHED"
    exit 1
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
  local bindir="$PATCHED/Contents/MacOS"
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
    int n = argc + 1;
    char **newargv = malloc(sizeof(char*) * (n + 1));
    newargv[0] = bin;
    newargv[1] = ud;
    for (int i = 1; i < argc; i++) newargv[i + 1] = argv[i];
    newargv[n] = NULL;
    execv(bin, newargv);
    perror("execv");
    return 1;
}
EOF
  clang -O2 -o "$bindir/ChatGPT" "$BASE/scripts/launcher.c" >> "$LOG" 2>&1
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
  if codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN" --entitlements "$BASE/certs/ent2.plist" "$PATCHED" >> "$LOG" 2>&1; then
    log "re-signed"
  else
    log "ERROR: cert signing failed (is the keychain unlocked?), falling back to ad-hoc"
    codesign --force --deep --sign - "$PATCHED" >> "$LOG" 2>&1
    log "re-signed (ad-hoc fallback)"
  fi

  printf '{"sourceVersion":"%s","builtAt":"%s"}\n' "$version" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
  log "marker written: $version"
}

install() {
  if ! is_patched; then
    build_patched
  else
    log "already patched (version $(get_marker_version)), skip"
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