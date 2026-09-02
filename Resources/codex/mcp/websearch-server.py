#!/usr/bin/env python3
"""MCP Server: Web Search via opencode hosted MCP (Exa/Parallel) - no API key required.
Ported from anomalyco/opencode packages/opencode/src/tool/websearch.ts + mcp-websearch.ts

Exposes:
- websearch(query, numResults=8, livecrawl=fallback, type=auto, contextMaxCharacters=10000)
- webfetch(url)  // simple fetch via exa

Only intended for the 24 models without native search (mimo/glm/kimi/qwen/hy3/etc).
The 7 native-search models (deepseek*4, vision*2, muse-go, luna) should use hosted web_search.
"""
import json, sys, hashlib, os, pathlib
import urllib.request, urllib.error

EXA_URL = os.environ.get("EXA_API_KEY") and f"https://mcp.exa.ai/mcp?exaApiKey={os.environ['EXA_API_KEY']}" or "https://mcp.exa.ai/mcp"
PARALLEL_URL = "https://search.parallel.ai/mcp"

# 复用 vision_proxy 的绕代理直连思路（见 codex-vpn-502-fix）：Clash/SakuraCat 会把系统代理设成 127.0.0.1:7890，
# 沙箱里 DNS 解析失败时 urllib 默认走代理就卡死，DIRECT_OPENER 强制直连避免卡 50 秒。
DIRECT_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
# 兜底：DIRECT 失败时再试系统/环境代理，兼顾“连 VPN 上外网 / 不连上大陆网”两种情况
SYSTEM_OPENER = urllib.request.build_opener()

def _load_zen_key():
    for fp in ["/Users/steve233/.config/agent-vision-toolkit/env", str(pathlib.Path.home()/".config/agent-vision-toolkit/env")]:
        try:
            for line in open(fp):
                line=line.strip()
                if line.startswith("ZEN_API_KEY"):
                    v=line.split("=",1)[1].strip().strip('"').strip("'")
                    if v: return v
        except: pass
    return os.environ.get("ZEN_API_KEY","")

def _delegate_via_deepseek(query: str, timeout=12):
    """让 deepseek-v4-flash-go (原生 web_search) 代搜，给 24 个无原生模型用。走本地 vision_proxy 127.0.0.1:19100，经它转发到 https://opencode.ai/zen/go，复用 ZEN_API_KEY，双路兼顾 VPN 开/关。"""
    import time as _time
    zen_key = _load_zen_key()
    if not zen_key:
        return None, "ZEN_API_KEY missing"
    payload = {
        "model": "deepseek-v4-flash-go",
        "input": [{"role":"user","content":[{"type":"input_text","text": query}]}],
        "tools": [{"type":"web_search"}],
        "store": False,
    }
    body = json.dumps(payload).encode()
    headers_base = {"Content-Type":"application/json", "Accept":"text/event-stream", "User-Agent":"websearch-delegate/1.0"}
    # 1) 走本地 vision_proxy（它会把 Authorization 换成真实 ZEN key 并选 GO_UPSTREAM）
    # 2) 直连 opencode.ai/zen/go 兜底
    targets = [
        ("http://127.0.0.1:19100/v1/responses", True),
        ("https://opencode.ai/zen/go/v1/responses", False),
    ]
    last_err = None
    for url, is_local in targets:
        for opener in (DIRECT_OPENER, SYSTEM_OPENER):
            try:
                hdrs = dict(headers_base)
                hdrs["Authorization"] = f"Bearer {zen_key}"
                req = urllib.request.Request(url, data=body, headers=hdrs, method="POST")
                with opener.open(req, timeout=timeout) as resp:
                    raw = resp.read().decode("utf-8", errors="replace")
                # 解析 Responses API：可能是 SSE 流或 JSON
                text_parts = []
                # 尝试 JSON 整体
                raw_stripped = raw.strip()
                if raw_stripped.startswith("{"):
                    try:
                        j=json.loads(raw_stripped)
                        for item in j.get("output",[]):
                            if isinstance(item, dict):
                                for c in item.get("content",[]):
                                    if isinstance(c, dict) and c.get("type")=="output_text" and c.get("text"):
                                        text_parts.append(c["text"])
                                if item.get("type")=="web_search_call":
                                    text_parts.append(f"[web_search_call] {json.dumps(item.get('action',{}), ensure_ascii=False)}")
                        if text_parts:
                            return "\n".join(text_parts), None
                    except: pass
                # SSE 解析
                for line in raw.split("\n"):
                    if line.startswith("data: "):
                        payload_s = line[6:].strip()
                        if not payload_s or payload_s=="[DONE]": continue
                        try:
                            j=json.loads(payload_s)
                            if j.get("type")=="response.output_text.delta" and j.get("delta"):
                                text_parts.append(j["delta"])
                            elif j.get("type")=="response.completed":
                                for it in j.get("response",{}).get("output",[]):
                                    for c in it.get("content",[]):
                                        if c.get("text"): text_parts.append(c["text"])
                        except: continue
                if text_parts:
                    return "".join(text_parts), None
                last_err = f"{url} empty response {raw[:400]}"
            except Exception as e:
                last_err = f"{url} {opener is DIRECT_OPENER and 'direct' or 'system'}: {e}"
                if opener is DIRECT_OPENER:
                    continue
                break
        # 换下一个 url 前如果已有结果就 break，外层也会 return
    return None, last_err

