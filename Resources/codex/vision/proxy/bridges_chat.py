"""Responses ⇄ Chat Completions 桥：请求转译 + 流式/非流式回落。"""

from __future__ import annotations

import hashlib
import json
import time
import uuid

from .config import (
    _OC_SESSION_FALLBACK,
    _clamp_reasoning_effort,
)
from .toolfix import (
    _sanitize_fc_args,
)


def _content_parts_to_chat(content):
    """Responses content (str | list of parts) -> chat content (str | list)."""
    if content is None:
        return None
    if isinstance(content, str):
        return content
    text_bits, image_parts = [], []
    for part in content if isinstance(content, list) else []:
        if not isinstance(part, dict):
            continue
        ptype = part.get("type")
        if ptype in ("input_text", "output_text", "text") and isinstance(part.get("text"), str):
            text_bits.append(part["text"])
        elif ptype in ("input_image", "image_url"):
            url = part.get("image_url")
            if isinstance(url, dict):
                url = url.get("url")
            if isinstance(url, str) and url:
                image_parts.append({"type": "image_url", "image_url": {"url": url}})
    if image_parts:
        parts = []
        if text_bits:
            parts.append({"type": "text", "text": "\n".join(text_bits)})
        parts.extend(image_parts)
        return parts
    return "\n".join(text_bits) if text_bits else None


def _responses_request_to_chat(parsed):
    """Translate a Responses API request body into Chat Completions format."""
    messages = []
    instructions = parsed.get("instructions")
    if isinstance(instructions, str) and instructions.strip():
        messages.append({"role": "system", "content": instructions})
    raw_input = parsed.get("input")
    if isinstance(raw_input, str):
        items = [{"type": "message", "role": "user", "content": raw_input}]
    elif isinstance(raw_input, list):
        items = [i for i in raw_input if isinstance(i, dict)]
    else:
        items = []
    for item in items:
        itype = item.get("type") or "message"
        if itype == "message":
            role = item.get("role") or "user"
            if role == "developer":
                role = "system"
            messages.append({"role": role, "content": _content_parts_to_chat(item.get("content"))})
        elif itype in ("function_call", "custom_tool_call"):
            call = {
                "id": item.get("call_id") or item.get("id") or f"call_{uuid.uuid4().hex[:16]}",
                "type": "function",
                "function": {"name": item.get("name") or "", "arguments": item.get("arguments") or "{}"},
            }
            prev = messages[-1] if messages else None
            if prev and prev.get("role") == "assistant" and isinstance(prev.get("tool_calls"), list):
                prev["tool_calls"].append(call)
            else:
                messages.append({"role": "assistant", "content": None, "tool_calls": [call]})
        elif itype in ("function_call_output", "custom_tool_call_output"):
            output = item.get("output")
            if not isinstance(output, str):
                output = json.dumps(output, ensure_ascii=False)
            messages.append({"role": "tool", "tool_call_id": item.get("call_id"), "content": output})
        # reasoning / web_search_call / other item types are dropped silently
    tools = []
    for tool in parsed.get("tools") or []:
        if isinstance(tool, dict) and tool.get("type") == "function":
            fn = {"name": tool.get("name") or "",
                  "parameters": tool.get("parameters") or {"type": "object", "properties": {}}}
            if tool.get("description"):
                fn["description"] = tool["description"]
            tools.append({"type": "function", "function": fn})
    payload = {"model": parsed.get("model"), "messages": messages, "stream": bool(parsed.get("stream"))}
    if tools:
        payload["tools"] = tools
        choice = parsed.get("tool_choice")
        payload["tool_choice"] = choice if choice in ("auto", "none", "required") else "auto"
        if parsed.get("parallel_tool_calls") is not None:
            payload["parallel_tool_calls"] = bool(parsed.get("parallel_tool_calls"))
    reasoning = parsed.get("reasoning")
    effort = reasoning.get("effort") if isinstance(reasoning, dict) else None
    if effort:
        clamped = _clamp_reasoning_effort(parsed.get("model"), effort)
        payload["reasoning_effort"] = clamped
    # max_output_tokens intentionally NOT forwarded: capping would truncate thinking.
    return payload


