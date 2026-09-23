"""HTTP 服务本体：Proxy 类（路由/上游转发/重写）+ main() 入口。"""

from __future__ import annotations

from http import HTTPStatus
import argparse
import asyncio
import json
import os
import signal
import socket
import time
import urllib.error
import urllib.request
import uuid

from .apply_patch import (
    _rewrite_apply_patch_response_json,
    _rewrite_apply_patch_tool,
)
from .bridges_chat import (
    ChatBridgeTranslator,
    _build_chat_fallback_json,
    _oc_session_id,
    _responses_request_to_chat,
)
from .bridges_messages import (
    MessagesBridgeTranslator,
    _build_messages_fallback_json,
    _responses_request_to_messages,
)
from .config import (
    CODEX_HEADERS,
    DIRECT_OPENER,
    GO_SUFFIX,
    GO_UPSTREAM,
    HOP_HEADERS,
    MESSAGES_ALWAYS_BRIDGE,
    MUSE_MAX_STALL_RETRIES,
    RESPONSES_ALWAYS_BRIDGE,
    RESPONSES_FALLBACK_MODELS,
    TERMINAL_GRACE_SECONDS,
    TERMINAL_IDLE_MAX_ROUNDS,
    ZEN_SUFFIX,
    ZEN_UPSTREAM,
    _ANTHROPIC_VERSION,
    _BRIDGE_NONSTREAM_MAX_BYTES,
    _RESPONSES_BROKEN_UNTIL,
    _RESPONSES_FALLBACK_TTL,
    _UPSTREAM_TRANSIENT_STATUS,
    _clamp_reasoning_effort,
    _log,
    load_env_file,
    normalize_route_model,
)
from .muse import (
    _build_muse_retry_body,
    _inject_muse_no_preamble,
    _inject_muse_tool_first,
    _is_muse_model,
    _muse_flag,
    _muse_retry_allowed,
    _sanitize_muse_tool_schemas,
)
from .search_sidecar import (
    _inject_synthetic_web_search,
    _is_web_search_tool_call,
    _normalize_web_search_call,
    _perform_web_search,
)
from .sse import (
    _complete_sse_frame,
    _flush_apply_patch,
    _rewrite_sse_body,
    _rewrite_sse_frame,
    _split_sse_frame,
    _sse_looks_like_stall,
    sse_turn_looks_complete,
)
from .toolfix import (
    _fix_tool_required,
    _intercept_unsupported_history,
    _normalize_fc_args_history,
    _sanitize_input_ids,
)


def _rewrite_zen_model(parsed):
    """Strip the trailing "-zen" suffix for Zen free models. Returns True if the
    body was rewritten so the caller re-serializes it.

    2026-09-23：也认 `opencode-zen/<slug>` 这种 provider 前缀（与后缀等价）。
    """
    raw = parsed.get("model")
    model = normalize_route_model(raw)
    if not isinstance(model, str) or not model.endswith(ZEN_SUFFIX):
        return False
    bare = model[: -len(ZEN_SUFFIX)]
    ZEN_ALIASES = {"ox-alpha": "x-preview-f-free"}
    mapped = ZEN_ALIASES.get(bare, bare)
    parsed["model"] = mapped
    _log(f"[vision-proxy] zen model compat {raw} -> {parsed['model']}" + (f" (alias {bare} -> {mapped})" if mapped != bare else ""))
    return True


def _normalize_assistant_content(parsed):
    """Collapse assistant message content arrays into a plain string.

    The opencode.ai Zen/Go gateway converts Responses messages to chat
    format for chat-adapted models (mimo/glm/kimi/hy3); an assistant message
    whose content is a list of output_text parts makes the upstream chat
    schema reject the whole request with 400. Native-Responses models
    (deepseek flash/pro, official direct) accept both forms, so this
    normalization is safe for every zen/go request.
    """
    input_items = parsed.get("input")
    if not isinstance(input_items, list):
        return False
    changed = False
    for item in input_items:
        if not isinstance(item, dict) or item.get("role") != "assistant":
            continue
        content = item.get("content")
        if not isinstance(content, list):
            continue
        parts = []
        for part in content:
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                parts.append(part["text"])
        item["content"] = "".join(parts)
        changed = True
    if changed:
        _log("[vision-proxy] collapsed assistant content array(s) to string for zen/go chat conversion")
    return changed


def _rewrite_go_model(parsed):
    # 2026-09-23：也认 `opencode-go/<slug>` 这种 provider 前缀（与后缀等价）
    raw = parsed.get("model")
    model = normalize_route_model(raw)
    if not isinstance(model, str) or not model.endswith(GO_SUFFIX):
        return False
    bare = model[: -len(GO_SUFFIX)]
    # Friendly alias: ox-alpha-go -> ox-alpha-free (Go upstream id is ox-alpha-free; Zen is x-preview-f-free)
    GO_ALIASES = {"ox-alpha": "ox-alpha-free"}
    mapped = GO_ALIASES.get(bare, bare)
    parsed["model"] = mapped
    _log(f"[vision-proxy] go model compat {raw} -> {parsed['model']}" + (f" (alias {bare} -> {mapped})" if mapped != bare else ""))
    return True


class _BufferedResponse:
    """把已经读完的响应体伪装成上游响应，让流式管线照常消费（重发后要走同一条路）。"""

    def __init__(self, status, headers, body):
        self.status = status
        self.headers = headers
        self._body = body
        self._pos = 0

    def read(self, n=-1):
        if n is None or n < 0:
            chunk = self._body[self._pos:]
            self._pos = len(self._body)
            return chunk
        chunk = self._body[self._pos:self._pos + n]
        self._pos += len(chunk)
        return chunk

    def close(self):
        pass


def _header_value(headers, name):
    return next((value for key, value in headers if key.lower() == name.lower()), None)


def _rewrite_model_compat(parsed):
    if parsed.get("model") != "gpt-5.2":
        return False
    parsed["model"] = "deepseek-v4-flash"
    _log("[vision-proxy] model compatibility gpt-5.2 -> deepseek-v4-flash")
    return True


def _inject_reasoning_summaries(text):
    """Optional compatibility transform; disabled by default."""
    text = text.replace("\r\n", "\n")
    blocks = text.split("\n\n")
    parsed, items = [], {}
    for block in blocks:
        data = next((line[5:].strip() for line in block.splitlines() if line.startswith("data:")), None)
        try:
            obj = json.loads(data) if data else None
        except json.JSONDecodeError:
            obj = None
        parsed.append((obj, block))
        if not obj:
            continue
        kind = obj.get("type")
        if kind == "response.output_item.added":
            item = obj.get("item") or {}
            if item.get("type") == "reasoning" and item.get("id"):
                items[item["id"]] = ""
        elif kind == "response.reasoning_text.delta" and obj.get("item_id") in items:
            items[obj["item_id"]] += obj.get("delta", "")
        elif kind == "response.reasoning_text.done" and obj.get("item_id") in items:
            items[obj["item_id"]] = obj.get("text", items[obj["item_id"]])
    output = []
    for obj, block in parsed:
        if obj and obj.get("type") == "response.output_item.done":
            item = obj.get("item") or {}
            reasoning = items.get(item.get("id"), "")
            if item.get("type") == "reasoning" and reasoning:
                fixed = json.loads(json.dumps(obj))
                fixed["item"]["summary"] = [{"type": "summary_text", "text": reasoning}]
                block = "event: response.output_item.done\ndata: " + json.dumps(fixed, ensure_ascii=False)
        output.append(block)
    return "\n\n".join(output)


