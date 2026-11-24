#!/bin/bash
# 说大白话：拦住"会打坏 Codex 副本"的 patch.sh 进包。
#
# 起因（2026-10-03，26.930）：官方升级后自动重建时 clang 因本机 CommandLineTools SDK 损坏链接失败，
# 旧脚本没检查产物就继续签名收尾 → 主可执行文件根本没生成，系统报"应用程序可能已损坏或不完整"；
# 补回 launcher 后又撞上 26.930 新增的框架摘要校验（`Failed to get integrity` FATAL）。
# 修好的脚本只在本机，仓库那份落后 86 行 —— 而安装器按内容覆盖，等于"下次重建小组件就复发"。
# 这个测试把四条护栏钉死，任何人把脚本改回去都会在这里红。
#
# 用法：scripts/test-patch-guards.sh   （build.sh --test 的门禁之一）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH_SH="$ROOT/Resources/codex/patch/patch.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAIL=0
ok()  { echo "  ✅ $1"; }
bad() { echo "  ❌ $1"; FAIL=1; }

echo "==> patch.sh 护栏自检（防「重建把副本搞坏」）"
[ -f "$PATCH_SH" ] || { echo "  ❌ 找不到 $PATCH_SH"; exit 1; }

# ---------------------------------------------------------------------------
# ① 语法
bash -n "$PATCH_SH" && ok "语法通过（bash -n）" || bad "语法错误"

# ---------------------------------------------------------------------------
# ② 四条静态护栏（缺任何一条都说明修好的脚本被回退了）
grep -qF '&& [ -s "$bindir/ChatGPT" ]; then' "$PATCH_SH" \
  && ok "clang 产物非空校验在（坑 1 的前半）" || bad "缺 clang 产物校验"
grep -qF 'cp "$BASE/launcher-universal" "$bindir/ChatGPT"' "$PATCH_SH" \
  && ok "预编译启动器回退在（坑 1 的后半）" || bad "缺 launcher-universal 回退"
grep -qF '[ -s "$bindir/ChatGPT" ] || { log "ERROR: launcher 缺失或为空，中止重建"; exit 1; }' "$PATCH_SH" \
  && ok "签名前硬校验在（-s，空壳也拦）" || bad "缺签名前硬校验（-x 会放行 0 字节空壳）"
grep -qF 'AGbevlPCksUGKNL8TSn7wGmJEuJsXb2A' "$PATCH_SH" \
  && grep -qF 'framework integrity digest refreshed' "$PATCH_SH" \
  && ok "框架摘要同步在（坑 2：__asar_integrity 哨兵 + plist 摘要）" || bad "缺框架摘要同步"
grep -qF '[ "$(readlink "$link")" = "$target" ]' "$PATCH_SH" \
  && ok "CLI 软链维护在（官方改布局不断 ccpocket）" || bad "缺 codex CLI 软链维护"

# 26.1103 浏览器 IPC：node_repl 必须是官方签名 node -> wrapper -> node_repl。
PATCH_SCRIPTS="$ROOT/Resources/codex/patch/scripts"
for _cua_file in cua-node-wrapper.cjs patch-cua-mcp.py test-cua-peer-chain.js; do
  [ -s "$PATCH_SCRIPTS/$_cua_file" ] \
    && ok "CUA 修复资源存在：$_cua_file" || bad "缺 CUA 修复资源：$_cua_file"
done
[ "$(grep -cF 'ensure_cua_wrapper' "$PATCH_SH" || true)" -ge 3 ] \
  && ok "patch/install 都会安装 CUA wrapper" || bad "CUA wrapper 没接入重建安装流程"
grep -qF 'CUA_PATCHED_MARKER='"'"'args:[t+"/w.cjs",h],command:f'"'"'' "$PATCH_SH" \
  && ok "CUA wrapper 写进 app.asar，而不是只改会被重建的缓存" || bad "CUA 修复仍只改运行时缓存"
grep -qF 'CUA_RE = re.compile(' "$PATCH_SH" \
  && grep -qF "b'codexHome:t' in cua_scope" "$PATCH_SH" \
  && grep -qF "source pattern not present (older build) - skipped" "$PATCH_SH" \
  && ok "app.asar CUA 源配置按结构匹配；新版补，旧版明确跳过" || bad "缺 app.asar CUA 结构匹配/旧版跳过"
