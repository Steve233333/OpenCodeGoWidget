#!/bin/bash
# 真机冒烟：转换层改完必须能真跑（2026-09-23 转换层收敛时加的）。
# 每个模型发一条流式请求，断言：HTTP 200、有正文、没有把工具调用 markup 漏进正文。
# 2026-09-23 追加第 5 类：**跨模型搜索历史** —— 历史含 web_search_call 时切到无原生搜索的
# 模型不能再 400（旧行为是"Cross-model history blocked，请换会话"），必须翻译成工具调用 + 占位结果。
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

CHECK_HISTORY="import json,sys
obj = json.load(open(sys.argv[1], encoding='utf-8'))
items = obj.get('output') or []
if any(isinstance(i, dict) and i.get('type') == 'web_search_call' for i in items):
    print('LEAKED')
else:
    text = ''.join(c.get('text','') for i in items if isinstance(i, dict) and i.get('type') == 'message'
                   for c in (i.get('content') or []) if isinstance(c, dict))
    print('OK' if text.strip() else 'EMPTY')"

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

# ---------- 第 5 类：跨模型搜索历史（DeepSeek/Muse 的历史 → 无原生搜索的模型）----------
# 老行为：400 "Cross-model history blocked ... Please start a new session"。
# 新行为：桥接层翻成 web_search 工具调用 + 诚实占位结果，正常 200 出正文。
HISTORY_JSON="$(mktemp)"
cat > "$HISTORY_JSON" <<'JSON'
{"stream":false,"max_output_tokens":3000,"input":[
 {"type":"message","role":"user","content":[{"type":"input_text","text":"iPhone 12 mini 换壳教程"}]},
 {"type":"reasoning","id":"rs_smoke","summary":[]},
 {"type":"web_search_call","id":"ws_smoke","status":"completed",
  "action":{"type":"search","query":"iPhone 12 mini 换壳教程","queries":["iPhone 12 mini 换壳教程"]}},
 {"type":"message","role":"assistant","content":[{"type":"output_text","text":"先关机再取下卡托，然后从屏幕下沿起翘。"}]},
 {"type":"message","role":"user","content":[{"type":"input_text","text":"一句话复述：第一步做什么？"}]}]}
JSON

for m in mimo-v2.6-flash-go glm-5.3-go; do
  out="$(mktemp)"
  payload="$(python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); p["model"]=sys.argv[2]; print(json.dumps(p,ensure_ascii=False))' "$HISTORY_JSON" "$m")"
  code="$(curl -s -o "$out" -w '%{http_code}' --max-time 180 -X POST "$PROXY/v1/responses" \
           -H 'Authorization: Bearer dummy' -H 'Content-Type: application/json' -d "$payload")"
  verdict="$(python3 -c "$CHECK_HISTORY" "$out" 2>/dev/null || echo BROKEN)"
  if [ "$code" != "200" ]; then
    echo "  ❌ 跨模型历史 ${m}：HTTP ${code} · $(head -c 200 "$out")"
    fail=1
  elif grep -q "Cross-model history blocked" "$out"; then
    echo "  ❌ 跨模型历史 ${m}：又出现旧的 400 拦截文案"
    fail=1
  elif [ "$verdict" = "LEAKED" ]; then
    echo "  ❌ 跨模型历史 ${m}：把 web_search_call 原样透传给了目标模型"
    fail=1
  elif [ "$verdict" != "OK" ]; then
    echo "  ❌ 跨模型历史 ${m}：返回里没有正文（${verdict}）"
    fail=1
  else
    echo "  ✅ 跨模型历史 ${m}：HTTP 200 · 没拦 400 · 历史已翻译"
  fi
  rm -f "$out"
done
rm -f "$HISTORY_JSON"

if [ "$fail" = 0 ]; then
  echo "冒烟全绿 ✅"
  exit 0
fi
echo "有失败项 ❌"
exit 1
