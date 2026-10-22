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

# 2026-10-20：`--install` 必须**版本感知**。
# 事故：官方升级后 --auto-update 因"副本正在运行"defer（exit 0），安装器回退到 --install，
# 而旧的 install() 只查 is_patched()（asar 里有补丁特征就跳过）→ 日志写 "already patched, skip"
# 然后 open 旧副本 → **假成功**，副本还停在旧版本。
grep -qF 'version mismatch (patched=$marker_ver, source=$current) → rebuilding' "$PATCH_SH" \
  && ok "install() 版本感知（marker≠源码版本必须重建）" || bad "install() 又变回「只看 is_patched」的假成功"
grep -qF 'local current marker_ver' "$PATCH_SH" \
  && grep -qF 'if is_patched && [ -n "$current" ]' "$PATCH_SH" \
  && ok "install() 用的是版本比较而不是单一 is_patched" || bad "install() 缺版本比较"

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