def send(msg):
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()

def select_provider(session_id: str) -> str:
    # mimic opencode checksum %2
    ov = os.environ.get("OPENCODE_WEBSEARCH_PROVIDER")
    if ov in ("exa", "parallel"):
        return ov
    h = hashlib.md5(session_id.encode()).hexdigest()[:8]
    try:
        val = int(h, 16) % 2
    except:
        val = 0
    return "exa" if val == 0 else "parallel"

def mcp_call(url: str, tool: str, args: dict, timeout=10, extra_headers=None):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":tool,"arguments":args}}).encode()
    headers = {"Content-Type":"application/json","Accept":"application/json, text/event-stream", "User-Agent":"opencode-websearch-mcp/1.0"}
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    # 先直连（绕过 Clash/SakuraCat 的 127.0.0.1 代理，修 VPN 502 同款问题），失败再走系统代理，兼顾有/无 VPN
    last_err = None
    for opener in (DIRECT_OPENER, SYSTEM_OPENER):
        try:
            with opener.open(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
            break
        except urllib.error.HTTPError as e:
            raw = e.read().decode("utf-8", errors="replace") if e.fp else ""
            break
        except Exception as e:
            last_err = e
            # 直连失败且还有下一个 opener 就重试，否则抛错
            if opener is DIRECT_OPENER:
                continue
            raise RuntimeError(f"HTTP error: {last_err}")
    else:
        raise RuntimeError(f"HTTP error: {last_err}")
    # parse MCP response: JSON or SSE data: lines
    raw = raw.strip()
    if not raw:
        return None
    # try direct JSON
    try:
        if raw.startswith("{"):
            j = json.loads(raw)
            content = j.get("result",{}).get("content",[])
            for item in content:
                if item.get("text"):
                    return item["text"]
    except: pass
    # SSE
    for line in raw.split("\n"):
        if line.startswith("data: "):
            payload = line[6:].strip()
            if not payload or not payload.startswith("{"):
                continue
            try:
                j = json.loads(payload)
                content = j.get("result",{}).get("content",[])
                for item in content:
                    if item.get("text"):
                        return item["text"]
            except: continue
    return None

def do_websearch(params: dict, session_id="default"):
    query = params.get("query") or params.get("objective") or ""
    if not query:
        raise ValueError("query required")
    numResults = int(params.get("numResults", 8))
    livecrawl = params.get("livecrawl", "fallback")
    typ = params.get("type", "auto")
    ctxMax = params.get("contextMaxCharacters")
    # 1) opencodex 代搜：让 deepseek-v4-flash-go 代搜，解决 24 个无原生模型问题
    try:
        d_query = f"Search the web for: {query}. Summarize top {numResults} results with titles, URLs, and snippets in Chinese."
        delegated, d_err = _delegate_via_deepseek(d_query)
        if delegated and len(delegated.strip()) > 30:
            return f"[delegate deepseek-v4-flash-go] {delegated.strip()}"
    except Exception as e:
        d_err = str(e)
        delegated = None
    # 2) 回退 Exa/Parallel 双路
    provider = select_provider(session_id)
    providers = [provider, "parallel" if provider=="exa" else "exa"]
    last_err = locals().get("d_err", "")
    for prov in providers:
        try:
            if prov == "parallel":
                result = mcp_call(PARALLEL_URL, "web_search", {
                    "objective": query,
                    "search_queries": [query],
                    "session_id": session_id,
                }, timeout=10, extra_headers={"User-Agent":"opencode/1.0"})
            else:
                args = {"query": query, "type": typ, "numResults": numResults, "livecrawl": livecrawl}
                if ctxMax is not None:
                    args["contextMaxCharacters"] = int(ctxMax)
                result = mcp_call(EXA_URL, "web_search_exa", args, timeout=10)
            if result:
                return f"[{prov}] {result}"
            last_err = f"{prov} returned empty; delegate: {d_err}" if 'd_err' in locals() and d_err else f"{prov} returned empty"
        except Exception as e:
            last_err = str(e) + (f"; delegate: {d_err}" if 'd_err' in locals() and d_err else "")
            continue
    return f"No search results found. Last error: {last_err}"

def do_webfetch(params: dict):
    # simple fetch via exa web_search_exa fallback to direct HTTP
    url = params.get("url") or params.get("query") or ""
    if not url:
        raise ValueError("url required")
    # try exa livecrawl preferred for fetch
    try:
        result = mcp_call(EXA_URL, "web_search_exa", {"query": url, "type":"auto", "numResults":1, "livecrawl":"preferred"}, timeout=10)
        if result:
            return result
    except: pass
    # fallback direct fetch - dual: direct then system proxy (VPN on/off both work)
    for opener in (DIRECT_OPENER, SYSTEM_OPENER):
        try:
            req = urllib.request.Request(url, headers={"User-Agent":"Mozilla/5.0"})
            with opener.open(req, timeout=10) as resp:
                data = resp.read().decode("utf-8", errors="replace")[:12000]
                return data if data else "Empty fetch"
        except Exception as e:
            if opener is DIRECT_OPENER:
                continue
            return f"Fetch failed: {e}"
    return "Fetch failed: both openers failed"

for line in sys.stdin:
    line=line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except:
        continue
    method = msg.get("method")
    req_id = msg.get("id")
    if method == "initialize":
        send({"jsonrpc":"2.0","id":req_id,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":False}},"serverInfo":{"name":"websearch","version":"1.0.0"}}})
    elif method == "notifications/initialized":
        pass
    elif method == "tools/list":
        send({"jsonrpc":"2.0","id":req_id,"result":{"tools":[
            {"name":"websearch","description":"Search the web for current info (for the 24 models without native search: mimo/glm/kimi/qwen/hy3/longcat/minimax/big-pickle etc). Native-search models (deepseek*4, vision*2, muse*2, luna, grok) should use hosted web_search instead. Supports livecrawl fallback/preferred, type auto/fast/deep, numResults 1-10. Hosted via Exa/Parallel MCP, no API key, ~10s timeout, bypasses system proxy.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Websearch query"},"numResults":{"type":"number","description":"Number of results (default 8)"},"livecrawl":{"type":"string","enum":["fallback","preferred"],"description":"Live crawl mode"},"type":{"type":"string","enum":["auto","fast","deep"],"description":"Search type"},"contextMaxCharacters":{"type":"number","description":"Max context chars (default 10000)"}},"required":["query"]}},
            {"name":"webfetch","description":"Fetch and extract content from a URL (via Exa livecrawl). Fallback to direct HTTP (bypasses proxy). Use for scraping a specific page.","inputSchema":{"type":"object","properties":{"url":{"type":"string","description":"URL to fetch"}},"required":["url"]}}
        ]}})
    elif method == "tools/call":
        tool = msg.get("params",{}).get("name")
        args = msg.get("params",{}).get("arguments",{}) or {}
        # session_id heuristic: use _meta or fallback
        session_id = str(msg.get("params",{}).get("_meta",{}).get("sessionId","default"))
        try:
            if tool == "websearch":
                out = do_websearch(args, session_id=session_id)
                send({"jsonrpc":"2.0","id":req_id,"result":{"content":[{"type":"text","text":out}]}})
            elif tool == "webfetch":
                out = do_webfetch(args)
                send({"jsonrpc":"2.0","id":req_id,"result":{"content":[{"type":"text","text":out}]}})
            else:
                send({"jsonrpc":"2.0","id":req_id,"error":{"code":-32601,"message":f"Unknown tool {tool}"}})
        except Exception as e:
            send({"jsonrpc":"2.0","id":req_id,"error":{"code":-32000,"message":str(e)}})
    elif method == "ping":
        send({"jsonrpc":"2.0","id":req_id,"result":{}})