def _chat_usage_to_responses(usage):
    usage = usage or {}
    prompt = usage.get("prompt_tokens") or 0
    completion = usage.get("completion_tokens") or 0
    return {
        "input_tokens": prompt,
        "input_tokens_details": {"cached_tokens": 0},
        "output_tokens": completion,
        "output_tokens_details": {"reasoning_tokens": 0},
        "total_tokens": usage.get("total_tokens") or (prompt + completion),
    }


def _parse_chat_stream_chunks(raw):
    """Aggregate chat-completions SSE bytes into (text, calls, finish_reason, usage)."""
    texts, calls, usage = [], {}, None
    finish_reason = None
    for line in raw.split(b"\n"):
        line = line.strip()
        if not line.startswith(b"data:"):
            continue
        data = line[5:].strip()
        if not data or data == b"[DONE]":
            continue
        try:
            chunk = json.loads(data)
        except json.JSONDecodeError:
            continue
        if isinstance(chunk.get("usage"), dict):
            usage = chunk["usage"]
        choices = chunk.get("choices") or []
        choice = choices[0] if choices else {}
        delta = choice.get("delta") or {}
        if isinstance(delta.get("content"), str):
            texts.append(delta["content"])
        elif isinstance(delta.get("content"), list):
            for part in delta["content"]:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    texts.append(part["text"])
        for tc in delta.get("tool_calls") or []:
            if not isinstance(tc, dict):
                continue
            idx = tc.get("index") or 0
            entry = calls.setdefault(idx, {"id": None, "name": "", "args": ""})
            if tc.get("id"):
                entry["id"] = tc["id"]
            fn = tc.get("function") or {}
            if fn.get("name"):
                entry["name"] += fn["name"]
            if isinstance(fn.get("arguments"), str):
                entry["args"] += fn["arguments"]
        if choice.get("finish_reason"):
            finish_reason = choice["finish_reason"]
    return "".join(texts), [calls[i] for i in sorted(calls)], finish_reason, usage


def _bridge_base_response(model, status="in_progress"):
    return {
        "id": "resp_" + uuid.uuid4().hex[:24],
        "object": "response",
        "created_at": int(time.time()),
        "status": status,
        "model": model,
        "output": [],
        "error": None,
        "incomplete_details": None,
        "usage": None,
        "metadata": {},
        "parallel_tool_calls": False,
    }


def _sse_data_frame(payload):
    payload = dict(payload)
    payload["sequence_number"] = _sse_data_frame.seq
    _sse_data_frame.seq += 1
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n".encode()


_sse_data_frame.seq = 1


