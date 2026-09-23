#!/bin/bash
# 真机冒烟：转换层改完必须能真跑（2026-09-23 转换层收敛时加的）。
# 每个模型发一条流式请求，断言：HTTP 200、有正文、没有把工具调用 markup 漏进正文。
# 用法：scripts/smoke-conversion.sh [模型…]
#      默认 DeepSeek / MiMo / Muse / GLM 各一条
set -uo pipefail

PROXY="${PROXY:-http://127.0.0.1:19100}"
COUNT_TEXT="import json,sys
text = ''
for line in open(sys.argv[1], encoding='utf-8', errors='replace'):
    if not line.startswith('data:'):
        continue
    try:
        obj = json.loads(line[5:].strip())
    except Exception:
        continue
    if obj.get('type') == 'response.output_text.delta':
        text += obj.get('delta', '')
print(len(text))"

MODELS=("$@")
if [ "${#MODELS[@]}" -eq 0 ]; then
  MODELS=(deepseek-v4.1-flash-go mimo-v2.6-flash-go muse-spark-1.3-contributor-go glm-5.3-go)
fi

fail=0
for m in "${MODELS[@]}"; do
  out="$(mktemp)"
  payload=$(printf '{"model":"%s","stream":true,"max_output_tokens":3000,"input":"用一句话说明：换手机电池前要做什么？"}' "$m")
  code="$(curl -s -o "$out" -w '%{http_code}' --max-time 180 -X POST "$PROXY/v1/responses" \
           -H 'Authorization: Bearer dummy' -H 'Content-Type: application/json' -d "$payload")"
  chars="$(python3 -c "$COUNT_TEXT" "$out" 2>/dev/null || echo 0)"
  markup="$(grep -c '<tool_call>' "$out" 2>/dev/null || true)"
  [ -z "$markup" ] && markup=0
  if [ "$code" = "200" ] && [ "${chars:-0}" -gt 0 ] && [ "$markup" = "0" ]; then
    echo "  ✅ ${m}：HTTP 200 · 正文 ${chars} 字 · markup 0"
  else
    echo "  ❌ ${m}：HTTP ${code} · 正文 ${chars:-0} 字 · markup ${markup}"
    fail=1
  fi
  rm -f "$out"
done

if [ "$fail" = 0 ]; then
  echo "冒烟全绿 ✅"
  exit 0
fi
echo "有失败项 ❌"
exit 1
