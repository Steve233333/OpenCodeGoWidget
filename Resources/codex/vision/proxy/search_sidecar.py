"""联网旁路：合成 web_search、shell 网络调用的 sidecar。"""

from __future__ import annotations

import asyncio
import json
import os
import pathlib   # 2026-09-23 Phase 3：原单体文件漏了这行（被 except: pass 吞成静默失败）
import re
import urllib.error
import urllib.request

from .config import (
    _log,
)


def _inject_synthetic_web_search(parsed, model=None, go_route=False):
    """Inject synthetic web_search for all non-search Go models (无条件).

    接受后所有 mimo/glm/qwen/kimi 等都能通过 web_search 边车真搜
    （DuckDuckGo 直连 3s 优先，deepseek 兜底），不再依赖 Codex 是否下发了原生 web_search。
    """
    if not go_route or not isinstance(model, str):
        return False
    if model.startswith(("deepseek-", "gpt-5.6-luna", "muse-spark")):
        return False
    tools = parsed.get("tools")
    if not isinstance(tools, list):
        # Codex 没给 tools 列表（纯对话轮），为边车补一个
        parsed["tools"] = []
        tools = parsed["tools"]
    # 已有合成的就不再重复注入
    for t in tools:
        if isinstance(t, dict) and t.get("type") == "function" and t.get("name") == "web_search":
            return False
    synthetic = {
        "type": "function",
        "name": "web_search",
        "description": "Search the web for current information. Use this for news, weather, hot topics, or any question requiring recent/realtime data. Always prefer this over shell/Browser for web content.",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query, e.g. 'today news' or 'weather Shanghai'"},
                "count": {"type": "integer", "description": "Number of results (1-10)", "minimum": 1, "maximum": 10}
            },
            "required": ["query"],
            "additionalProperties": False
        }
    }
    # 将原生 web_search（若有）替换为合成，或直接追加
    new_tools = []
    replaced = False
    for t in tools:
        if isinstance(t, dict) and t.get("type") == "web_search":
            if not replaced:
                new_tools.append(synthetic)
                replaced = True
            # 跳过原生，保留合成一个
        else:
            new_tools.append(t)
    if not replaced:
        new_tools.append(synthetic)
    parsed["tools"] = new_tools
    _log(f"[vision-proxy] injected synthetic web_search for {model} sidecar (unconditional)")
    return True