def _build_chat_fallback_events(model, raw, effort=None):
    """Turn aggregated chat stream/JSON output into full Responses SSE bytes."""
    base = _bridge_base_response(model)
    frames = [_sse_data_frame({"type": "response.created", "response": base}),
              _sse_data_frame({"type": "response.in_progress", "response": base})]
    items_done, output_index = [], 0
    if isinstance(raw, bytes):
        text, call_list, _, usage = _parse_chat_stream_chunks(raw)
    else:
        obj = raw
        choice = (obj.get("choices") or [{}])[0]
        message = choice.get("message") or {}
        content = message.get("content")
        text = content if isinstance(content, str) else ""
        if not text and isinstance(content, list):
            text = "".join(p.get("text", "") for p in content if isinstance(p, dict))
        call_list = [{"id": tc.get("id"),
                      "name": ((tc.get("function") or {}).get("name") or ""),
                      "args": ((tc.get("function") or {}).get("arguments") or "")}
                     for tc in message.get("tool_calls") or []]
        usage = obj.get("usage")
    if text:
        msg_id = "msg_" + uuid.uuid4().hex[:24]
        added_item = {"id": msg_id, "type": "message", "status": "in_progress", "role": "assistant", "content": []}
        frames.append(_sse_data_frame({"type": "response.output_item.added", "output_index": output_index, "item": added_item}))
        empty_part = {"type": "output_text", "text": "", "annotations": []}
        frames.append(_sse_data_frame({"type": "response.content_part.added", "item_id": msg_id,
                                       "output_index": output_index, "content_index": 0, "part": empty_part}))
        frames.append(_sse_data_frame({"type": "response.output_text.delta", "item_id": msg_id,
                                       "output_index": output_index, "content_index": 0, "delta": text}))
        final_part = {"type": "output_text", "text": text, "annotations": []}
        frames.append(_sse_data_frame({"type": "response.output_text.done", "item_id": msg_id,
                                       "output_index": output_index, "content_index": 0, "text": text}))
        frames.append(_sse_data_frame({"type": "response.content_part.done", "item_id": msg_id,
                                       "output_index": output_index, "content_index": 0, "part": final_part}))
        done_item = dict(added_item, status="completed", content=[final_part])
        frames.append(_sse_data_frame({"type": "response.output_item.done", "output_index": output_index, "item": done_item}))
        items_done.append(done_item)
        output_index += 1
    for call in call_list:
        args = _sanitize_fc_args(call["args"] or "{}")
        call_id = call["id"] or ("call_" + uuid.uuid4().hex[:16])
        fc_id = "fc_" + uuid.uuid4().hex[:24]
        added_item = {"id": fc_id, "type": "function_call", "status": "in_progress",
                      "call_id": call_id, "name": call["name"], "arguments": ""}
        frames.append(_sse_data_frame({"type": "response.output_item.added", "output_index": output_index, "item": added_item}))
        frames.append(_sse_data_frame({"type": "response.function_call_arguments.delta", "item_id": fc_id,
                                       "output_index": output_index, "delta": args}))
        frames.append(_sse_data_frame({"type": "response.function_call_arguments.done", "item_id": fc_id,
                                       "output_index": output_index, "arguments": args}))
        done_item = dict(added_item, status="completed", arguments=args)
        frames.append(_sse_data_frame({"type": "response.output_item.done", "output_index": output_index, "item": done_item}))
        items_done.append(done_item)
        output_index += 1
    final = dict(base, status="completed", output=items_done, usage=_chat_usage_to_responses(usage))
    frames.append(_sse_data_frame({"type": "response.completed", "response": final}))
    return b"".join(frames)


