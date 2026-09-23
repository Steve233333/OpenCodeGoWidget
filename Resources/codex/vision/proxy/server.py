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
    MUSE_MAX_STALL_RETRIES,
    MUSE_STALL_HOLD_BYTES,
    MUSE_STALL_HOLD_SECONDS,
    MUSE_STALL_TEXT_LIMIT,
    IO_BUFFER_BYTES,
    IO_CHUNK_BYTES,
    RETRY_BACKOFF_BASE,
    TERMINAL_GRACE_SECONDS,
    WEB_SEARCH_BRIDGE_LIMIT,
    WEB_SEARCH_INLINE_LIMIT,
    WEB_SEARCH_TOOL_LIMIT,
    TERMINAL_IDLE_MAX_ROUNDS,
    ZEN_SUFFIX,
    ZEN_UPSTREAM,
    _ANTHROPIC_VERSION,
    _BRIDGE_NONSTREAM_MAX_BYTES,
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
from .pipeline import RequestPipelineMixin
from .policy import (
    NATIVE_PROBES,
    ROUTE_BRIDGE,
    ROUTE_MESSAGES,
    ROUTE_NATIVE_OR_BRIDGE,
    has_native_search,
    policy_for,
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
    _sse_output_signals,
    _sse_looks_like_stall,
    TextDeltaPacer,
    sse_turn_looks_complete,
)
from .toolfix import (
    _fix_tool_required,
    _normalize_fc_args_history,
    _sanitize_input_ids,
)


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


class _PrefixedResponse:
    """先吐已经扣留的字节，然后继续从上游实时读（2026-09-23）。

    用途：Muse 空转守卫只扣一小段；一旦判定"不是在空转"，就把已读到的部分交给客户端，
    剩下的边流边转 —— 这样 muse 也能逐字出现，而不是等整段读完才一次性蹦出来。
    """

    def __init__(self, prefix, upstream, status, headers):
        self.status = status
        self.headers = headers
        self._prefix = bytes(prefix)
        self._upstream = upstream

    def read(self, n=-1):
        if self._prefix:
            if n is None or n < 0:
                chunk, self._prefix = self._prefix, b""
                return chunk
            chunk, self._prefix = self._prefix[:n], self._prefix[n:]
            return chunk
        return self._upstream.read(n)

    def read1(self, n=None):
        return self.read(IO_CHUNK_BYTES if n is None else n)

    def close(self):
        try:
            self._upstream.close()
        except Exception:
            pass


def _tool_param_types(parsed):
    """从请求的 tools 里抠出 {"工具名": {"参数名": "integer|number|boolean|string"}}。

    用途（2026-09-23）：MiMo 的 XML 工具调用只有文本值（`<parameter=session_id>77397</parameter>`），
    要变成合法的 function_call 参数就得知道每个参数的类型 —— 类型就在请求的 tools schema 里，
    拿到就按它转，拿不到就不猜（一律当字符串）。
    """
    out = {}
    tools = parsed.get("tools") if isinstance(parsed, dict) else None
    if not isinstance(tools, list):
        return out
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        name = tool.get("name")
        params = tool.get("parameters")
        if not isinstance(name, str) or not isinstance(params, dict):
            continue
        props = params.get("properties")
        if not isinstance(props, dict):
            continue
        types = {}
        for key, spec in props.items():
            if isinstance(spec, dict) and isinstance(spec.get("type"), str):
                types[key] = spec["type"]
        if types:
            out[name] = types
    return out


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