async def _perform_web_search(query, zen_key=None):
    """只走 deepseek 代搜，给非联网模型用，不再直连 Google/DuckDuckGo。"""
    # 兜底取 key
    if not zen_key:
        zen_key = os.environ.get("ZEN_API_KEY", "")
        if not zen_key:
            try:
                for fp in ["/Users/steve233/.config/agent-vision-toolkit/env", str(pathlib.Path.home() / ".config/agent-vision-toolkit/env")]:
                    for line in open(fp):
                        line = line.strip()
                        if line.startswith("ZEN_API_KEY"):
                            v = line.split("=", 1)[1].strip().strip('"').strip("'")
                            if v:
                                zen_key = v
                                break
                    if zen_key:
                        break
            except:
                pass
    if not zen_key:
        _log(f"[vision-proxy] _perform_web_search no ZEN_API_KEY for query='{query[:30]}'")
        return f"Search for '{query}' failed: ZEN_API_KEY missing"
    # 只走 deepseek-v4-flash-go 代搜
    try:
        # 2026-09-05 修复：直连上游要用裸 id deepseek-v4-flash（-go 是本代理内部约定，
        # 网关不认识会 401 ModelError）；本地自调保留 -go（代理自己剥后缀）。
        # 超时 15s→60s：deepseek 代搜实测 ~28s，15s 必超时（omen P6 实锤）。
        _delegate_local = {
            "model": "deepseek-v4-flash-go",
            "input": [{"role": "user", "content": [{"type":"input_text","text": f"Search the web for: {query}. Summarize top 5 results concisely in Chinese."}]}],
            "tools": [{"type": "web_search"}],
            "stream": False,
            "store": False
        }
        _delegate_direct = dict(_delegate_local, model="deepseek-v4-flash")
        data_local = json.dumps(_delegate_local).encode()
        data_direct = json.dumps(_delegate_direct).encode()
        # 双路：先本地 19100（走 vision_proxy 转发，自动换真实 key），不通直连 zen/go
        last_err = None
        for url, is_local, data in [("http://127.0.0.1:19100/v1/responses", True, data_local), ("https://opencode.ai/zen/go/v1/responses", False, data_direct)]:
            for opener in (urllib.request.build_opener(urllib.request.ProxyHandler({})), urllib.request.build_opener()):
                try:
                    req = urllib.request.Request(url, data=data, method="POST")
                    req.add_header("Authorization", f"Bearer {zen_key}")
                    req.add_header("Content-Type", "application/json")
                    req.add_header("Accept", "application/json, text/event-stream")
                    req.add_header("User-Agent", "vision-proxy-delegate/1.0")

                    def do_search():
                        with opener.open(req, timeout=60) as resp:
                            body = resp.read().decode("utf-8", errors="replace")
                            # 先试 JSON 整包
                            stripped = body.strip()
                            if stripped.startswith("{"):
                                try:
                                    obj = json.loads(stripped)
                                    output = obj.get("output", [])
                                    texts = []
                                    for item in output:
                                        if item.get("type") == "message":
                                            for part in item.get("content", []):
                                                if part.get("type") == "output_text":
                                                    texts.append(part.get("text", ""))
                                        if item.get("type") == "web_search_call":
                                            texts.append(f"[web_search_call] {json.dumps(item.get('action', {}), ensure_ascii=False)}")
                                    if texts:
                                        return "\n".join(texts)
                                except:
                                    pass
                            # SSE
                            texts = []
                            for line in body.split("\n"):
                                if line.startswith("data: "):
                                    p = line[6:].strip()
                                    if not p or p == "[DONE]":
                                        continue
                                    try:
                                        j = json.loads(p)
                                        if j.get("type") == "response.output_text.delta" and j.get("delta"):
                                            texts.append(j["delta"])
                                        elif j.get("type") == "response.completed":
                                            for it in j.get("response", {}).get("output", []):
                                                for c in it.get("content", []):
                                                    if c.get("text"):
                                                        texts.append(c["text"])
                                    except:
                                        continue
                            if texts:
                                return "".join(texts)
                            return body[:3000]

                    result = await asyncio.to_thread(do_search)
                    if result and len(result.strip()) > 30:
                        _log(f"[vision-proxy] delegate deepseek success via {url} query='{query[:30]}' len={len(result)}")
                        return result
                    last_err = f"{url} empty"
                except Exception as e:
                    last_err = f"{url} {e!r}"
                    _log(f"[vision-proxy] delegate failed {url} opener={'direct' if 'ProxyHandler' in str(type(opener)) else 'system'}: {e!r}")
                    if "ProxyHandler" in str(type(opener)):
                        continue
                    break
        _log(f"[vision-proxy] delegate all failed query='{query[:30]}' last_err={last_err}")
        return f"Search for '{query}' failed: delegate all targets failed ({last_err})"
    except Exception as e:
        _log(f"[vision-proxy] sidecar deepseek failed: {e!r}")
        return f"Search for '{query}' failed: {e!r}"


def _is_web_search_tool_call(item):
    """Check if a function_call item is a web_search sidecar call."""
    if not isinstance(item, dict):
        return False
    if item.get("type") == "web_search_call":
        return True
    if item.get("type") == "function_call" and item.get("name") == "web_search":
        return True
    return False


def _is_shell_network_call(item):
    """Detect shell calls that try to fetch web content (curl/wget with URL)."""
    if not isinstance(item, dict) or item.get("type") != "function_call":
        return False
    if item.get("name") != "shell":
        return False
    args = item.get("arguments")
    if not isinstance(args, str):
        return False
    # Check for curl/wget with http
    if "curl" in args or "wget" in args:
        if "http://" in args or "https://" in args:
            return True
    # Check for URLs directly in shell command
    if re.search(r"https?://[^\s\"']+", args):
        return True
    return False