if python3 - "$PATCH_SH" <<'PY'
import contextlib, io, re, sys

text = open(sys.argv[1], encoding='utf-8').read()
try:
    block = text[text.index('# 2. CUA'):text.index('# 3. Offline language')]
except ValueError:
    print('FAIL 找不到 CUA 补丁段标记')
    raise SystemExit(1)

SCOPE = (b'PO:function({codexCliPath:e,codexHome:t,envVars:n=[],extraEnv:l,'
         b'nodeModuleDirs:m="",nodePath:f,nodeReplPath:h,platform:g}){')
BODY = (b'return {[`mcp_servers.${s}`]:{args:[],command:h,env:w,...0===%s.length?'
        b'{}:{env_vars:Array.from(%s)},startup_timeout_sec:120}}')

def run(name, sample, expect_err=None, expect_patch=True):
    ns = {'re': re, 'buf': bytearray(sample)}
    err = None
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            exec(compile(block, '<cua-block>', 'exec'), ns)
    except Exception as exc:
        err = '%s: %s' % (type(exc).__name__, exc)
    if expect_err:
        if not err or expect_err not in err:
            print('FAIL %s: 期望报错含 %r，实际 %r' % (name, expect_err, err))
            return False
        print('ok   %s（已拒绝）' % name)
        return True
    if err:
        print('FAIL %s: %s' % (name, err))
        return False
    out = bytes(ns['buf'])
    if len(out) != len(sample):
        print('FAIL %s: 长度 %d -> %d' % (name, len(sample), len(out)))
        return False
    marker = b'args:[t+"/w.cjs",h],command:f'
    if expect_patch and marker not in out:
        print('FAIL %s: 没写入 wrapper 参数' % name)
        return False
    if not expect_patch and marker in out:
        print('FAIL %s: 旧版不应凭空写 wrapper 参数' % name)
        return False
    print('ok   %s%s' % (name, '' if expect_patch else '（已跳过）'))
    return True

cases = [
    ('26.1011 形态（_）', SCOPE + BODY % (b'_', b'_'), None),
    ('26.1117 形态（k）', SCOPE + BODY % (b'k', b'k'), None),
    ('旧版源码没有 CUA 配置', b'nothing to see here', None, False),
    ('作用域重命名',
     SCOPE.replace(b'codexHome:t', b'codexHome:q').replace(b'nodePath:f', b'nodePath:j')
     + BODY % (b'k', b'k'), 'launch scope changed'),
    ('重复命中', SCOPE + BODY % (b'k', b'k') + SCOPE + BODY % (b'k', b'k'), 'found 2'),
]
raise SystemExit(0 if all(run(*c) for c in cases) else 1)
PY
then
  ok "app.asar CUA：新版适配变量名，旧版跳过，作用域漂移/重复命中仍拒绝"
else
  bad "app.asar CUA 替换回归（变量名适配/旧版跳过/作用域/唯一性）"
fi
grep -qF "BROWSER_PATCHED_MARKER='browser-phase-patch'" "$PATCH_SH" \
  && ok "浏览器收尾标记的稳定补丁标记仍保留" || bad "缺浏览器收尾标记补丁"
if python3 - "$PATCH_SH" <<'PY'
import contextlib, io, re, sys
text = open(sys.argv[1], encoding='utf-8').read()
try:
    block = text[text.index('# 3b. browser-complete'):text.index('# 4. recompute per-file')]
except ValueError:
    print('FAIL 找不到 browser-complete 补丁段标记')
    raise SystemExit(1)

SAMPLE = (b'function o(e,t,n){let i=n?.phase==="commentary"?(0,s._)(e,t):void 0;'
          b'return null!=i?{content:"",removed:!0,browserCompletion:null!=i.headline}:0}')
NO_CONSUMER = (b'function o(e,t,n){let i=n?.phase==="commentary"?(0,s._)(e,t):void 0;'
               b'return 0}')

