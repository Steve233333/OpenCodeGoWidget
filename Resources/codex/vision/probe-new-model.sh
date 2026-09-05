#!/bin/bash
# probe-new-model.sh — 新模型接入 5 探针分类器（2026-09-05）
# 用法：./probe-new-model.sh <网关模型id> [--go-key KEY]
#   例：./probe-new-model.sh omen-alpha
#       ./probe-new-model.sh kimi-k3
# 输出：A原生派 / B桥接派（+是否 ALWAYS_BRIDGE）/ 档位声明验证 / 联网家族 / 视觉直通
# 注意：每个探针都是真实上游请求，会消耗少量 Go 额度；P3 只测条目声称的档位（slim 版，不穷举）
set -uo pipefail

MODEL="${1:-}"
GO_KEY="${2:-}"
if [ -z "$MODEL" ]; then echo "用法：$0 <网关模型id> [--go-key KEY]"; exit 1; fi
if [[ "$GO_KEY" == "--go-key" ]]; then GO_KEY="${3:-}"; fi
if [ -z "$GO_KEY" ]; then
  GO_KEY="$(grep '^ZEN_API_KEY=' "$HOME/.config/agent-vision-toolkit/env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"'")"
fi
[ -z "$GO_KEY" ] && { echo "找不到 ZEN_API_KEY"; exit 1; }

RESP="https://opencode.ai/zen/go/v1/responses"
CHAT="https://opencode.ai/zen/go/v1/chat/completions"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

post() { # $1=url $2=jsonfile -> prints HTTP code, saves body to $3
  curl -4 -sS --max-time 60 -X POST "$1" -H "Authorization: Bearer $GO_KEY" \
    -H "Content-Type: application/json" -d @"$2" -o "$3" -w "%{http_code}" 2>/dev/null
}

say() { printf '[probe] %s\n' "$*"; }

# ---- P1/P2 协议分类 ----
say "P1: /responses 裸请求…"
echo "{\"model\":\"$MODEL\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}],\"max_output_tokens\":16,\"store\":false}" > "$TMP/p1.json"
C1=$(post "$RESP" "$TMP/p1.json" "$TMP/p1.out"); echo "  responses bare -> HTTP $C1"
say "P2: /chat 裸请求…"
echo "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi, one word\"}],\"max_tokens\":16}" > "$TMP/p2.json"
C2=$(post "$CHAT" "$TMP/p2.json" "$TMP/p2.out"); echo "  chat bare -> HTTP $C2"
if [ "$C1" = "200" ]; then CLASS="A原生派（零代理改动）"
elif [ "$C2" = "200" ]; then
  if [ "$C1" = "500" ]; then CLASS="B桥接派（500 自动桥兜底）"
  else CLASS="B桥接派＋ALWAYS_BRIDGE 候选（responses 回 $C1 会穿透，需无条件桥）"; fi
else CLASS="不可用（两端点皆非 200，先查网关/模型名）"; fi
echo "  => 分类：$CLASS"

# ---- P3 档位声明验证（只测给定档位，逗号分隔；默认 low,high）----
LEVELS="${LEVELS:-low,high}"
say "P3: 档位声明验证 [$LEVELS]…"
IFS=',' read -ra LV_ARR <<< "$LEVELS"
for lv in "${LV_ARR[@]}"; do
  lv="$(echo "$lv" | tr -d ' ')"
  echo "{\"model\":\"$MODEL\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"1+1=?\"}]}],\"max_output_tokens\":16,\"store\":false,\"reasoning\":{\"effort\":\"$lv\"}}" > "$TMP/p3.json"
  C=$(post "$RESP" "$TMP/p3.json" "$TMP/p3.out")
  if [ "$C" != "200" ]; then
    echo "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"1+1=?\"}],\"max_tokens\":16,\"reasoning_effort\":\"$lv\"}" > "$TMP/p3c.json"
    CC=$(post "$CHAT" "$TMP/p3c.json" "$TMP/p3c.out"); C="responses:$C → chat:$CC"
  fi
  echo "  effort=$lv -> HTTP $C"
done

