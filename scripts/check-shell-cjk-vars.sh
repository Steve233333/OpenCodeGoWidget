#!/bin/bash
# 说大白话：检查 shell 脚本里有没有 `$VAR` 紧跟中文标点的写法（2026-09-23 加）。
# 为什么：bash 在非 UTF-8 locale 下会把中文标点当成变量名的一部分 → set -u 直接报 unbound。
# 今天已经在这上面栽过三次（ensure-proxy / smoke / 安装器各一次），所以进门槛。
set -uo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PYEOF'
import glob, re, sys
pat = re.compile(r'(?<![{A-Za-z0-9_])\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]')
files = (sorted(glob.glob('scripts/*.sh'))
         + ['Resources/codex/vision/ensure-proxy.sh']
         + sorted(glob.glob('Resources/codex/setup/steps/*.sh'))
         + ['Resources/codex/codex-oneclick-setup.command'])
hits = [(p, i, l.strip()) for p in files if p
        for i, l in enumerate(open(p, encoding='utf-8'), 1) if pat.search(l)]
if hits:
    print('❌ 有 $VAR 紧跟中文标点的写法（可能被当成变量名 → unbound）：')
    for p, i, l in hits[:20]:
        print(f'   {p}:{i}: {l[:100]}')
    print('   修法：写成 ${VAR}')
    sys.exit(1)
print('✅ 没有 $VAR 紧跟中文标点的写法')
PYEOF