def run(name, sample, expect_err=None, expect_patch=True):
    ns = {'re': re, 'buf': bytearray(sample)}
    err = None
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            exec(compile(block, '<browser-block>', 'exec'), ns)
    except Exception as exc:
        err = '%s: %s' % (type(exc).__name__, exc)
    if expect_err:
        if not err or expect_err not in err:
            print('FAIL %s: 期望报错含 %r，实际 %r' % (name, expect_err, err))
            return False
        print('ok   %s（已拒绝）' % name)
        return True
    if err:
        print('FAIL %s: %s' % (name, err))
        return False
    out = bytes(ns['buf'])
    if len(out) != len(sample):
        print('FAIL %s: 长度 %d -> %d' % (name, len(sample), len(out)))
        return False
    marker = b'browser-phase-patch'
    if expect_patch and (marker not in out or b'.phase==="commentary"' in out):
        print('FAIL %s: 门禁没拆掉或标记没写入' % name)
        return False
    if not expect_patch and marker in out:
        print('FAIL %s: 旧版不应凭空写 phase 补丁' % name)
        return False
    print('ok   %s%s' % (name, '' if expect_patch else '（已跳过）'))
    return True

cases = [
    ('26.1117 门禁形态', SAMPLE, None),
    ('旧版源码没有 phase 门禁', b'nothing here', None, False),
    ('缺 browserCompletion 消费者', NO_CONSUMER, 'consumer not found'),
    ('重复命中', SAMPLE + SAMPLE, 'found 2'),
]
raise SystemExit(0 if all(run(*c) for c in cases) else 1)
PY
then
  ok "app.asar 浏览器完成标记不再受 phase 限制（普通文本不受影响）"
else
  bad "app.asar 浏览器完成标记门禁补丁回归"
fi
if printf 'wrapper-ok\n' | node "$PATCH_SCRIPTS/cua-node-wrapper.cjs" /bin/cat >"$WORK/cua-wrapper.out" 2>"$WORK/cua-wrapper.err" \
   && grep -qx 'wrapper-ok' "$WORK/cua-wrapper.out"; then
  ok "CJS wrapper 能启动目标并透传 stdio"
else
  bad "CJS wrapper 启动/stdio 透传失败"
fi

# 离线中文：语言包加载器必须把 enable_i18n 的缺省值翻成 true。
grep -qF 'I18N_TRUE_REGEX=' "$PATCH_SH" \
  && grep -qF 'I18N_FALSE_REGEX=' "$PATCH_SH" \
  && grep -qF 'offline i18n default: source pattern not present (older build) - skipped' "$PATCH_SH" \
  && ok "离线中文：新版补 false→true，旧版没有源码时明确跳过" || bad "离线中文旧版兼容分支缺失"
grep -qF 'I18N_QUOTED_OLD = b'"'"'get("enable_i18n",!1)'"'"'' "$PATCH_SH" \
  && grep -qF 'I18N_QUOTED_NEW = b'"'"'get("enable_i18n",!0)'"'"'' "$PATCH_SH" \
  && grep -qF 'I18N_BACKTICK_OLD = b'"'"'get(`enable_i18n`,!1)'"'"'' "$PATCH_SH" \
  && grep -qF 'I18N_BACKTICK_NEW = b'"'"'get(`enable_i18n`,!0)'"'"'' "$PATCH_SH" \
  && ok "即时语言包加载器兼容双引号/反引号 false→true" || bad "缺离线中文 asar 替换"
if _i18n_len="$(python3 - "$PATCH_SH" <<'PY'
import ast, re, sys
text = open(sys.argv[1], encoding='utf-8').read()
pairs = []
for old_name, new_name in [
    ("I18N_QUOTED_OLD", "I18N_QUOTED_NEW"),
    ("I18N_BACKTICK_OLD", "I18N_BACKTICK_NEW"),
]:
    old = re.search(r"^%s = b('(?:[^'\\\\]|\\\\.)*')$" % old_name, text, re.M)
    new = re.search(r"^%s = b('(?:[^'\\\\]|\\\\.)*')$" % new_name, text, re.M)
    if not old or not new:
        raise SystemExit(2)
    a = ast.literal_eval(old.group(1)).encode()
    b = ast.literal_eval(new.group(1)).encode()
    if len(a) != len(b):
        raise SystemExit(1)
    pairs.append(f"{len(a)}:{len(b)}")