def _build_chat_fallback_json(model, obj, effort=None):
    """Turn a non-streaming chat completion JSON into a Responses response object."""
    choice = (obj.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    content = message.get("content")
    text = content if isinstance(content, str) else ""
    if not text and isinstance(content, list):
        text = "".join(p.get("text", "") for p in content if isinstance(p, dict))
    call_list = [{"id": tc.get("id"),
                  "name": ((tc.get("function") or {}).get("name") or ""),
                  "args": ((tc.get("function") or {}).get("arguments") or "")}
                 for tc in message.get("tool_calls") or []]
    response = _bridge_base_response(model, status="completed")
    items = []
    if text:
        items.append({"id": "msg_" + uuid.uuid4().hex[:24], "type": "message", "status": "completed",
                      "role": "assistant",
                      "content": [{"type": "output_text", "text": text, "annotations": []}]})
    for call in call_list:
        items.append({"id": "fc_" + uuid.uuid4().hex[:24], "type": "function_call", "status": "completed",
                      "call_id": call["id"] or ("call_" + uuid.uuid4().hex[:16]),
                      "name": call["name"], "arguments": _sanitize_fc_args(call["args"] or "{}")})
    response["output"] = items
    response["usage"] = _chat_usage_to_responses(obj.get("usage"))
    return response


def _oc_session_id(parsed):
    """官方要求客户端在 x-opencode-session 里带一个稳定的会话 ID。

    Codex 不会发这个头，缺了它 messages 端点直接 400 MissingSessionID；
    这里用「instructions + 前几条消息 + 模型」的指纹生成，同一段对话稳定复用，
    不同对话互不串号（换会话不会命中同一个 ID）。
    """
    if not isinstance(parsed, dict):
        return _OC_SESSION_FALLBACK
    try:
        parts = []
        instructions = parsed.get("instructions")
        if isinstance(instructions, str) and instructions:
            parts.append(instructions[:2000])
        if isinstance(parsed.get("model"), str):
            parts.append(parsed["model"])
        for item in (parsed.get("input") or [])[:6]:
            if not isinstance(item, dict):
                continue
            content = item.get("content")
            if isinstance(content, str):
                parts.append(content[:400])
            elif isinstance(content, list):
                for part in content:
                    if isinstance(part, dict) and isinstance(part.get("text"), str):
                        parts.append(part["text"][:400])
        blob = "\n".join(parts) or _OC_SESSION_FALLBACK
        digest = hashlib.sha1(blob.encode("utf-8", "replace")).hexdigest()
        return f"{digest[:8]}-{digest[8:12]}-{digest[12:16]}-{digest[16:20]}-{digest[20:32]}"
    except Exception:
        return _OC_SESSION_FALLBACK


class ChatBridgeTranslator:
    """Incremental chat-completions SSE -> Responses SSE translator (fault-23 P3/P4/P5).

    Emits Responses frames as upstream deltas arrive (typewriter streaming) instead of
    buffering the whole stream. reasoning_content surfaces as a visible reasoning item
    (P4). A byte budget caps accumulated text (P5): exceeding it truncates gracefully.
    """

    def __init__(self, model, effort=None, byte_budget=16 * 1024 * 1024):
        self.model = model
        self.effort = effort
        self.byte_budget = byte_budget
        self.seq = 1
        self.resp_id = "resp_" + uuid.uuid4().hex[:24]
        self.created_at = int(time.time())
        self.output_index = 0
        self.msg = None          # {"id", "text"} while a message item is open
        self.reasoning = None    # {"id", "text"} while a reasoning item is open
        self.tools = {}          # index -> {"item_id","call_id","name","args","opened"}
        self.tool_order = []     # creation order of tool indices
        self.items_done = []
        self.usage = None
        self.finish_reason = None
        self.truncated = False
        self.finished = False

    # -- plumbing ---------------------------------------------------------
    def _frame(self, payload):
        payload = dict(payload)
        payload["sequence_number"] = self.seq
        self.seq += 1
        return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n".encode()

    def _snapshot(self, status="in_progress", output=None, usage=None):
        return {
            "id": self.resp_id, "object": "response", "created_at": self.created_at,
            "status": status, "model": self.model,
            "output": self.items_done if output is None else output,
            "error": None, "incomplete_details": None,
            "usage": usage if usage is not None else None,
            "metadata": {}, "parallel_tool_calls": False,
        }

    def _over_budget(self, extra):
        return self.total_len() + extra > self.byte_budget

    def total_len(self):
        n = 0
        if self.msg:
            n += len(self.msg["text"])
        if self.reasoning:
            n += len(self.reasoning["text"])
        for t in self.tools.values():
            n += len(t["args"])
        return n

    # -- lifecycle ----------------------------------------------------------
    def on_created(self):
        base = self._snapshot()
        return (self._frame({"type": "response.created", "response": base}) +
                self._frame({"type": "response.in_progress", "response": base}))

    def _close_message(self):
        if not self.msg:
            return b""
        m, self.msg = self.msg, None
        part = {"type": "output_text", "text": m["text"], "annotations": []}
        out = [self._frame({"type": "response.output_text.done", "item_id": m["id"],
                            "output_index": m["index"], "content_index": 0, "text": m["text"]}),
               self._frame({"type": "response.content_part.done", "item_id": m["id"],
                            "output_index": m["index"], "content_index": 0, "part": part})]
        done_item = {"id": m["id"], "type": "message", "status": "completed", "role": "assistant",
                     "content": [part]}
        out.append(self._frame({"type": "response.output_item.done",
                                "output_index": m["index"], "item": done_item}))
        self.items_done.append(done_item)
        self.output_index += 1
        return b"".join(out)

    def _close_reasoning(self):
        if not self.reasoning:
            return b""
        r, self.reasoning = self.reasoning, None
        summary = [{"type": "summary_text", "text": r["text"]}]
        out = [self._frame({"type": "response.reasoning_summary_text.done", "item_id": r["id"],
                            "output_index": r["index"], "summary_index": 0, "text": r["text"]}),
               self._frame({"type": "response.reasoning_summary_part.done", "item_id": r["id"],
                            "output_index": r["index"], "summary_index": 0,
                            "part": {"type": "summary_text", "text": r["text"]}})]
        done_item = {"id": r["id"], "type": "reasoning", "summary": summary, "encrypted_content": None}
        out.append(self._frame({"type": "response.output_item.done",
                                "output_index": r["index"], "item": done_item}))
        self.items_done.append(done_item)
        self.output_index += 1
        return b"".join(out)

    def _open_tool_if_needed(self, index, call_id, name):
        entry = self.tools.get(index)
        out = b""
        if entry is None:
            entry = {"item_id": "fc_" + uuid.uuid4().hex[:24],
                     "call_id": call_id or ("call_" + uuid.uuid4().hex[:16]),
                     "name": name or "", "args": "", "index": self.output_index}
            self.tools[index] = entry
            self.tool_order.append(index)
            item = {"id": entry["item_id"], "type": "function_call", "status": "in_progress",
                    "call_id": entry["call_id"], "name": entry["name"], "arguments": ""}
            out += self._frame({"type": "response.output_item.added",
                                "output_index": entry["index"], "item": item})
            self.output_index += 1
        elif name and not entry["name"]:
            entry["name"] = name
        return out

    def _close_tools(self):
        out = b""
        for index in list(self.tool_order):
            entry = self.tools.pop(index)
            args = _sanitize_fc_args(entry["args"] or "{}")
            out += self._frame({"type": "response.function_call_arguments.done",
                                "item_id": entry["item_id"], "output_index": entry["index"],
                                "arguments": args})
            done_item = {"id": entry["item_id"], "type": "function_call", "status": "completed",
                         "call_id": entry["call_id"], "name": entry["name"], "arguments": args}
            out += self._frame({"type": "response.output_item.done",
                                "output_index": entry["index"], "item": done_item})
            self.items_done.append(done_item)
        self.tool_order.clear()
        return out

    # -- upstream deltas -----------------------------------------------------
    def on_content_delta(self, text):
        if not text:
            return b""
        out = self._close_reasoning()
        if self._over_budget(len(text)):
            self.truncated = True
            return (out or b"") + self.on_finish("stop", self.usage)
        if not self.msg:
            mid = "msg_" + uuid.uuid4().hex[:24]
            self.msg = {"id": mid, "text": "", "index": self.output_index}
            out = (out or b"") + self._frame({"type": "response.output_item.added", "output_index": self.output_index,
                                              "item": {"id": mid, "type": "message", "status": "in_progress",
                                                       "role": "assistant", "content": []}})
            out += self._frame({"type": "response.content_part.added", "item_id": mid,
                                "output_index": self.msg["index"], "content_index": 0,
                                "part": {"type": "output_text", "text": "", "annotations": []}})
        self.msg["text"] += text
        out += self._frame({"type": "response.output_text.delta", "item_id": self.msg["id"],
                            "output_index": self.msg["index"], "content_index": 0, "delta": text})
        return out

    def on_reasoning_delta(self, text):
        if not text:
            return b""
        out = self._close_message()
        if self._over_budget(len(text)):
            return out or b""
        if not self.reasoning:
            rid = "rs_" + uuid.uuid4().hex[:24]
            self.reasoning = {"id": rid, "text": "", "index": self.output_index}
            out = (out or b"") + self._frame({"type": "response.output_item.added", "output_index": self.output_index,
                                              "item": {"id": rid, "type": "reasoning", "summary": [],
                                                       "encrypted_content": None}})
            out += self._frame({"type": "response.reasoning_summary_part.added", "item_id": rid,
                                "output_index": self.reasoning["index"], "summary_index": 0,
                                "part": {"type": "summary_text", "text": ""}})
        self.reasoning["text"] += text
        out += self._frame({"type": "response.reasoning_summary_text.delta", "item_id": self.reasoning["id"],
                            "output_index": self.reasoning["index"], "summary_index": 0, "delta": text})
        return out

    def on_tool_delta(self, index, call_id=None, name=None, args_delta=""):
        out = self._open_tool_if_needed(index, call_id, name)
        if args_delta:
            if self._over_budget(len(args_delta)):
                self.truncated = True
                return out + self.on_finish("tool_calls", self.usage)
            self.tools[index]["args"] += args_delta
            out += self._frame({"type": "response.function_call_arguments.delta",
                                "item_id": self.tools[index]["item_id"],
                                "output_index": self.tools[index]["index"], "delta": args_delta})
        return out

    def on_chat_frame(self, frame_bytes):
        """Parse one upstream SSE frame; return concatenated Responses frames."""
        data_lines = []
        for line in frame_bytes.decode(errors="replace").split("\n"):
            line = line.strip()
            if line.startswith("data:"):
                data_lines.append(line[5:].strip())
        out = b""
        for data in data_lines:
            if not data or data == "[DONE]":
                continue
            try:
                chunk = json.loads(data)
            except json.JSONDecodeError:
                continue
            if not isinstance(chunk, dict):
                continue
            if isinstance(chunk.get("usage"), dict):
                self.usage = chunk["usage"]
            choices = chunk.get("choices") or []
            choice = choices[0] if choices else {}
            delta = choice.get("delta") or {}
            if isinstance(delta.get("content"), str) and delta["content"]:
                out += self.on_content_delta(delta["content"])
            elif isinstance(delta.get("content"), list):
                for part in delta["content"]:
                    if isinstance(part, dict) and isinstance(part.get("text"), str):
                        out += self.on_content_delta(part["text"])
            if isinstance(delta.get("reasoning_content"), str) and delta["reasoning_content"]:
                out += self.on_reasoning_delta(delta["reasoning_content"])
            elif isinstance(delta.get("reasoning"), str) and delta["reasoning"]:
                out += self.on_reasoning_delta(delta["reasoning"])
            for tc in delta.get("tool_calls") or []:
                if not isinstance(tc, dict):
                    continue
                fn = tc.get("function") or {}
                out += self.on_tool_delta(tc.get("index") or 0, tc.get("id"),
                                          fn.get("name"),
                                          fn.get("arguments") if isinstance(fn.get("arguments"), str) else "")
            if choice.get("finish_reason"):
                self.finish_reason = choice["finish_reason"]
        return out

    def on_finish(self, finish_reason=None, usage=None):
        """Close every open item and emit the terminal frame. Idempotent."""
        if self.finished:
            return b""
        self.finished = True
        if finish_reason:
            self.finish_reason = finish_reason
        if usage:
            self.usage = usage
        out = (self._close_reasoning() or b"") + (self._close_message() or b"") + self._close_tools()
        status = "incomplete" if self.truncated else "completed"
        final = self._snapshot(status=status, usage=_chat_usage_to_responses(self.usage))
        final["incomplete_details"] = ({"reason": "max_output_tokens"} if self.truncated else None)
        out += self._frame({"type": "response.completed", "response": final})
        return out
