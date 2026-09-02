#!/usr/bin/env python3
"""MCP Server: Web Search via opencode hosted MCP (Exa/Parallel) - no API key required.
Ported from anomalyco/opencode packages/opencode/src/tool/websearch.ts + mcp-websearch.ts

Exposes:
- websearch(query, numResults=8, livecrawl=fallback, type=auto, contextMaxCharacters=10000)
- webfetch(url)  // simple fetch via exa

Only intended for the 24 models without native search (mimo/glm/kimi/qwen/hy3/etc).
The 7 native-search models (deepseek*4, vision*2, muse-go, luna) should use hosted web_search.
"""
import json, sys, hashlib, os
import urllib.request, urllib.error

EXA_URL = os.environ.get("EXA_API_KEY") and f"https://mcp.exa.ai/mcp?exaApiKey={os.environ['EXA_API_KEY']}" or "https://mcp.exa.ai/mcp"
PARALLEL_URL = "https://search.parallel.ai/mcp"

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

def mcp_call(url: str, tool: str, args: dict, timeout=25, extra_headers=None):
    body = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":tool,"arguments":args}}).encode()
    headers = {"Content-Type":"application/json","Accept":"application/json, text/event-stream", "User-Agent":"opencode-websearch-mcp/1.0"}
    if extra_headers:
        headers.update(extra_headers)
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace") if e.fp else ""
        # still try parse
    except Exception as e:
        raise RuntimeError(f"HTTP error: {e}")
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
    # choose provider
    provider = select_provider(session_id)
    # Try primary, fallback to other
    providers = [provider, "parallel" if provider=="exa" else "exa"]
    last_err = None
    for prov in providers:
        try:
            if prov == "parallel":
                result = mcp_call(PARALLEL_URL, "web_search", {
                    "objective": query,
                    "search_queries": [query],
                    "session_id": session_id,
                }, timeout=25, extra_headers={"User-Agent":"opencode/1.0"})
            else:
                args = {"query": query, "type": typ, "numResults": numResults, "livecrawl": livecrawl}
                if ctxMax is not None:
                    args["contextMaxCharacters"] = int(ctxMax)
                result = mcp_call(EXA_URL, "web_search_exa", args, timeout=25)
            if result:
                return f"[{prov}] {result}"
            last_err = f"{prov} returned empty"
        except Exception as e:
            last_err = str(e)
            continue
    return f"No search results found. Last error: {last_err}"

def do_webfetch(params: dict):
    # simple fetch via exa web_search_exa fallback to direct HTTP
    url = params.get("url") or params.get("query") or ""
    if not url:
        raise ValueError("url required")
    # try exa livecrawl preferred for fetch
    try:
        result = mcp_call(EXA_URL, "web_search_exa", {"query": url, "type":"auto", "numResults":1, "livecrawl":"preferred"}, timeout=25)
        if result:
            return result
    except: pass
    # fallback direct fetch
    try:
        req = urllib.request.Request(url, headers={"User-Agent":"Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = resp.read().decode("utf-8", errors="replace")[:12000]
            return data if data else "Empty fetch"
    except Exception as e:
        return f"Fetch failed: {e}"

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
            {"name":"websearch","description":"Search the web for current info (for the 24 models without native search: mimo/glm/kimi/qwen/hy3/longcat/minimax/big-pickle etc). Native-search models (deepseek*4, vision*2, muse*2, luna, grok) should use hosted web_search instead. Supports livecrawl fallback/preferred, type auto/fast/deep, numResults 1-10. Hosted via Exa/Parallel MCP, no API key, ~25s timeout.","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"Websearch query"},"numResults":{"type":"number","description":"Number of results (default 8)"},"livecrawl":{"type":"string","enum":["fallback","preferred"],"description":"Live crawl mode"},"type":{"type":"string","enum":["auto","fast","deep"],"description":"Search type"},"contextMaxCharacters":{"type":"number","description":"Max context chars (default 10000)"}},"required":["query"]}},
            {"name":"webfetch","description":"Fetch and extract content from a URL (via Exa livecrawl). Fallback to direct HTTP. Use for scraping a specific page.","inputSchema":{"type":"object","properties":{"url":{"type":"string","description":"URL to fetch"}},"required":["url"]}}
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