print(",".join(pairs))
raise SystemExit(0)
PY
)"; then
  ok "离线中文两种形态均等长（${_i18n_len}）"
else
  bad "离线中文替换长度不一致或定义缺失（${_i18n_len:-parse-error}）"
fi
if python3 - "$PATCH_SH" <<'PY'
import contextlib, io, sys

text = open(sys.argv[1], encoding='utf-8').read()
try:
    block = text[text.index('# 3. Offline language'):text.index('# 3b. browser-complete')]
except ValueError:
    print('FAIL 找不到离线中文补丁段标记')
    raise SystemExit(1)

PRELUDE = '''
def swap(old, new, expect=(1,), name='?'):
    global buf
    n = buf.count(old)
    assert n in expect, '%s: found %d, expected %s' % (name, n, expect)
    if n:
        assert len(old) == len(new)
        buf = buf.replace(old, new)
    print('%s: %d occurrence(s) patched' % (name, n))
'''

def run(name, sample, expect_err=None, expect_patch=True):
    ns = {'buf': bytearray(sample)}
    err = None
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            exec(compile(PRELUDE + block, '<i18n-block>', 'exec'), ns)
    except Exception as exc:
        err = '%s: %s' % (type(exc).__name__, exc)
    if expect_err:
        if not err or expect_err not in err:
            print('FAIL %s: 期望报错含 %r，实际 %r' % (name, expect_err, err))
            return False
        print('ok   %s（已拒绝）' % name)
        return True
    if err:
        print('FAIL %s: %s' % (name, err))
        return False
    out = bytes(ns['buf'])
    changed = b'get("enable_i18n",!0)' in out or b'get(`enable_i18n`,!0)' in out
    if expect_patch != changed:
        print('FAIL %s: expect_patch=%s changed=%s' % (name, expect_patch, changed))
        return False
    print('ok   %s%s' % (name, '' if expect_patch else '（已跳过）'))
    return True

cases = [
    ('旧版无离线语言源码', b'nothing here', None, False),
    ('双引号 false→true', b'get("enable_i18n",!1)', None, True),
    ('反引号 false→true', b'get(`enable_i18n`,!1)', None, True),
    ('重复命中', b'get("enable_i18n",!1)get(`enable_i18n`,!1)', 'expected at most 1'),
]
raise SystemExit(0 if all(run(*c) for c in cases) else 1)
PY
then
  ok "离线中文替换行为：旧版跳过、两种新版形态命中、重复命中拒绝"
else
  bad "离线中文替换行为回归"
fi

# 端到端复现“旧版 26.1013”：核心模型/Sparkle 补丁已经命中，但 CUA、phase
# gate、enable_i18n 这三处新版源码全都不存在。旧脚本会在第一个 assert 直接
# ABORTED:integrity；新脚本必须逐项打印 skip 并继续完成完整性刷新。
if python3 - "$PATCH_SH" "$WORK/old-build" <<'PY'
import contextlib
import io
import os
from pathlib import Path
import plistlib
import struct
import sys

patch_sh = Path(sys.argv[1])
work = Path(sys.argv[2])
text = patch_sh.read_text(encoding='utf-8')
start_marker = "  if ! python3 -u - \"$asar\" \"$plist\" >>\"$LOG\" 2>&1 <<'PYEOF'\n"
end_marker = "\nPYEOF\n"
try:
    start = text.index(start_marker) + len(start_marker)
    end = text.index(end_marker, start)
except ValueError:
    print('FAIL 找不到 asar integrity Python heredoc')
    raise SystemExit(1)
code = text[start:end]

app = work / 'ChatGPT-Patched.new'
contents = app / 'Contents'
resources = contents / 'Resources'
resources.mkdir(parents=True)
asar = resources / 'app.asar'
plist = contents / 'Info.plist'