class Proxy:
    def __init__(self, port, upstream, log_path, codex_header_compat=False,
                 inject_reasoning_summary=False):
        self.port = port
        self.upstream = upstream.rstrip("/")
        self.codex_header_compat = codex_header_compat
        self.inject_reasoning_summary = inject_reasoning_summary
        os.environ["VISION_LOG_FILE"] = log_path

    def _upstream_headers(self, incoming):
        headers = []
        for key, value in incoming:
            lower = key.lower()
            if lower in HOP_HEADERS:
                continue
            if self.codex_header_compat and (lower in CODEX_HEADERS or lower.startswith("x-codex-")):
                continue
            headers.append((key, value))
        if self.codex_header_compat:
            headers.append(("User-Agent", "python-urllib/3"))
        headers.append(("Connection", "close"))
        # P6-lite hardening: Cloudflare error 1010 blocks python-urllib user agents.
        # Never leak them upstream (local scripts/tests would all fail with 403).
        cleaned = []
        for key, value in headers:
            if key.lower() == "user-agent" and value.lower().startswith("python-urllib"):
                value = "vision-proxy/1.0"
            cleaned.append((key, value))
        return cleaned

    async def handle(self, reader, writer):
        response = None
        response_started = False
        txn = {"t0": time.monotonic(), "method": "?", "path": "?", "model": "-",
               "route": "direct", "status": None, "bridge": None}
        try:
            request_head = await self._read_head(reader)
            if request_head is None:
                return
            request_line, incoming_headers, body_start = request_head
            method, path, _ = request_line.split(" ", 2)
            txn["method"], txn["path"] = method, path
            try:
                content_length = int(_header_value(incoming_headers, "content-length") or 0)
            except ValueError:
                await self._send_error(writer, 400, "invalid Content-Length")
                return
            body = bytearray(body_start)
            while len(body) < content_length:
                chunk = await reader.read(min(65536, content_length - len(body)))
                if not chunk:
                    break
                body.extend(chunk)
            if len(body) < content_length:
                await self._send_error(writer, 400, "incomplete request body")
                return
            parsed = None
            if body:
                try:
                    parsed = json.loads(bytes(body))
                except json.JSONDecodeError:
                    pass
            if isinstance(parsed, dict):
                model_changed = _rewrite_model_compat(parsed)
                zen_changed = _rewrite_zen_model(parsed)
                go_changed = _rewrite_go_model(parsed)
                tools_changed = _rewrite_apply_patch_tool(parsed)
                model = parsed.get("model") if isinstance(parsed, dict) else None
                synth_changed = (zen_changed or go_changed) and _inject_synthetic_web_search(parsed, model, go_changed)
                # Proactive sidecar: for non-search models that now have synthetic web_search, if user asks to search, pre-fetch
                proactive_changed = False
                if go_changed and model:
                    is_search_capable = isinstance(model, str) and model.startswith(("deepseek-", "gpt-5.6-luna", "muse-spark"))
                    if not is_search_capable:
                        last_text = ""
                        for it in reversed(parsed.get("input", []) or []):
                            if isinstance(it, dict) and it.get("role") == "user":
                                for part in it.get("content", []) or []:
                                    if isinstance(part, dict) and part.get("type") == "input_text" and isinstance(part.get("text"), str):
                                        last_text = part["text"]
                                        break
                                if last_text:
                                    break
                        has_synth = any(isinstance(t, dict) and t.get("type") == "function" and t.get("name") == "web_search" for t in parsed.get("tools", []) or [])
                        has_native = any(isinstance(t, dict) and t.get("type") == "web_search" for t in parsed.get("tools", []) or [])
                        _log(f"[vision-proxy] sidecar check model={model} go={go_changed} has_synth={has_synth} has_native={has_native} text='{last_text[:30]}' stream={parsed.get('stream')}")
                        if last_text and (has_synth or has_native) and any(kw in last_text.lower() for kw in ["搜", "搜索", "新闻", "search", "news", "天气", "weather", "热点", "热榜", "today"]):
                            try:
                                # REAL search for BOTH stream and non-stream: inject results before upstream so
                                # the model answers directly instead of calling web_search (which would 400 / sandbox-fail).
                                zen_key = os.environ.get("ZEN_API_KEY")
                                try:
                                    search_res = await asyncio.wait_for(_perform_web_search(last_text, zen_key), timeout=25.0)
                                except asyncio.TimeoutError:
                                    _log(f"[vision-proxy] proactive real search timeout for {model}, using hint")
                                    search_res = ""
                                if search_res and len(search_res) > 60:
                                    parsed["input"].append({
                                        "type": "message",
                                        "role": "user",
                                        "content": [{"type": "input_text", "text": f"[web_search sidecar] 已为你实时搜索完成，直接基于以下搜索结果回答：\n{search_res[:4000]}"}]
                                    })
                                    proactive_changed = True
                                    _log(f"[vision-proxy] proactive REAL search injected for {model} query='{last_text[:30]}' len={len(search_res)}")
                                else:
                                    placeholder = f"Web search is available for '{last_text[:50]}'. You have real-time search capability via the web_search tool. Please use web_search to search and then summarize. Do not claim you have no search ability."
                                    parsed["input"].append({
                                        "type": "message",
                                        "role": "user",
                                        "content": [{"type": "input_text", "text": f"[web_search sidecar] {placeholder}"}]
                                    })
                                    proactive_changed = True
                                    _log(f"[vision-proxy] proactive sidecar hint injected for {model} query='{last_text[:30]}' (search empty)")
                            except Exception as e:
                                _log(f"[vision-proxy] proactive sidecar failed: {e!r}")
                wsc_changed = (zen_changed or go_changed) and _normalize_web_search_call(parsed)
                ac_changed = (zen_changed or go_changed) and _normalize_assistant_content(parsed)
                fca_changed = (zen_changed or go_changed) and _normalize_fc_args_history(parsed)
                id_changed = (zen_changed or go_changed) and _sanitize_input_ids(parsed)
                req_changed = (zen_changed or go_changed) and _fix_tool_required(parsed)
                # 2026-09-20：Muse(Meta 后端) 专属兼容（muse-codex-compat skill）。
                # 三条都自带 model 网关，其他模型的 payload 保持字节不变。
                muse_schema_changed = (zen_changed or go_changed) and _sanitize_muse_tool_schemas(parsed)
                muse_preamble_changed = (zen_changed or go_changed) and _inject_muse_no_preamble(parsed)
                muse_first_changed = (zen_changed or go_changed) and _inject_muse_tool_first(parsed)
                # reasoning clamp: generic high fallback, hand-written registry, zero probe
                reasoning_changed = False
                if isinstance(parsed, dict) and isinstance(parsed.get("reasoning"), dict):
                    eff = parsed["reasoning"].get("effort")
                    if isinstance(eff, str) and eff:
                        clamped = _clamp_reasoning_effort(parsed.get("model"), eff)
                        if clamped != eff:
                            parsed["reasoning"]["effort"] = clamped
                            reasoning_changed = True
                if model_changed or zen_changed or go_changed or tools_changed or synth_changed or proactive_changed or wsc_changed or ac_changed or fca_changed or id_changed or req_changed or reasoning_changed or muse_schema_changed or muse_preamble_changed or muse_first_changed:
                    body = bytearray(json.dumps(parsed).encode())
            model = parsed.get("model") if isinstance(parsed, dict) else None
            zen_route = isinstance(parsed, dict) and zen_changed
            go_route = isinstance(parsed, dict) and go_changed
            self._last_model = model
            txn["model"] = model or "-"
            txn["route"] = "go" if go_route else ("zen" if zen_route else "direct")
            _log(f"[vision-proxy] request {method} {path} model={model} body_bytes={len(body)} zen={zen_route} go={go_route}")
            # intercept search=true history -> search=false model (preserve integrity)
            if go_route and _intercept_unsupported_history(parsed, model):
                txn["status"] = 400
                await self._send_error(
                    writer,
                    400,
                    "Cross-model history blocked: target model does not support web_search (mimo/GLM/Zen free). "
                    "History contains web_search_call from previous DeepSeek/Luna/Muse session. "
                    "Please start a new session for this model to preserve context integrity. "
                    f"Model={model} go_route={go_route}",
                )
                return
            if zen_route or go_route:
                zen_key = os.environ.get("ZEN_API_KEY")
                if not zen_key:
                    await self._send_error(writer, 502, "ZEN_API_KEY not set in env file")
                    return
                if go_route:
                    upstream = GO_UPSTREAM + ("" if path.startswith("/v1") else "/v1")
                else:
                    upstream = ZEN_UPSTREAM + ("" if path.startswith("/v1") else "/v1")
                headers = self._upstream_headers(incoming_headers)
                headers = [(k, f"Bearer {zen_key}") if k.lower() == "authorization" else (k, v) for k, v in headers]
                # 2026-09-19：客户端没带 Authorization 时必须补上，不能裸奔。
                # 上游实测可区分两种 401：无 Authorization -> "Missing API key."，
                # 错误 key -> "Invalid API key."（都带 cf-ray）。Codex 那侧只要 config.toml
                # 缺 experimental_bearer_token（或被「清除」过 / 用的是没读这份 config 的副本），
                # 就会发一个没有 Authorization 的请求，以前代理原样转发 → 用户看到
                # 401 Missing API key。go/zen 路由的上游凭据本来就固定是 ZEN_API_KEY，
                # 所以缺了直接补。
                if not any(k.lower() == "authorization" for k, _ in headers):
                    headers.append(("Authorization", f"Bearer {zen_key}"))
                # 2026-09-17：官方开始强制 x-opencode-session（缺了直接 400 MissingSessionID，
                # chat 端点实测也中招，会把 chat 桥一起打死），Codex 不会发这个头，由代理补。
                if not any(k.lower() == "x-opencode-session" for k, _ in headers):
                    headers.append(("x-opencode-session", _oc_session_id(parsed)))
            else:
                upstream = self.upstream
                headers = self._upstream_headers(incoming_headers)
            is_responses_path = path.split("?")[0].rstrip("/").endswith("/responses")
            bridge_eligible = (
                (go_route or zen_route)
                and isinstance(parsed, dict)
                and is_responses_path
            )
            # known chat-adapted models get instant fallback if TTL cached
            bridge_cached = bridge_eligible and model in RESPONSES_FALLBACK_MODELS and time.monotonic() < _RESPONSES_BROKEN_UNTIL.get(model, 0.0)
            always_bridge = bridge_eligible and model in RESPONSES_ALWAYS_BRIDGE
            messages_now = bridge_eligible and model in MESSAGES_ALWAYS_BRIDGE
            fallback_now = False
            upstream_status = 0
            if messages_now:
                # 只认 Anthropic Messages 格式的模型：/responses 必 500，不浪费这一次探测
                fallback_now = True
            elif always_bridge:
                fallback_now = True
            elif bridge_cached:
                fallback_now = True
            else:
                response = await self._open_upstream(method, path, bytes(body), headers, upstream)
                upstream_status = getattr(response, "status", None) or getattr(response, "code", 0) or 0
                # 2026-09-10：网关把「Model X is not supported for format openai」从 500 改成 401
                # （kimi-k3 实测），已知 chat 适配模型在 /responses 上吃 401 也要切桥；
                # 未登记模型仍只在 5xx 时切，避免把真正的鉴权失败吞成桥接。
                needs_bridge = upstream_status >= 500 or (
                    upstream_status == 401 and model in RESPONSES_FALLBACK_MODELS)
                if bridge_eligible and needs_bridge:
                    if model not in RESPONSES_FALLBACK_MODELS:
                        _log(f"[vision-proxy] auto-bridge new model {model} on {upstream_status} (not in RESPONSES_FALLBACK_MODELS)")
                    else:
                        _log(f"[vision-proxy] bridge on {upstream_status} for chat-adapted model {model}")
                    fallback_now = True
            if fallback_now:
                if response is not None:
                    try:
                        response.close()
                    except Exception:
                        pass
                    response = None
                if messages_now:
                    bridged = await self._messages_bridge_attempt(
                        writer, parsed, model, path, headers, upstream, txn,
                        reason="messages-only model")
                    if bridged:
                        return
                    txn["status"], txn["bridge"] = 502, "messages-fallback-failed"
                    await self._send_error(
                        writer, 502,
                        f"Anthropic Messages fallback failed for {model} "
                        f"(Go gateway exposes this model only on /v1/messages)",
                    )
                    return
                chat_payload = _responses_request_to_chat(parsed)
                chat_body = json.dumps(chat_payload).encode()
                fwd_headers = [(k, v) for k, v in headers if k.lower() not in ("content-length", "accept-encoding")]
                chat_path = "/v1/chat/completions" if path.startswith("/v1") else "/chat/completions"
                chat_resp = await self._open_chat_upstream(chat_path, chat_body, fwd_headers, upstream, model)
                try:
                    chat_status = getattr(chat_resp, "status", None) or getattr(chat_resp, "code", 0) or 0
                    if chat_status >= 400:
                        err_text = ""
                        try:
                            err_text = (await asyncio.to_thread(chat_resp.read)).decode(errors="replace")[:300]
                        except Exception:
                            pass
                        # 2026-09-17：chat 也失败时再给 messages 一次机会（Anthropic-only 模型）
                        if await self._messages_bridge_attempt(
                                writer, parsed, model, path, headers, upstream, txn,
                                reason=f"chat {chat_status}"):
                            return
                        txn["status"], txn["bridge"] = 502, "chat-fallback-failed"
                        _log(f"[vision-proxy] responses->chat fallback FAILED model={model} "
                             f"upstream_status={upstream_status} chat_status={chat_status} err={err_text[:120]}")
                        await self._send_error(
                            writer, 502,
                            f"Go gateway /responses broken ({upstream_status}) and chat fallback failed "
                            f"({chat_status}) for {model}: {err_text}",
                        )
                        return
                    _RESPONSES_BROKEN_UNTIL[model] = time.monotonic() + _RESPONSES_FALLBACK_TTL
                    txn["status"], txn["bridge"] = 200, "chat-fallback"
                    _log(f"[vision-proxy] responses->chat fallback engaged model={model} "
                         f"upstream_status={upstream_status} chat_status={chat_status}")
                    await self._send_chat_bridge(writer, chat_resp, parsed, model, txn)
                finally:
                    try:
                        chat_resp.close()
                    except Exception:
                        pass
                return
            # Sidecar: handle web_search calls from non-search models (mimo/glm etc.)
            # If the primary model called synthetic web_search, delegate to deepseek and synthesize tool result
            if not fallback_now and go_route and model and not model.startswith(("deepseek-", "gpt-5.6-luna", "muse-spark")):
                # Peek at response body for web_search calls (only for JSON non-stream for now)
                try:
                    ctype = response.headers.get("Content-Type", "") if hasattr(response, "headers") else ""
                    if "application/json" in ctype and not response.headers.get("Content-Encoding"):
                        body_bytes = await asyncio.to_thread(response.read)
                        # Try to parse as JSON
                        try:
                            obj = json.loads(body_bytes.decode(errors="replace"))
                            # Check if output contains web_search function_call
                            has_ws = False
                            ws_query = None
                            ws_call_id = None
                            for item in obj.get("output", []):
                                if _is_web_search_tool_call(item):
                                    has_ws = True
                                    # Extract query from arguments
                                    args = item.get("arguments") or item.get("input") or "{}"
                                    try:
                                        args_obj = json.loads(args) if isinstance(args, str) else args
                                        ws_query = args_obj.get("query") or args_obj.get("q") or "news"
                                        ws_call_id = item.get("call_id") or item.get("id")
                                    except:
                                        ws_query = "news"
                                    break
                            if has_ws and ws_query:
                                _log(f"[vision-proxy] sidecar web_search detected model={model} query='{ws_query[:30]}', delegating to deepseek")
                                zen_key = os.environ.get("ZEN_API_KEY")
                                search_result = await _perform_web_search(ws_query, zen_key)
                                # Synthesize a new response that includes the search results as tool output
                                # Create a new output with the search results
                                search_output = {
                                    "type": "function_call_output",
                                    "call_id": ws_call_id,
                                    "output": search_result
                                }
                                # Also add a message with the results for the model to see in next turn
                                # For now, return a direct response with search results
                                synthetic = {
                                    "id": obj.get("id", "resp_" + uuid.uuid4().hex[:24]),
                                    "object": "response",
                                    "created_at": int(time.time()),
                                    "status": "completed",
                                    "model": model,
                                    "output": [
                                        {"id": "msg_" + uuid.uuid4().hex[:24], "type": "message", "status": "completed", "role": "assistant", "content": [{"type": "output_text", "text": f"Search results for '{ws_query}':\n{search_result}", "annotations": []}]},
                                        search_output
                                    ],
                                    "error": None,
                                    "usage": obj.get("usage")
                                }
                                body_bytes = json.dumps(synthetic).encode()
                                await self._write_head(writer, 200, [("Content-Type", "application/json")], len(body_bytes))
                                writer.write(body_bytes)
                                await writer.drain()
                                response_started = True
                                txn["status"] = 200
                                txn["bridge"] = "web-search-sidecar"
                                # Close original response and return
                                try:
                                    response.close()
                                except:
                                    pass
                                return
                        except Exception as e:
                            _log(f"[vision-proxy] sidecar check failed: {e!r}")
                        # If not handled, fall through to normal send
                        # Need to restore response for normal handling - we already consumed it, so we need to recreate
                        # For now, just send the original body
                        await self._write_head(writer, getattr(response, "status", 200), list(response.headers.items()), len(body_bytes))
                        writer.write(body_bytes)
                        await writer.drain()
                        response_started = True
                        txn["status"] = getattr(response, "status", 200)
                        return
                except Exception as e:
                    _log(f"[vision-proxy] sidecar outer failed: {e!r}")

            # For non-search models that called web_search via synthetic tool, handle the search here
            # This handles both direct and bridge cases where the model returns a web_search function_call
            # We need to check if the response is a web_search call and handle it via sidecar
            # For now, handle the simple case where the response is JSON with web_search
            try:
                ctype = response.headers.get("Content-Type", "") if hasattr(response, "headers") else ""
                if "application/json" in ctype and go_route and model and not model.startswith(("deepseek-", "gpt-5.6-luna", "muse-spark")):
                    # Peek at response body for web_search
                    body_peek = await asyncio.to_thread(response.read)
                    # Restore response for normal handling if not web_search
                    # Check if it contains web_search
                    try:
                        obj_peek = json.loads(body_peek.decode(errors="replace"))
                        has_ws_call = any(item.get("name") == "web_search" for item in obj_peek.get("output", []) if item.get("type") == "function_call")
                        if has_ws_call:
                            # Extract query
                            ws_query = None
                            ws_call_id = None
                            for item in obj_peek.get("output", []):
                                if item.get("type") == "function_call" and item.get("name") == "web_search":
                                    args = item.get("arguments") or "{}"
                                    try:
                                        args_obj = json.loads(args) if isinstance(args, str) else args
                                        ws_query = args_obj.get("query") or "news"
                                        ws_call_id = item.get("call_id") or item.get("id")
                                    except:
                                        ws_query = "news"
                                    break
                            if ws_query:
                                _log(f"[vision-proxy] sidecar handling web_search for {model} query='{ws_query[:30]}'")
                                zen_key = os.environ.get("ZEN_API_KEY")
                                search_res = await _perform_web_search(ws_query, zen_key)
                                # Create a new response with search results
                                # The next turn from Codex will include the web_search call in history, but we can also
                                # directly return the search results as a tool output so the model can see them
                                # For now, synthesize a tool output and also a message
                                # We need to create a new request to the primary model with the search results injected
                                # Simplify: return the search results directly as a message
                                synthetic = {
                                    "id": obj_peek.get("id", "resp_" + uuid.uuid4().hex[:24]),
                                    "object": "response",
                                    "created_at": int(time.time()),
                                    "status": "completed",
                                    "model": model,
                                    "output": [
                                        {"id": "msg_" + uuid.uuid4().hex[:24], "type": "message", "status": "completed", "role": "assistant", "content": [{"type": "output_text", "text": f"Search results for '{ws_query}':\n{search_res[:4000]}", "annotations": []}]},
                                        {"type": "function_call_output", "call_id": ws_call_id, "output": search_res}
                                    ],
                                    "error": None,
                                    "usage": obj_peek.get("usage")
                                }
                                body_bytes = json.dumps(synthetic).encode()
                                await self._write_head(writer, 200, [("Content-Type", "application/json")], len(body_bytes))
                                writer.write(body_bytes)
                                await writer.drain()
                                response_started = True
                                txn["status"] = 200
                                txn["bridge"] = "web-search-sidecar-response"
                                try:
                                    response.close()
                                except:
                                    pass
                                return
                        # Not a web_search call, need to restore response for normal handling
                        # Create a new response object with the body we consumed
                        class RestoredResponse:
                            def __init__(self, status, headers, body):
                                self.status = status
                                self.headers = headers
                                self._body = body
                                self._pos = 0
                            def read(self, n=-1):
                                if n == -1:
                                    ret = self._body[self._pos:]
                                    self._pos = len(self._body)
                                    return ret
                                ret = self._body[self._pos:self._pos+n]
                                self._pos += len(ret)
                                return ret
                            def close(self): pass
                        # Restore headers
                        headers = list(response.headers.items()) if hasattr(response, "headers") else []
                        response = RestoredResponse(getattr(response, "status", 200), {k: v for k, v in headers}, body_peek)
                    except Exception as e:
                        _log(f"[vision-proxy] sidecar web_search check failed: {e!r}")
                        # Restore for normal handling
                        class RestoredResponse2:
                            def __init__(self, status, headers, body):
                                self.status = status
                                self.headers = headers
                                self._body = body
                                self._pos = 0
                            def read(self, n=-1):
                                if n == -1:
                                    ret = self._body[self._pos:]
                                    self._pos = len(self._body)
                                    return ret
                                ret = self._body[self._pos:self._pos+n]
                                self._pos += len(ret)
                                return ret
                            def close(self): pass
                        headers = list(response.headers.items()) if hasattr(response, "headers") else []
                        response = RestoredResponse2(getattr(response, "status", 200), {k: v for k, v in headers}, body_peek)
            except Exception as e:
                _log(f"[vision-proxy] sidecar response handling failed: {e!r}")

            response_started = True
            txn["status"] = getattr(response, "status", None) or getattr(response, "code", None)
            # 2026-09-20：Muse 空转兜底（narration-only turn）。是不是空转要读完整段响应才知道，
            # 所以重发只能在 _send_response 里做；这里把「拿同一份请求体重发一次」的能力传进去。
            stall_retry = None
            if (not fallback_now) and _is_muse_model(model) and _muse_flag("VISION_PROXY_MUSE_STALL_RETRY"):
                retry_base = bytes(body)

                async def stall_retry(attempt, _base=retry_base, _path=path, _headers=list(headers),
                                      _upstream=upstream, _method=method):
                    retry_body = _build_muse_retry_body(_base, attempt)
                    _log(f"[vision-proxy] muse stall retry #{attempt} model={model} bytes={len(retry_body)}")
                    return await self._open_upstream(_method, _path, retry_body, _headers, _upstream)
            # model 显式传进去：_last_model 是服务实例上的共享字段，并发请求会互相覆盖，
            # 用它的后果是"另一个模型的响应被按 Muse 规则改名/漏改名"。
            await self._send_response(writer, response, model=model, retry=stall_retry)
        except (ConnectionResetError, BrokenPipeError):
            txn["status"] = txn["status"] or 499
        except Exception as exc:
            _log(f"[vision-proxy] handler error: {exc!r}\n{__import__('traceback').format_exc()}")
            if not response_started:
                txn["status"] = 502
                # 2026-09-19：把底层异常类型带出去，Codex 里那句 502 才有信息量
                # （以前只有 "Upstream proxy request failed"，看不出是 TLS/DNS/超时还是别的）。
                await self._send_error(
                    writer, 502,
                    f"Upstream proxy request failed: {type(exc).__name__}: {str(exc)[:160]}",
                )
        finally:
            if txn["path"].endswith("/responses") or "/completions" in txn["path"] or "/messages" in txn["path"]:
                _log("[vision-proxy] txn {method} {path} model={model} route={route} "
                     "status={status} bridge={bridge} ms={ms}".format(
                         ms=int((time.monotonic() - txn["t0"]) * 1000), **{k: v for k, v in txn.items() if k != "t0"}))
            if response is not None:
                response.close()
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

    async def _open_upstream(self, method, path, body, headers, upstream=None):
        base = upstream or self.upstream
        request = urllib.request.Request(base + path, data=body or None, method=method)
        for key, value in headers:
            request.add_header(key, value)

        def open_request():
            # 2026-09-16: VPN 节点抖动/切换的瞬间，上游 TLS 会被瞬时重置
            # (SSLEOFError / Connection reset)。以前直接把这个连接级错误翻成 502
            # 甩给 Codex，Codex 疯狂重试刷屏；这里对连接级瞬时错误退避重试几次。
            # 只在"没收到任何 HTTP 响应"时重试，不会重复计费/生成。
            attempts = 4
            last_exc = None
            for i in range(attempts):
                try:
                    return DIRECT_OPENER.open(request, timeout=600)
                except urllib.error.HTTPError as exc:
                    return exc
                except urllib.error.URLError as exc:
                    last_exc = exc
                    reason = str(getattr(exc, "reason", exc))
                    transient = any(s in reason for s in (
                        "EOF occurred", "Connection reset", "Broken pipe",
                        "Connection refused", "Cannot connect",
                        "Network is unreachable", "Temporary failure",
                    ))
                    if i < attempts - 1 and transient:
                        _log(f"[vision-proxy] upstream transient error ({reason}), retry {i + 1}/{attempts - 1}")
                        time.sleep(0.8 * (i + 1))
                        continue
                    raise
            raise last_exc

        try:
            return await asyncio.to_thread(open_request)
        except urllib.error.URLError as exc:
            raise RuntimeError(f"Upstream network error: {exc.reason}") from exc

    async def _send_chat_bridge(self, writer, chat_resp, original_parsed, model, txn=None):
        """Translate a chat-completions upstream response into Responses wire format.

        Streaming path (P3/P4/P5): incremental typewriter translation via
        ChatBridgeTranslator — deltas flow through as they arrive, reasoning_content
        becomes a visible reasoning item, and a byte budget caps accumulation.
        """
        effort = None
        reasoning = original_parsed.get("reasoning") if isinstance(original_parsed, dict) else None
        if isinstance(reasoning, dict):
            effort = reasoning.get("effort")
        content_type = chat_resp.headers.get("Content-Type", "")
        wants_stream = "event-stream" in content_type or (isinstance(original_parsed, dict) and original_parsed.get("stream"))

        if not wants_stream:
            raw = bytearray()
            while len(raw) < _BRIDGE_NONSTREAM_MAX_BYTES:
                chunk = await asyncio.to_thread(chat_resp.read, 262144)
                if not chunk:
                    break
                raw.extend(chunk)
            try:
                obj = json.loads(bytes(raw))
            except json.JSONDecodeError:
                await self._send_error(writer, 502, f"chat fallback returned non-JSON for {model}")
                return
            obj = _build_chat_fallback_json(model, obj, effort)
            # Sidecar for web_search from non-search models via bridge - handle the search and inject results
            if model and not model.startswith(("deepseek-", "gpt-5.6-luna", "muse-spark")):
                has_ws = False
                ws_query = None
                ws_call_id = None
                for item in obj.get("output", []) if isinstance(obj.get("output"), list) else []:
                    if item.get("type") == "function_call" and item.get("name") == "web_search":
                        has_ws = True
                        ws_call_id = item.get("call_id") or item.get("id")
                        try:
                            args = json.loads(item.get("arguments", "{}"))
                            ws_query = args.get("query") or "news"
                        except:
                            ws_query = "news"
                        break
                if has_ws and ws_query:
                    _log(f"[vision-proxy] bridge sidecar web_search for {model} query='{ws_query[:30]}'")
                    try:
                        zen_key = os.environ.get("ZEN_API_KEY")
                        search_res = await _perform_web_search(ws_query, zen_key)
                        # For the bridge, we can't easily inject a new turn, so we will
                        # directly return the search results as a message in this response,
                        # along with the original web_search call output
                        # The model called web_search, we will provide the results immediately
                        # Append the search results as a new message and tool output
                        obj["output"].append({"type": "function_call_output", "call_id": ws_call_id, "output": search_res[:6000]})
                        # Also add a synthetic message with the results so the model can see them in this turn
                        # (Codex will see the tool output in the next request, but for immediate feedback we add a message)
                        # Actually, the current response already has the function_call, we are adding the output
                        # The client will then make a new request with this output in history, but for now we return
                        # a response that already contains both the call and the output, so the next turn is not needed
                        # To make it work, we will also add a message that summarizes the search
                        obj["output"].append({"id": "msg_" + uuid.uuid4().hex[:24], "type": "message", "status": "completed", "role": "assistant", "content": [{"type": "output_text", "text": f"Search results for '{ws_query}':\n{search_res[:3000]}", "annotations": []}]})
                        _log(f"[vision-proxy] bridge sidecar injected search results for {model} len={len(search_res)}")
                    except Exception as e:
                        _log(f"[vision-proxy] bridge sidecar failed: {e!r}")
            body = json.dumps(obj, ensure_ascii=False).encode()
            await self._write_head(writer, 200, [("Content-Type", "application/json")], len(body))
            writer.write(body)
            await writer.drain()
            return

        tr = ChatBridgeTranslator(model, effort=effort)
        sse_headers = [("Content-Type", "text/event-stream; charset=utf-8"), ("Cache-Control", "no-cache")]
        await self._write_head(writer, 200, sse_headers, None)
        writer.write(tr.on_created())
        await writer.drain()

        read_chunk = getattr(chat_resp, "read1", chat_resp.read)
        buffer = bytearray()
        upstream_ended_cleanly = False
        while not tr.truncated and not tr.finished:
            try:
                chunk = await asyncio.to_thread(read_chunk, 65536)
            except Exception as exc:  # socket reset mid-stream etc.
                _log(f"[vision-proxy] bridge upstream read error model={model}: {exc!r}")
                break
            if not chunk:
                upstream_ended_cleanly = True
                break
            buffer.extend(chunk)
            while not tr.truncated and not tr.finished:
                frame, rest = _split_sse_frame(buffer)
                if frame is None:
                    break
                buffer = rest
                out = tr.on_chat_frame(frame)
                if out:
                    writer.write(out)
            await writer.drain()
        if buffer and not tr.finished:
            out = tr.on_chat_frame(bytes(buffer))
            if out:
                writer.write(out)
        if not upstream_ended_cleanly and not tr.truncated and not tr.finished:
            _log(f"[vision-proxy] bridge upstream stream ended prematurely model={model}; finalizing anyway")
        writer.write(tr.on_finish())
        await writer.drain()

    async def _open_chat_upstream(self, chat_path, chat_body, fwd_headers, upstream, model):
        """chat 桥的上游调用：瞬时 5xx 退避重试（同样只在没往客户端写数据前重试）。"""
        attempts = 4
        last = None
        for attempt in range(attempts):
            resp = await self._open_upstream("POST", chat_path, chat_body, fwd_headers, upstream)
            last = resp
            status = getattr(resp, "status", None) or getattr(resp, "code", 0) or 0
            if status < 400 or status not in _UPSTREAM_TRANSIENT_STATUS or attempt >= attempts - 1:
                return resp
            err_text = ""
            try:
                err_text = (await asyncio.to_thread(resp.read)).decode(errors="replace")[:200]
            except Exception:
                pass
            _log(f"[vision-proxy] chat bridge transient {status} model={model}, "
                 f"retry {attempt + 1}/{attempts - 1}: {err_text[:100]}")
            try:
                resp.close()
            except Exception:
                pass
            await asyncio.sleep(0.8 * (attempt + 1))
        return last

    async def _open_messages_upstream(self, parsed, path, headers, upstream):
        """把 Responses 请求翻成 Messages 请求发出去。

        线上实测：Go 的 /v1/messages 认 `x-api-key`（Bearer 会 401 Missing API key），
        且必须带 x-opencode-session（否则 400 MissingSessionID），另需 anthropic-version。
        """
        zen_key = os.environ.get("ZEN_API_KEY") or ""
        payload = _responses_request_to_messages(parsed)
        body = json.dumps(payload, ensure_ascii=False).encode()
        messages_path = "/v1/messages" if path.startswith("/v1") else "/messages"
        fwd_headers = [(k, v) for k, v in headers
                       if k.lower() not in ("content-length", "accept-encoding", "authorization", "content-type")]
        fwd_headers.append(("Content-Type", "application/json"))
        fwd_headers.append(("x-api-key", zen_key))
        fwd_headers.append(("anthropic-version", _ANTHROPIC_VERSION))
        if not any(k.lower() == "x-opencode-session" for k, _ in fwd_headers):
            fwd_headers.append(("x-opencode-session", _oc_session_id(parsed)))
        response = await self._open_upstream("POST", messages_path, body, fwd_headers, upstream)
        return response, payload

    async def _messages_bridge_attempt(self, writer, parsed, model, path, headers, upstream, txn, reason=""):
        """试一次 messages 桥。返回 True = 已经把响应写回客户端。

        上游 5xx 有一种是供应商抖动（实测 union-alpha 会随机回
        503 "Endpoint is unavailable"），此时没有生成任何内容、没计费，
        所以退避重试；重试只发生在「还没往客户端写一个字节」之前。
        """
        attempts = 4
        for attempt in range(attempts):
            try:
                messages_resp, payload = await self._open_messages_upstream(parsed, path, headers, upstream)
            except Exception as exc:
                _log(f"[vision-proxy] messages bridge open failed model={model} "
                     f"attempt={attempt + 1}/{attempts}: {exc!r} ({reason})")
                if attempt < attempts - 1:
                    await asyncio.sleep(0.8 * (attempt + 1))
                    continue
                return False
            try:
                status = getattr(messages_resp, "status", None) or getattr(messages_resp, "code", 0) or 0
                txn["messages_bridge"] = status
                if status < 400:
                    txn["status"], txn["bridge"] = 200, "messages-fallback"
                    _log(f"[vision-proxy] responses->messages fallback engaged model={model} status={status} "
                         f"tools={len(payload.get('tools') or [])} msgs={len(payload.get('messages') or [])} "
                         f"({reason})")
                    await self._send_messages_bridge(writer, messages_resp, parsed, model, txn)
                    return True
                err_text = ""
                try:
                    err_text = (await asyncio.to_thread(messages_resp.read)).decode(errors="replace")[:300]
                except Exception:
                    pass
                txn["messages_bridge_error"] = err_text[:200]
                if status in _UPSTREAM_TRANSIENT_STATUS and attempt < attempts - 1:
                    _log(f"[vision-proxy] messages bridge transient {status} model={model}, "
                         f"retry {attempt + 1}/{attempts - 1}: {err_text[:100]}")
                else:
                    _log(f"[vision-proxy] messages bridge FAILED model={model} status={status} "
                         f"tools={len(payload.get('tools') or [])} msgs={len(payload.get('messages') or [])} "
                         f"err={err_text[:160]} ({reason})")
                    return False
            finally:
                try:
                    messages_resp.close()
                except Exception:
                    pass
            await asyncio.sleep(0.8 * (attempt + 1))
        return False

    async def _send_messages_bridge(self, writer, messages_resp, original_parsed, model, txn=None):
        """把 Anthropic Messages 上游响应翻成 Responses 线上格式（流式 + 非流式）。"""
        content_type = messages_resp.headers.get("Content-Type", "")
        wants_stream = "event-stream" in content_type or (
            isinstance(original_parsed, dict) and original_parsed.get("stream"))

        if not wants_stream:
            raw = bytearray()
            while len(raw) < _BRIDGE_NONSTREAM_MAX_BYTES:
                chunk = await asyncio.to_thread(messages_resp.read, 262144)
                if not chunk:
                    break
                raw.extend(chunk)
            try:
                obj = json.loads(bytes(raw))
            except json.JSONDecodeError:
                await self._send_error(writer, 502, f"messages fallback returned non-JSON for {model}")
                return
            payload = _build_messages_fallback_json(model, obj)
            body = json.dumps(payload, ensure_ascii=False).encode()
            await self._write_head(writer, 200, [("Content-Type", "application/json")], len(body))
            writer.write(body)
            await writer.drain()
            return

        tr = MessagesBridgeTranslator(model)
        sse_headers = [("Content-Type", "text/event-stream; charset=utf-8"), ("Cache-Control", "no-cache")]
        await self._write_head(writer, 200, sse_headers, None)
        writer.write(tr.ensure_created())
        await writer.drain()

        read_chunk = getattr(messages_resp, "read1", messages_resp.read)
        buffer = bytearray()
        upstream_ended_cleanly = False
        while not tr.truncated and not tr.finished:
            try:
                chunk = await asyncio.to_thread(read_chunk, 65536)
            except Exception as exc:
                _log(f"[vision-proxy] messages bridge upstream read error model={model}: {exc!r}")
                break
            if not chunk:
                upstream_ended_cleanly = True
                break
            buffer.extend(chunk)
            while not tr.truncated and not tr.finished:
                frame, rest = _split_sse_frame(buffer)
                if frame is None:
                    break
                buffer = rest
                out = tr.on_message_frame(frame)
                if out:
                    writer.write(out)
            await writer.drain()
        if buffer and not tr.finished:
            out = tr.on_message_frame(bytes(buffer))
            if out:
                writer.write(out)
        if not upstream_ended_cleanly and not tr.truncated and not tr.finished:
            _log(f"[vision-proxy] messages bridge stream ended prematurely model={model}; finalizing anyway")
        writer.write(tr.on_finish())
        await writer.drain()

    async def _send_response(self, writer, response, model=None, retry=None):
        status = getattr(response, "status", None) or getattr(response, "code", 502)
        headers = list(response.headers.items())
        content_type = response.headers.get("Content-Type", "")
        compressed = response.headers.get("Content-Encoding")
        if "text/event-stream" in content_type and not compressed:
            if self.inject_reasoning_summary:
                body = await asyncio.to_thread(response.read)
                body = _rewrite_sse_body(body)
                body = _inject_reasoning_summaries(body.decode(errors="replace")).encode()
                await self._write_head(writer, status, headers, len(body))
                writer.write(body)
                await writer.drain()
                return
            await self._send_response_sse(writer, response, status, headers, retry=retry, model=model)
            return
        if "application/json" in content_type and not compressed:
            body = await asyncio.to_thread(response.read)
            body = _rewrite_apply_patch_response_json(body, model if model is not None else getattr(self, "_last_model", None))
            await self._write_head(writer, status, headers, len(body))
            writer.write(body)
            await writer.drain()
            return

        await self._write_head(writer, status, headers, None)
        read_chunk = getattr(response, "read1", response.read)
        while chunk := await asyncio.to_thread(read_chunk, 65536):
            writer.write(chunk)
            await writer.drain()

    async def _guard_muse_stall(self, response, status, headers, retry):
        """把 Muse 的流式响应先读完，确认不是「只叙述不调用工具」的空转再交给客户端。

        空转（没有 function_call + 短计划文字）时用同一份请求体重发，最多两次；两次都空转就把
        最后一次的内容照样发给客户端，绝不让调用方悬着。熔断由 _muse_retry_allowed 兜。
        """
        try:
            body = await asyncio.to_thread(response.read)
        except Exception as exc:
            _log(f"[vision-proxy] muse stall probe read failed: {exc!r}")
            return response, status, headers
        attempts = 0
        while attempts < MUSE_MAX_STALL_RETRIES and _sse_looks_like_stall(body):
            attempts += 1
            if not _muse_retry_allowed(bytes(body)):
                _log(f"[vision-proxy] muse stall detected but circuit breaker open (#{attempts}); forwarding as-is")
                break
            _log(f"[vision-proxy] muse narration-only stall detected (retry #{attempts})")
            try:
                response.close()
            except Exception:
                pass
            try:
                nxt = await retry(attempts)
            except Exception as exc:
                _log(f"[vision-proxy] muse stall retry failed: {exc!r}")
                break
            if nxt is None:
                break
            nxt_status = getattr(nxt, "status", None) or getattr(nxt, "code", 0) or status
            nxt_headers = list(nxt.headers.items()) if hasattr(nxt, "headers") else headers
            try:
                nxt_body = await asyncio.to_thread(nxt.read)
            except Exception as exc:
                _log(f"[vision-proxy] muse stall retry read failed: {exc!r}")
                break
            response, status, headers, body = nxt, nxt_status, nxt_headers, nxt_body
        final_status = getattr(response, "status", None) or status
        return _BufferedResponse(final_status, {k: v for k, v in headers}, bytes(body)), status, headers

    async def _send_response_sse(self, writer, response, status, headers, retry=None, model=None):
        """Stream the upstream SSE response. Fail-safe apply_patch bridge:
        only whitelisted apply_patch frames are transformed; every other
        frame is forwarded byte-identical (including its delimiter). Any
        parse/transform error forwards the raw frame."""
        if retry is not None:
            response, status, headers = await self._guard_muse_stall(response, status, headers, retry)
        await self._write_head(writer, status, headers, None)
        read_chunk = getattr(response, "read1", response.read)
        buffer = bytearray()
        state = {"pending": {}, "completed": False,
                 "compat": {"model": model if model is not None else getattr(self, "_last_model", None)}}

        async def emit(frame_bytes):
            writer.write(frame_bytes)
            await writer.drain()

        # 2026-09-23：上游"挂着不发字节"时别让 Codex 一直转圈（muse 空转的另一半）。
        # 给底层 socket 套一个空闲宽限：空闲到点且这一轮内容已完整 → 收尾补终止帧；
        # 内容还没完整就继续等（长思考不能被掐），但连续空闲超过 TERMINAL_IDLE_MAX_ROUNDS 才算真死。
        idle_rounds = 0
        try:
            sock = response.fp.raw._sock          # urllib 响应的底层 socket
            sock.settimeout(TERMINAL_GRACE_SECONDS)
            _log(f"[vision-proxy] SSE 空闲宽限 {TERMINAL_GRACE_SECONDS:.0f}s 已启用")
        except Exception:
            sock = None

        while True:
            try:
                chunk = await asyncio.to_thread(read_chunk, 65536)
            except (socket.timeout, TimeoutError):
                if sse_turn_looks_complete(state):
                    _log(f"[vision-proxy] 上游空闲 {TERMINAL_GRACE_SECONDS:.0f}s 且内容已完整 → 收尾"
                         f"（trigger=idle model={state.get('compat', {}).get('model')}）")
                    break
                idle_rounds += 1
                if idle_rounds >= TERMINAL_IDLE_MAX_ROUNDS:
                    _log(f"[vision-proxy] 上游连续空闲 {idle_rounds}×{TERMINAL_GRACE_SECONDS:.0f}s 且内容不完整 → 收尾")
                    break
                continue
            if not chunk:
                break
            idle_rounds = 0        # 有数据就重置：计数只统计"连续"空闲，慢但活着的流不会被误掐
            buffer.extend(chunk)
            while True:
                frame, rest = _split_sse_frame(buffer)
                if frame is None:
                    break
                buffer = rest
                for compat_frame in _complete_sse_frame(frame, state):
                    for out_frame in _rewrite_sse_frame(compat_frame, state):
                        await emit(out_frame)
        if buffer:
            for compat_frame in _complete_sse_frame(bytes(buffer), state):
                for out_frame in _rewrite_sse_frame(compat_frame, state):
                    await emit(out_frame)
        compat = state.get("compat")
        if compat and compat.get("started") and not compat.get("saw_created") and not state.get("completed"):
            close_frame = b"event: response.completed\ndata: {\"type\": \"response.completed\"}\n\n"
            for compat_frame in _complete_sse_frame(close_frame, state):
                for out_frame in _rewrite_sse_frame(compat_frame, state):
                    await emit(out_frame)
        # P2 hardening: a stream that ends without ANY terminal event would hang
        # codex-rs ("stream closed before response.completed"). Synthesize a terminal frame.
        # 2026-09-23：先按 opencodex 的 modelResponsesTerminalRepair 契约分两种 ——
        # 内容已经完整（开过的输出项都 done 了）就补 response.completed，这一轮照常收尾；
        # 只有内容确实不完整时才判 response.failed（老行为）。
        if not state.get("completed"):
            model = compat.get("model") if compat else getattr(self, "_last_model", None)
            if sse_turn_looks_complete(state):
                done_payload = {
                    "type": "response.completed",
                    "response": {
                        "id": "resp_" + uuid.uuid4().hex[:24],
                        "object": "response",
                        "created_at": int(time.time()),
                        "completed_at": int(time.time()),
                        "status": "completed",
                        "model": model,
                        # 已经发过的项原样带上：客户端若从 completed 帧里取最终 output，
                        # 也不会拿到空数组（对齐 opencodex 的做法）
                        "output": list(state.get("completed_items") or []),
                    },
                }
                _log(f"[vision-proxy] 上游没发终止帧但内容已完整 → 补 response.completed model={model}")
                frame_bytes = f"data: {json.dumps(done_payload)}\n\n".encode()
                for compat_frame in _complete_sse_frame(frame_bytes, state):
                    for out_frame in _rewrite_sse_frame(compat_frame, state):
                        await emit(out_frame)
        if not state.get("completed"):
            model = compat.get("model") if compat else getattr(self, "_last_model", None)
            fail_payload = {
                "type": "response.failed",
                "response": {
                    "id": "resp_" + uuid.uuid4().hex[:24],
                    "object": "response",
                    "created_at": int(time.time()),
                    "status": "failed",
                    "model": model,
                    "output": [],
                    "error": {"code": "upstream_stream_interrupted",
                              "message": "Upstream SSE stream ended without a terminal event; synthesized by vision-proxy"},
                },
            }
            _log(f"[vision-proxy] upstream SSE ended without terminal event; synthesized response.failed model={model}")
            frame_bytes = f"data: {json.dumps(fail_payload)}\n\n".encode()
            for compat_frame in _complete_sse_frame(frame_bytes, state):
                for out_frame in _rewrite_sse_frame(compat_frame, state):
                    await emit(out_frame)
        for item_id, entry in list(state["pending"].items()):
            state["pending"].pop(item_id, None)
            state.setdefault("flushed", set()).add(item_id)
            _log(f"[vision-proxy] apply_patch stream ended mid-call item_id={item_id}")
            for out_frame in _flush_apply_patch(entry, interrupted=True):
                await emit(out_frame)

    async def _write_head(self, writer, status, headers, content_length):
        reason = HTTPStatus(status).phrase if status in HTTPStatus._value2member_map_ else "Unknown"
        output = f"HTTP/1.1 {status} {reason}\r\n".encode()
        for key, value in headers:
            if key.lower() not in HOP_HEADERS:
                output += f"{key}: {value}\r\n".encode("latin1")
        if content_length is not None:
            output += f"Content-Length: {content_length}\r\n".encode()
        writer.write(output + b"Connection: close\r\n\r\n")
        await writer.drain()

    async def _send_error(self, writer, status, message):
        if writer.is_closing():
            return
        body = json.dumps({"error": {"message": message, "type": "proxy_error"}}, ensure_ascii=False).encode()
        writer.write(f"HTTP/1.1 {status} {HTTPStatus(status).phrase}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode() + body)
        await writer.drain()

    @staticmethod
    async def _read_head(reader):
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 128 * 1024:
            chunk = await reader.read(4096)
            if not chunk:
                break
            data += chunk
        if b"\r\n\r\n" not in data:
            return None
        head, _, body = data.partition(b"\r\n\r\n")
        lines = head.decode("latin1").split("\r\n")
        headers = []
        for line in lines[1:]:
            if ":" in line:
                key, _, value = line.partition(":")
                headers.append((key.strip(), value.strip()))
        return lines[0], headers, body

    async def serve(self):
        server = await asyncio.start_server(self.handle, "127.0.0.1", self.port)
        _log(f"[vision-proxy] listening on 127.0.0.1:{self.port} -> {self.upstream}")
        async with server:
            await server.serve_forever()


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=19100)
    parser.add_argument("--upstream", default="https://api.deepseek.com")
    parser.add_argument("--log", default="")
    parser.add_argument("--env-file")
    parser.add_argument("--codex-header-compat", action="store_true")
    parser.add_argument("--inject-reasoning-summary", action="store_true")
    # 兼容旧安装器写进 LaunchAgent 的开关；视觉链路已下线，这里只保留参数不做事
    parser.add_argument("--skip-vision-config-check", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    load_env_file(args.env_file)
    proxy = Proxy(args.port, args.upstream, args.log, args.codex_header_compat,
                  args.inject_reasoning_summary)
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        try:
            loop.add_signal_handler(sig, stopped.set)
        except NotImplementedError:
            pass
    task = asyncio.create_task(proxy.serve())
    await stopped.wait()
    task.cancel()
    await asyncio.gather(task, return_exceptions=True)
