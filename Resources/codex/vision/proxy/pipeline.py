"""请求管线：HTTP 层之外的那一大段"读请求 → 准备 → 路由 → 桥/原生 → 日志"（2026-09-23 从 server.py 搬出来）。

搬出来的原因：`handle()` 一度 483 行、49 个 if 挤在一个方法里，改一处要通读整段。
这一版先**纯搬移**（逻辑一行没改），行为不变；后续再把里面的步骤拆成
`_turn_read_request / _turn_prepare / _turn_decide_route / _turn_run` 这些独立方法。
"""

from __future__ import annotations

import asyncio
import json
import os
import time
import uuid

from .apply_patch import _rewrite_apply_patch_tool
from .bridges_chat import _oc_session_id, _responses_request_to_chat
from .config import (GO_SUFFIX, GO_UPSTREAM, IO_CHUNK_BYTES, WEB_SEARCH_INLINE_LIMIT,
                     ZEN_SUFFIX, ZEN_UPSTREAM, _clamp_reasoning_effort, _log,
                     normalize_route_model)
from .muse import (_build_muse_retry_body, _inject_muse_no_preamble, _inject_muse_tool_first,
                   _muse_flag, _sanitize_muse_tool_schemas)
from .policy import (NATIVE_PROBES, ROUTE_BRIDGE, ROUTE_MESSAGES, ROUTE_NATIVE_OR_BRIDGE,
                     has_native_search, policy_for)
from .search_sidecar import (_inject_synthetic_web_search, _is_web_search_tool_call,
                             _normalize_web_search_call, _perform_web_search)
from .toolfix import (_fix_tool_required, _intercept_unsupported_history,
                      _normalize_fc_args_history, _sanitize_input_ids)




def _header_value(headers, name):
    return next((value for key, value in headers if key.lower() == name.lower()), None)




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




def _rewrite_model_compat(parsed):
    if parsed.get("model") != "gpt-5.2":
        return False
    parsed["model"] = "deepseek-v4-flash"
    _log("[vision-proxy] model compatibility gpt-5.2 -> deepseek-v4-flash")
    return True




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


class RequestPipelineMixin:
    """Proxy 的请求管线（作为 mixin 与 Proxy 组合；方法依赖 Proxy 上的网络/工具方法）。"""

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
                chunk = await reader.read(min(IO_CHUNK_BYTES, content_length - len(body)))
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
                    is_search_capable = has_native_search(model)
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
                                        "content": [{"type": "input_text", "text": f"[web_search sidecar] 已为你实时搜索完成，直接基于以下搜索结果回答：\n{search_res[:WEB_SEARCH_INLINE_LIMIT]}"}]
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
                # Muse 的推理也吃 max_output_tokens（实测 80 预算里 reasoning 占 77 → 一个字没吐就 incomplete）。
                # 只抬高客户端显式给的小值，没给就照上游默认（2026-09-23）。
                _min_budget = policy_for(model).min_output_tokens
                _cur_budget = parsed.get("max_output_tokens") if isinstance(parsed, dict) else None
                if _min_budget and isinstance(_cur_budget, int) and _cur_budget < _min_budget:
                    parsed["max_output_tokens"] = _min_budget
                    _log(f"[vision-proxy] {model} max_output_tokens {_cur_budget} → {_min_budget}"
                         f"（推理计入这个预算，太小会只思考不出字）")
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
            pol = policy_for(model)
            bridge_cached = (bridge_eligible and pol.route == ROUTE_NATIVE_OR_BRIDGE
                             and NATIVE_PROBES.is_broken(model))
            always_bridge = bridge_eligible and pol.route == ROUTE_BRIDGE
            messages_now = bridge_eligible and pol.route == ROUTE_MESSAGES
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
                if 200 <= upstream_status < 300:
                    # 原生路径活了：把"连续失败"计数清零（下次坏了重新从 5 分钟起步）
                    NATIVE_PROBES.note_success(model)
                # 2026-09-10：网关把「Model X is not supported for format openai」从 500 改成 401
                # （kimi-k3 实测），已知 chat 适配模型在 /responses 上吃 401 也要切桥；
                # 未登记模型仍只在 5xx 时切，避免把真正的鉴权失败吞成桥接。
                needs_bridge = upstream_status >= 500 or (
                    upstream_status == 401 and pol.route == ROUTE_NATIVE_OR_BRIDGE)
                if bridge_eligible and needs_bridge:
                    if pol.route != ROUTE_NATIVE_OR_BRIDGE:
                        _log(f"[vision-proxy] auto-bridge new model {model} on {upstream_status} (策略表里没登记这个模型)")
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
                    # 连续失败就指数退避（2026-09-23）：别每 5 分钟白试一次原生路径
                    ttl = NATIVE_PROBES.note_failure(model)
                    _log(f"[vision-proxy] {model} 原生 /responses 连续失败 "
                         f"{NATIVE_PROBES.streak(model)} 次 → 接下来 {int(ttl)}s 直接走 chat 桥")
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
                                        {"id": "msg_" + uuid.uuid4().hex[:24], "type": "message", "status": "completed", "role": "assistant", "content": [{"type": "output_text", "text": f"Search results for '{ws_query}':\n{search_res[:WEB_SEARCH_INLINE_LIMIT]}", "annotations": []}]},
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
            if (not fallback_now) and pol.stall_guard and _muse_flag("VISION_PROXY_MUSE_STALL_RETRY"):
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