# 最小合法 asar：空 files 树，无 per-file integrity；只验证旧版三处可选补丁缺失时
# integrity 脚本能走完，不再重跑模型/Sparkle 的外层 shell 补丁。
header = b'{"files":{}}'
raw = struct.pack('<III', 32, len(header), len(header)) + b'\0' * 4 + header + b'\0' * 32
asar.write_bytes(raw)
with plist.open('wb') as fh:
    plistlib.dump({
        'CFBundleShortVersionString': '26.1013.40934',
        'ElectronAsarIntegrity': {
            'Resources/app.asar': {
                'algorithm': 'SHA256',
                'hash': '0' * 64,
            }
        },
    }, fh)

old_argv = sys.argv[:]
sys.argv = ['-', str(asar), str(plist)]
out = io.StringIO()
try:
    with contextlib.redirect_stdout(out):
        exec(compile(code, '<asar-integrity>', 'exec'), {})
finally:
    sys.argv = old_argv

logged = out.getvalue()
required_skips = [
    'cua signed-node wrapper: source pattern not present (older build) - skipped',
    'offline i18n default: source pattern not present (older build) - skipped',
    'browser-complete phase gate: source pattern not present (older build) - skipped',
]
missing = [line for line in required_skips if line not in logged]
if missing:
    print('FAIL 旧版没有明确跳过：%s' % missing)
    raise SystemExit(1)
if asar.stat().st_size != len(raw):
    print('FAIL 旧版 asar 大小被改写')
    raise SystemExit(1)
with plist.open('rb') as fh:
    pl = plistlib.load(fh)
if pl['ElectronAsarIntegrity']['Resources/app.asar']['hash'] == '0' * 64:
    print('FAIL plist 的 asar 头哈希没有刷新')
    raise SystemExit(1)
print('ok   旧版 26.1013：三处新版补丁缺失时全部 skip，integrity 正常完成')
PY
then
  ok "26.1013 旧版端到端：可选补丁缺失不再误伤完整性刷新"
else
  bad "26.1013 旧版端到端回归（可选补丁缺失仍会 ABORTED:integrity）"
fi

grep -qF '"$RES_DIR"/patch/scripts/*' "$ROOT/Resources/codex/setup/steps/100-patched-app.sh" \
  && ok "安装器会把 CUA wrapper 脚本同步进 picker-patch" || bad "安装器漏同步 CUA wrapper 脚本"
grep -qF 'PATCH_REV=' "$ROOT/Resources/codex/setup/steps/100-patched-app.sh" \
  && grep -qF 'MARKER_REV=' "$ROOT/Resources/codex/setup/steps/100-patched-app.sh" \
  && grep -qF '"$MARKER_REV" != "$PATCH_REV"' "$ROOT/Resources/codex/setup/steps/100-patched-app.sh" \
  && ok "安装器同版本也会核对补丁代际，旧 marker 不会假跳过" \
  || bad "安装器没有核对补丁代际"
grep -qF '文件存在，但补丁未完成' "$ROOT/Resources/codex/setup/steps/130-selfcheck.sh" \
  && grep -qF "grep -q '(patched)'" "$ROOT/Resources/codex/setup/steps/130-selfcheck.sh" \
  && ok "配置后自检不再把「文件存在」误报成副本已同步" \
  || bad "配置后自检仍可能先报 ✅ 再报失败"

# 2026-10-20：`--install` 必须**版本感知**。
# 事故：官方升级后 --auto-update 因"副本正在运行"defer（exit 0），安装器回退到 --install，
# 而旧的 install() 只查 is_patched()（asar 里有补丁特征就跳过）→ 日志写 "already patched, skip"
# 然后 open 旧副本 → **假成功**，副本还停在旧版本。
grep -qF 'version mismatch (patched=$marker_ver, source=$current) → rebuilding' "$PATCH_SH" \
  && ok "install() 版本感知（marker≠源码版本必须重建）" || bad "install() 又变回「只看 is_patched」的假成功"
grep -qF 'PATCH_REVISION="20261124.1"' "$PATCH_SH" \
  && grep -qF 'patch revision mismatch' "$PATCH_SH" \
  && grep -qF '[ "$marker_rev" = "$PATCH_REVISION" ] && copy_healthy' "$PATCH_SH" \
  && grep -qF '"patchRevision":"%s"' "$PATCH_SH" \
  && ok "install() 用「官方版本 + 补丁代际 + 体检」判定，旧 marker 会强制重建" \
  || bad "install() 缺补丁代际判定（同版本可能假跳过）"