async def _handle_shell_network_sidecar(item, zen_key=None):
    """Handle shell network calls by performing HTTP fetch via proxy (bypass sandbox).

    Extract URLs from shell command, fetch them, and return results as if the shell succeeded.
    """
    args = item.get("arguments", "")
    try:
        args_obj = json.loads(args) if isinstance(args, str) else args
        cmd = args_obj.get("cmd", "") if isinstance(args_obj, dict) else str(args)
    except:
        cmd = str(args)
    urls = re.findall(r"https?://[^\s\"'<>]+", cmd)
    if not urls:
        return None
    # Fetch first URL (for t now, handle one)
    url = urls[0].rstrip('"\';')
    # Clean up URL (remove trailing | head etc.)
    url = url.split("|")[0].strip().split()[0].strip('"\';')
    _log(f"[vision-proxy] shell network sidecar for {url}")
    try:
        def fetch():
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"})
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(req, timeout=10) as resp:
                content = resp.read().decode(errors="replace")
                # Truncate to avoid huge output
                if len(content) > 8000:
                    content = content[:8000] + "\n...[truncated]"
                return content
        content = await asyncio.to_thread(fetch)
        if content and len(content) > 50:
            _log(f"[vision-proxy] shell sidecar success {url} len={len(content)}")
            return f"Fetched {url} (via sidecar, bypassing sandbox):\n{content[:6000]}"
    except Exception as e:
        _log(f"[vision-proxy] shell sidecar failed {url}: {e!r}")
        return f"Failed to fetch {url} via sidecar: {e}. Try using web_search tool instead for search."
    return None


def _normalize_web_search_call(parsed):
    """Rewrite history web_search_call items to the gateway's accepted action shape.

    Official DeepSeek (supports_search_tool=true) writes web_search_call history
    items with the OpenAI-standard action {"type":"web_search"}. The Go gateway's
    native responses path for deepseek-* models only accepts
    {"type":"search"|"open_page"|"find_in_page"} and rejects the whole request
    with `input: unknown variant 'web_search'` 400 when such history is replayed
    after switching models. Rewriting web_search -> search + queries keeps the
    search results (output) intact and passes the gateway's serde validation.

    2026-08-20: extend to dual-field for cross-model reuse (DeepSeek 670-item
    history -> Muse/Luna). Go strict validates `query: string` required; DeepSeek
    history has `queries: string[]` only. Ensure both `query` and `queries` are
    present to satisfy both families.
    """
    input_items = parsed.get("input")
    if not isinstance(input_items, list):
        return False
    changed = False
    for item in input_items:
        if not isinstance(item, dict) or item.get("type") != "web_search_call":
            continue
        action = item.get("action")
        if not isinstance(action, dict):
            continue
        # 1) web_search -> search (Go gateway)
        if action.get("type") == "web_search":
            queries = action.get("queries")
            if not queries:
                query = item.get("search_query") or action.get("query") or "search"
                queries = [query] if isinstance(query, str) else ["search"]
            action["type"] = "search"
            action["queries"] = queries
            changed = True
        # 2) dual-field for cross-model reuse: ensure query <-> queries
        if isinstance(action.get("queries"), list) and not isinstance(action.get("query"), str):
            qs = action["queries"]
            if qs and isinstance(qs[0], str):
                action["query"] = qs[0]
                changed = True
            elif not qs:
                action["query"] = item.get("search_query") or "search"
                action["queries"] = [action["query"]]
                changed = True
        elif isinstance(action.get("query"), str) and not isinstance(action.get("queries"), list):
            action["queries"] = [action["query"]]
            changed = True
        elif not isinstance(action.get("query"), str) and not isinstance(action.get("queries"), list):
            # neither present -> fallback
            fallback = item.get("search_query") or "search"
            action["query"] = fallback
            action["queries"] = [fallback]
            changed = True
    if changed:
        _log("[vision-proxy] normalized web_search_call action(s) to gateway format for zen/go (dual-field)")
    return changed