# ---- P4 web_search 接受性 ----
say "P4: web_search 工具接受性…"
echo "{\"model\":\"$MODEL\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"search: test\"}]}],\"tools\":[{\"type\":\"web_search\"}],\"stream\":false,\"store\":false}" > "$TMP/p4.json"
C4=$(post "$RESP" "$TMP/p4.json" "$TMP/p4.out"); echo "  web_search -> HTTP $C4"
if [ "$C4" = "200" ]; then echo "  => 原生联网家族（加前缀白名单 + supports_search_tool=true）"
else echo "  => 无原生联网（synthetic 边车自动生效，零改动；跨模型搜索历史走前缀白名单拦截）"; fi

# ---- P5 function+流式+图片（三合一）----
say "P5a: function 工具调用…"
echo "{\"model\":\"$MODEL\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"echo hi via echo tool\"}]}],\"tools\":[{\"type\":\"function\",\"name\":\"echo\",\"description\":\"echo\",\"parameters\":{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"],\"additionalProperties\":false}}],\"max_output_tokens\":128,\"store\":false,\"stream\":true}" > "$TMP/p5a.json"
C5a=$(post "$RESP" "$TMP/p5a.json" "$TMP/p5a.out"); echo "  function流式 -> HTTP $C5a"
python3 - "$TMP/p5a.out" <<'PY' 2>/dev/null || echo "  (SSE 解析跳过)"
import json,sys
args=''; n_delta=0
for line in open(sys.argv[1]):
    line=line.strip()
    if line.startswith('data: '):
        try: d=json.loads(line[6:])
        except: continue
        if d.get('type')=='response.function_call_arguments.delta':
            n_delta+=1; args+=d.get('delta','')
        if d.get('type')=='response.function_call_arguments.done': args=d.get('arguments') or args
try:
    json.loads(args); print(f"  工具参数合法 JSON ✓ (delta {n_delta} 块): {args[:60]}")
except Exception as e: print(f"  工具参数非法/缺失（§20 式截断嫌疑）: {args[:80]}")
PY
say "P5b: 图片直通（8x8 测试图，问颜色）…"
IMG=$(python3 -c "
import base64,struct,zlib
def ch(t,d):
    c=struct.pack('>I',len(d))+t+d; return c+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
ih=struct.pack('>IIBBBBB',8,8,8,2,0,0,0)
raw=b''.join(b'\x00'+b'\xff\x00\x00'*8 for _ in range(8))
print(base64.b64encode(b'\x89PNG\r\n\x1a\n'+ch(b'IHDR',ih)+ch(b'IDAT',zlib.compress(raw))+ch(b'IEND',b'')).decode())")
echo "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,$IMG\"}},{\"type\":\"text\",\"text\":\"what color? one word\"}]}],\"max_tokens\":64}" > "$TMP/p5b.json"
C5b=$(post "$CHAT" "$TMP/p5b.json" "$TMP/p5b.out"); echo "  image(chat) -> HTTP $C5b"
python3 -c "import json; d=json.load(open('$TMP/p5b.out')); print('  回答:', (d.get('choices',[{}])[0].get('message',{}).get('content') or str(d)[:100])[:60])" 2>/dev/null

# ---- P6 复杂载荷穿透检查（omen 式：带工具+历史时 400 穿透 vs 500 走桥）----
say "P6: 复杂载荷（历史+工具）是否 400 穿透…"
echo "{"model":"$MODEL","input":[{"role":"user","content":[{"type":"input_text","text":"search news"}]},{"type":"web_search_call","id":"ws_1","status":"completed","action":{"type":"search","query":"news","queries":["news"]},"output":[{"type":"text","text":"result"}]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"here you go"}]},{"role":"user","content":[{"type":"input_text","text":"more news"}]}],"tools":[{"type":"function","name":"web_search","description":"search","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}],"max_output_tokens":64,"store":false}" > "$TMP/p6.json"
C6=$(post "$RESP" "$TMP/p6.json" "$TMP/p6.out"); echo "  complex -> HTTP $C6"
if [[ "$C6" =~ ^4 ]]; then echo "  => 4xx 穿透($C6)！必须加 RESPONSES_ALWAYS_BRIDGE（探测不触发桥）"
elif [ "$C6" = "500" ]; then echo "  => 500，桥接兜底即可"
else echo "  => $C6，无需 ALWAYS_BRIDGE"; fi

echo
echo "===== 结论 ====="
echo "分类：$CLASS"
echo "下一步：A类确认条目即可；B类确认 FALLBACK 名单；ALWAYS_BRIDGE 仅 400 穿透时加；"
echo "P4=200 加搜搜白名单；P5b 对且答对加 NATIVE_VISION；P3 被拒的档位从条目删除。"