# ---------------------------------------------------------------------------
# ②b 原子重建护栏（2026-10-22）
# 事故：另一台机器点「配置」后弹"ChatGPT-Patched 已损坏，无法打开"。根因是重建
# **在正式路径上原地做**：先把旧副本 mv 成备份，再把官方版 cp 到正式路径原地改 ——
# 那一两分钟里正式路径上是个半成品（asar 已改、签名没重做、启动器没编好），
# 用户此时双击就报"已损坏"；任务中途被取消/关机，半成品还会留在正式路径上。
# 修法：先在暂存目录建好、验签通过，再原子换入 —— 正式路径上永远是好的。
grep -qF 'STAGING="$(dirname "$PATCHED")/ChatGPT-Patched.new.' "$PATCH_SH" \
  && ok "重建在暂存目录做（正式路径不再放半成品）" || bad "重建又变回正式路径原地做"
grep -qF 'mv "$STAGING" "$PATCHED"' "$PATCH_SH" \
  && ok "验签通过后换入暂存副本" || bad "缺暂存→正式的换入动作"
grep -qF 'discard_staging()' "$PATCH_SH" \
  && grep -qF 'discard_staging "byte-verify"' "$PATCH_SH" \
  && ok "失败只丢暂存目录（旧副本不受影响）" || bad "缺失败清理逻辑"
# 字节校验必须针对**暂存目录那份** asar：用全局 is_patched() 会去查正式路径 → 永远失败
grep -qF 'discard_staging "byte-verify"' "$PATCH_SH" \
  && ! grep -qF 'if ! is_patched; then' "$PATCH_SH" \
  && ok "字节校验针对暂存副本（不再查正式路径）" || bad "字节校验又变回查正式路径"
# 顺序：换入必须在验签之后
verify_line=$(grep -n 'codesign verify passed' "$PATCH_SH" | head -1 | cut -d: -f1)
swap_line=$(grep -n 'mv "$STAGING" "$PATCHED"' "$PATCH_SH" | head -1 | cut -d: -f1)
if [ -n "$verify_line" ] && [ -n "$swap_line" ] && [ "$verify_line" -lt "$swap_line" ]; then
  ok "顺序正确：先验签再换入"
else
  bad "换入发生在验签之前（半成品会先落到正式路径）"
fi

# ---------------------------------------------------------------------------
# ②c 副本体检 + 自愈（2026-10-22）
# 目标：升级之后「点配置」不再出错 —— 副本坏了自动重建，重建还不行也留一个能打开的。
grep -qF 'copy_healthy()' "$PATCH_SH" \
  && grep -qF '&& copy_healthy; then' "$PATCH_SH" \
  && ok "install() 先体检再决定跳过/重建" || bad "install() 没做副本体检"
grep -qF '副本存在但体检不通过' "$PATCH_SH" \
  && ok "坏副本会被自动重建（点配置即修复）" || bad "缺坏副本自动重建"
grep -qF '已放置官方原版副本（未打补丁）' "$PATCH_SH" \
  && ok "重建失败也保证留一个能打开的副本" || bad "缺官方原版兜底"
grep -qF 'exit 2' "$PATCH_SH" \
  && ok "降级用退出码 2（App 显示黄色提示而不是失败）" || bad "缺降级退出码"

# ---------------------------------------------------------------------------
# ②d 模型可见性 patch 正则（2026-11-10，26.1103）
# 事故：官方把条件里的字面量挪到运算符前面并换成双引号
# （useHiddenModels&&"amazonBedrock"!==a），旧正则 `...[^`]*!==`amazonBedrock``
# 命中 0 → ABORTED:pattern-count → 安装器退化成「放一份未打补丁的官方原版」，
# 副本能开但下拉里没有自定义模型，且 patch-state 版本对不上 → 配置报失败。
U_RE="$(sed -nE 's/^PATTERN_REGEX='"'"'(.*)'"'"'$/\1/p' "$PATCH_SH" | head -1)"
P_RE="$(sed -nE 's/^PATCHED_REGEX='"'"'(.*)'"'"'$/\1/p' "$PATCH_SH" | head -1)"
UNPATCHED_MARK="$(grep -cF 'grep -aqE "$PATCHED_REGEX" "$asar"' "$PATCH_SH" || true)"
if [ -z "$U_RE" ] || [ -z "$P_RE" ]; then
  bad "缺 PATTERN_REGEX / PATCHED_REGEX 定义（pattern 校验串必须集中管理）"
