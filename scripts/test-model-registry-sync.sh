#!/bin/bash
# 模型目录（models.json）与代理档位表（reasoning_registry.json）必须一致。
# 少了条目 -> 代理会按 generic high 兜底，桌面滑杆也显示不出来；这是“适配了模型但档位没跟上”的根因。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "==> 模型档位一致性自检（离线）"
python3 - "$ROOT" <<'PY'
import json, sys
root=sys.argv[1]
models=json.load(open(root+'/Resources/codex/templates/models.json'))['models']
registry=json.load(open(root+'/Resources/codex/relay/reasoning_registry.json'))
missing=[]; mismatch=[]
for m in models:
    slug=m.get('slug','')
    base=slug[:-3] if slug.endswith('-go') else slug[:-4] if slug.endswith('-zen') else slug
    levels=[x.get('effort') for x in (m.get('supported_reasoning_levels') or []) if isinstance(x,dict) and x.get('effort')]
    if not levels: continue
    if base not in registry: missing.append(base)
    elif registry[base]!=levels: mismatch.append((base,levels,registry[base]))
if missing or mismatch:
    print('❌ 模型/代理档位不同步：')
    for x in missing: print('  缺表:',x)
    for x in mismatch: print('  不一致:',x)
    sys.exit(1)
# 新模型可能先被线上目录自动发现，模板还没同步。这里单列本轮已实测的档位，
# 防止“运行时有五档、仓库真源又退回只有 high”的漂移。
required = {
    'beam-free': ['low', 'medium', 'high', 'xhigh', 'max'],
    'minimax-m3.1-flash-free': ['low', 'medium', 'high', 'xhigh', 'max'],
}
bad_required = [(name, levels, registry.get(name)) for name, levels in required.items()
                if registry.get(name) != levels]
if bad_required:
    print('❌ 新模型实测档位未同步：')
    for x in bad_required: print(' ', x)
    sys.exit(1)
print(f'   ✅ {len(models)} 个模型的档位与 reasoning_registry 一致')
PY