class Proxy(RequestPipelineMixin):
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
                        time.sleep(RETRY_BACKOFF_BASE * (i + 1))
                        continue
                    raise
            raise last_exc

        try:
            return await asyncio.to_thread(open_request)
        except urllib.error.URLError as exc:
            raise RuntimeError(f"Upstream network error: {exc.reason}") from exc

    async def _send_chat_bridge(self, writer, chat_resp, original_parsed, model, txn=None):
        # MiMo 的 XML 工具调用要用到参数类型（见 _tool_param_types）
        param_types = _tool_param_types(original_parsed)
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
                chunk = await asyncio.to_thread(chat_resp.read, IO_BUFFER_BYTES)
                if not chunk:
                    break
                raw.extend(chunk)
            try:
                obj = json.loads(bytes(raw))
            except json.JSONDecodeError:
                await self._send_error(writer, 502, f"chat fallback returned non-JSON for {model}")
                return
            obj = _build_chat_fallback_json(model, obj, effort, tool_param_types=param_types)
            # Sidecar for web_search from non-search models via bridge - handle the search and inject results
            if model and not has_native_search(model):
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
                        obj["output"].append({"type": "function_call_output", "call_id": ws_call_id, "output": search_res[:WEB_SEARCH_TOOL_LIMIT]})
                        # Also add a synthetic message with the results so the model can see them in this turn
                        # (Codex will see the tool output in the next request, but for immediate feedback we add a message)
                        # Actually, the current response already has the function_call, we are adding the output
                        # The client will then make a new request with this output in history, but for now we return
                        # a response that already contains both the call and the output, so the next turn is not needed
                        # To make it work, we will also add a message that summarizes the search
                        obj["output"].append({"id": "msg_" + uuid.uuid4().hex[:24], "type": "message", "status": "completed", "role": "assistant", "content": [{"type": "output_text", "text": f"Search results for '{ws_query}':\n{search_res[:WEB_SEARCH_BRIDGE_LIMIT]}", "annotations": []}]})
                        _log(f"[vision-proxy] bridge sidecar injected search results for {model} len={len(search_res)}")
                    except Exception as e:
                        _log(f"[vision-proxy] bridge sidecar failed: {e!r}")
            body = json.dumps(obj, ensure_ascii=False).encode()
            await self._write_head(writer, 200, [("Content-Type", "application/json")], len(body))
            writer.write(body)
            await writer.drain()
            return

        tr = ChatBridgeTranslator(model, effort=effort, tool_param_types=param_types)
        sse_headers = [("Content-Type", "text/event-stream; charset=utf-8"), ("Cache-Control", "no-cache")]
        await self._write_head(writer, 200, sse_headers, None)
        writer.write(tr.on_created())
        await writer.drain()

        read_chunk = getattr(chat_resp, "read1", chat_resp.read)
        buffer = bytearray()
        upstream_ended_cleanly = False
        while not tr.truncated and not tr.finished:
            try:
                chunk = await asyncio.to_thread(read_chunk, IO_CHUNK_BYTES)
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
            await asyncio.sleep(RETRY_BACKOFF_BASE * (attempt + 1))
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
                    await asyncio.sleep(RETRY_BACKOFF_BASE * (attempt + 1))
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
            await asyncio.sleep(RETRY_BACKOFF_BASE * (attempt + 1))
        return False

    async def _send_messages_bridge(self, writer, messages_resp, original_parsed, model, txn=None):
        """把 Anthropic Messages 上游响应翻成 Responses 线上格式（流式 + 非流式）。"""
        content_type = messages_resp.headers.get("Content-Type", "")
        wants_stream = "event-stream" in content_type or (
            isinstance(original_parsed, dict) and original_parsed.get("stream"))

        if not wants_stream:
            raw = bytearray()
            while len(raw) < _BRIDGE_NONSTREAM_MAX_BYTES:
                chunk = await asyncio.to_thread(messages_resp.read, IO_BUFFER_BYTES)
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
                chunk = await asyncio.to_thread(read_chunk, IO_CHUNK_BYTES)
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

    async def _guard_muse_stall(self, response, status, headers, retry, attempts_left=None):
        """Muse 的「只叙述不调用工具」空转守卫 —— 有限扣留版（2026-09-23）。

        以前是**把整段响应读完**再判断：muse 于是从来不逐字流式（实测长回合 63~82 秒里
        客户端一直"正在思考"）。现在只扣一小段：
          * 看到 function_call / 正文超过阈值 / 扣满字节或秒数 → 立刻放行（已读部分先给客户端，
            剩下的边流边转，不重发）；
          * 流结束时还扣着（典型的"短叙述 + 没工具调用"）→ 照旧判定空转并重发，最多两次。
        重发拿到的新响应走同一个守卫（递归、次数递减）—— 所以"重发之后"也是流式的。
        熔断仍由 _muse_retry_allowed 兜。
        """
        if attempts_left is None:
            attempts_left = MUSE_MAX_STALL_RETRIES
        hold = attempts_left > 0          # 没有重发机会了就不用扣留，直接边流边转
        started = time.monotonic()
        body = b""
        # 关键：必须用 read1（有数据就返回）。HTTPResponse.read(n) 会**阻塞到凑满 n 字节**，
        # 实测那样第一次拿到 64 KB 已经是 39.8 秒之后，"有限扣留"就完全失效了。
        read_chunk = getattr(response, "read1", None) or response.read
        while True:
            try:
                chunk = await asyncio.to_thread(read_chunk, IO_CHUNK_BYTES)
            except Exception as exc:
                _log(f"[vision-proxy] muse stall probe read failed: {exc!r}")
                break
            if not chunk:
                break
            body += chunk
            if hold:
                has_tool_call, text = _sse_output_signals(body)
                long_text = len(text.strip()) > MUSE_STALL_TEXT_LIMIT
                over_hold = (len(body) >= MUSE_STALL_HOLD_BYTES
                             or time.monotonic() - started >= MUSE_STALL_HOLD_SECONDS)
                if has_tool_call or long_text or over_hold:
                    reason = ("工具调用" if has_tool_call
                              else "正文够长" if long_text else "扣留到上限")
                    _log(f"[vision-proxy] muse 放行实时转发（{reason}，已扣 {len(body)} 字节 "
                         f"{time.monotonic() - started:.1f}s）")
                    return _PrefixedResponse(body, response, status, headers), status, headers
        if not hold:
            # 已经没有重发机会：整段照原样交给客户端
            final_status = getattr(response, "status", None) or status
            return _BufferedResponse(final_status, headers, bytes(body)), status, headers
        # 流结束了还扣着：这时候才做空转判定（短叙述 + 没工具调用 + 有终态）
        if _sse_looks_like_stall(body):
            attempt_no = MUSE_MAX_STALL_RETRIES - attempts_left + 1
            if not _muse_retry_allowed(bytes(body)):
                _log(f"[vision-proxy] muse stall detected but circuit breaker open (#{attempt_no}); forwarding as-is")
            else:
                _log(f"[vision-proxy] muse narration-only stall detected (retry #{attempt_no})")
                try:
                    response.close()
                except Exception:
                    pass
                nxt = None
                try:
                    nxt = await retry(attempt_no)
                except Exception as exc:
                    _log(f"[vision-proxy] muse stall retry failed: {exc!r}")
                if nxt is not None:
                    nxt_status = getattr(nxt, "status", None) or getattr(nxt, "code", 0) or status
                    nxt_headers = list(nxt.headers.items()) if hasattr(nxt, "headers") else headers
                    return await self._guard_muse_stall(
                        nxt, nxt_status, nxt_headers, retry, attempts_left - 1)
        final_status = getattr(response, "status", None) or status
        return _BufferedResponse(final_status, headers, bytes(body)), status, headers

    async def _send_response_sse(self, writer, response, status, headers, retry=None, model=None):
        """Stream the upstream SSE response. Fail-safe apply_patch bridge:
        only whitelisted apply_patch frames are transformed; every other
        frame is forwarded byte-identical (including its delimiter). Any
        parse/transform error forwards the raw frame."""
        if retry is not None:
            response, status, headers = await self._guard_muse_stall(response, status, headers, retry)
        pol = policy_for(model)                    # 宽限/平滑都查策略表（2026-09-23 收敛）
        await self._write_head(writer, status, headers, None)
        read_chunk = getattr(response, "read1", response.read)
        buffer = bytearray()
        state = {"pending": {}, "completed": False,
                 "compat": {"model": model if model is not None else getattr(self, "_last_model", None)}}

        # 2026-09-23：上游（尤其 muse 网关）常把整段正文在末尾一次性涌出来 —— 客户端看起来
        # 就是"文字闪一下全出来"。漏桶按固定速率滴出去，显示就像正常逐字；本来就是均匀的流
        # （每帧几字）桶是空的、零延迟零改动。
        pacer = TextDeltaPacer() if pol.smoothing else None

        async def emit(frame_bytes):
            shaped = pacer.shape(frame_bytes) if pacer else [(frame_bytes, 0.0)]
            for piece, delay in shaped:
                writer.write(piece)
                await writer.drain()
                if delay:
                    await asyncio.sleep(delay)

        # 2026-09-23：上游"挂着不发字节"时别让 Codex 一直转圈（muse 空转的另一半）。
        # 给底层 socket 套一个空闲宽限：空闲到点且这一轮内容已完整 → 收尾补终止帧；
        # 内容还没完整就继续等（长思考不能被掐），但连续空闲超过 TERMINAL_IDLE_MAX_ROUNDS 才算真死。
        idle_rounds = 0
        grace = pol.terminal_grace or TERMINAL_GRACE_SECONDS
        try:
            sock = response.fp.raw._sock          # urllib 响应的底层 socket
            sock.settimeout(grace)
            _log(f"[vision-proxy] SSE 空闲宽限 {grace:.0f}s 已启用")
        except Exception:
            sock = None

        while True:
            try:
                chunk = await asyncio.to_thread(read_chunk, IO_CHUNK_BYTES)
            except (socket.timeout, TimeoutError):
                if sse_turn_looks_complete(state):
                    _log(f"[vision-proxy] 上游空闲 {grace:.0f}s 且内容已完整 → 收尾"
                         f"（trigger=idle model={state.get('compat', {}).get('model')}）")
                    break
                idle_rounds += 1
                if idle_rounds >= TERMINAL_IDLE_MAX_ROUNDS:
                    _log(f"[vision-proxy] 上游连续空闲 {idle_rounds}×{grace:.0f}s 且内容不完整 → 收尾")
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