elif [ "$UNPATCHED_MARK" -lt 2 ]; then
  bad "is_patched / 字节校验没有引用 \${PATCHED_REGEX}（又硬编码了？）"
else
  ok "pattern 正则集中在 PATTERN_REGEX / PATCHED_REGEX，且两处校验都引用它"
  # 用受控样例跑真正则：历史形态 + 26.1103 形态都必须各命中 1，已打补丁形态必须 0
  re_case() {  # $1=名称 $2=文本 $3=要用的正则 $4=期望命中数
    printf '%s' "$2" > "$WORK/re.txt"
    local got; got=$(grep -cE "$3" "$WORK/re.txt" 2>/dev/null || true)
    if [ "$got" = "$4" ]; then ok "正则·$1（命中 ${got}）"; else bad "正则·$1 命中 ${got}，期望 $4"; fi
  }
  re_case "旧形态 <=26.1027" 'a.useHiddenModels&&i!==`amazonBedrock`' "$U_RE" 1
  re_case "新形态 26.1103" 'o.useHiddenModels&&"amazonBedrock"!==a' "$U_RE" 1
  re_case "已打补丁（旧形态）" 'a.useHiddenModels&&i===`amazonBedrock`' "$U_RE" 0
  re_case "已打补丁（新形态）" 'o.useHiddenModels&&"amazonBedrock"===a' "$U_RE" 0
  re_case "体检认已打补丁（旧）" 'a.useHiddenModels&&i===`amazonBedrock`' "$P_RE" 1
  re_case "体检认已打补丁（新）" 'o.useHiddenModels&&"amazonBedrock"===a' "$P_RE" 1
  re_case "体检不误判未打补丁" 'o.useHiddenModels&&"amazonBedrock"!==a' "$P_RE" 0
fi

# ---------------------------------------------------------------------------
# ③ 行为用例：把脚本里那段启动器选择逻辑抠出来，用受控的假 clang 跑
sed -n '/^  launcher_ok=""/,/main executable wrapped with user-data-dir launcher/p' "$PATCH_SH" > "$WORK/block.sh"
if [ ! -s "$WORK/block.sh" ]; then
  bad "抠不出启动器选择逻辑（脚本结构变了，请同步更新本测试）"
else
  # $1=用例名  $2=假 clang 定义  $3=预置命令
  run_case() {
    local name="$1" clang_def="$2" prep="$3" dir="$WORK/$1"
    mkdir -p "$dir/bin" "$dir/base/scripts"
    {
      echo 'set -euo pipefail'
      echo "BASE=\"$dir/base\"; bindir=\"$dir/bin\"; uddir=\"$dir/ud\"; LOG=\"$dir/log\"; : > \"\$LOG\""
      echo 'log() { echo "$*" >> "$LOG"; }'
      echo "$clang_def"
      echo "$prep"
      # 2026-10-07：这段在 patch.sh 里是函数内的（含 local）→ 抠出来也要包成函数再跑
      echo 'f() {'
      cat "$WORK/block.sh"
      echo '}'
      echo 'f'
    } > "$dir/harness.sh"
    bash "$dir/harness.sh" >> "$dir/log" 2>&1
    echo $? > "$dir/rc"
  }

  # A. clang 在但编译失败 → 必须回退预编译启动器
  run_case A 'clang() { if [ "${1:-}" = "--version" ]; then echo "fake clang"; return 0; fi; return 1; }' \
             'printf FAKE-UNIVERSAL > "$BASE/launcher-universal"'
  if [ "$(cat "$WORK/A/rc")" = 0 ] && [ "$(cat "$WORK/A/bin/ChatGPT" 2>/dev/null)" = "FAKE-UNIVERSAL" ] \
     && grep -q "回退预编译启动器" "$WORK/A/log"; then
    ok "clang 链接失败 → 自动回退预编译启动器（今天事故场景 A）"
  else
    bad "clang 失败时没有回退预编译启动器（rc=$(cat "$WORK/A/rc" 2>/dev/null)）"
  fi

  # B. clang 成功 → 用编译产物，不回退
  run_case B 'clang() { if [ "${1:-}" = "--version" ]; then echo "fake clang"; return 0; fi; local out=""; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done; [ -n "$out" ] && printf CLANG-BUILT > "$out"; return 0; }' \
             'printf FAKE-UNIVERSAL > "$BASE/launcher-universal"'
  if [ "$(cat "$WORK/B/rc")" = 0 ] && [ "$(cat "$WORK/B/bin/ChatGPT" 2>/dev/null)" = "CLANG-BUILT" ] \
     && grep -q "launcher compiled with clang" "$WORK/B/log"; then
    ok "clang 可用时走编译产物（不回退）"
  else
    bad "clang 可用时行为不对（rc=$(cat "$WORK/B/rc" 2>/dev/null)）"
  fi

  # C. 既没有 clang 产物也没有预编译启动器 → 必须非 0 退出，且不许留下半成品
  run_case C 'clang() { return 1; }' ':'
  if [ "$(cat "$WORK/C/rc")" != 0 ] && [ ! -s "$WORK/C/bin/ChatGPT" ]; then
    ok "启动器彻底缺失 → 中止重建（rc=$(cat "$WORK/C/rc")，没有半成品）"
  else
    bad "启动器缺失时没有中止（rc=$(cat "$WORK/C/rc" 2>/dev/null)）"
  fi
fi

# ---------------------------------------------------------------------------
# ④ 行为用例：CLI 软链维护（官方改布局不断手机端 ccpocket 桥）
sed -n '/^ensure_cli_symlink() {/,/^}/p' "$PATCH_SH" > "$WORK/symlink_fn.sh"
if [ ! -s "$WORK/symlink_fn.sh" ]; then
  bad "抠不出 ensure_cli_symlink（脚本结构变了，请同步更新本测试）"
else
  HOME_T="$WORK/home-link"; PATCHED_T="$WORK/patched"
  mkdir -p "$HOME_T/.local/bin" "$PATCHED_T/Contents/Resources/codex-cli/bin"
  printf 'shim' > "$PATCHED_T/Contents/Resources/codex-cli/bin/codex"
  ln -s "$PATCHED_T/Contents/Resources/old-layout-codex" "$HOME_T/.local/bin/codex"   # 悬空软链
  cat > "$WORK/link-harness.sh" <<EOF
set -uo pipefail
HOME="$HOME_T"; PATCHED="$PATCHED_T"; LOG="$WORK/link.log"; : > "\$LOG"
log() { echo "\$*" >> "\$LOG"; }
$(cat "$WORK/symlink_fn.sh")
ensure_cli_symlink
ensure_cli_symlink
EOF
  bash "$WORK/link-harness.sh"
  want="$PATCHED_T/Contents/Resources/codex-cli/bin/codex"
  got="$(readlink "$HOME_T/.local/bin/codex")"
  if [ "$got" = "$want" ]; then
    ok "悬空软链被重指到新布局（→ codex-cli/bin/codex）"
  else
    bad "软链没重指对（got=${got}）"
  fi
  [ "$(grep -c "codex CLI 软链" "$WORK/link.log")" -ge 2 ] \
    && ok "重复调用幂等（第二次报「无需变更」）" || bad "重复调用不幂等"

  HOME_N="$WORK/home-nolink"; mkdir -p "$HOME_N"
  sed "s#$HOME_T#$HOME_N#" "$WORK/link-harness.sh" > "$WORK/link-harness-nolink.sh"
  bash "$WORK/link-harness-nolink.sh"
  [ -e "$HOME_N/.local/bin/codex" ] && bad "不该主动创建软链" || ok "没有软链时不去创建（不打扰别的机器）"
fi

echo
if [ "$FAIL" = 0 ]; then
  echo "全部通过 ✅"
  exit 0
fi
echo "有护栏缺失 ❌ —— 别打包，先看 patch.sh 是不是被回退了"
exit 1
