"""SSE 流改写引擎：分帧、重建、apply_patch 参数落盘、整体重写。"""

from __future__ import annotations

import json

from .apply_patch import (
    _extract_apply_patch_input,
    _is_apply_patch_name,
)
from .config import (
    _MUSE_STALL_MARKERS,
    _log,
)
from .muse import (
    _fix_namespaced_tool_name,
    _is_muse_model,
    _split_muse_namespaced_items,
    _sse_state_model,
)
from .toolfix import (
    _coerce_float_ints_in_args_str,
    _fc_args_broken,
    _repair_json_object_args,
)


def _iter_sse_data_frames(body):
    """Yield 一个已缓冲 SSE body 里的每个 JSON data 帧（解不出来就跳过）。"""
    try:
        text = body.decode("utf-8", errors="replace")
    except Exception:
        return
    for block in text.split("\n\n"):
        for line in block.splitlines():
            if line.startswith("data:"):
                try:
                    payload = json.loads(line[5:].strip())
                except Exception:
                    payload = None
                if isinstance(payload, dict):
                    yield payload
                break


def _sse_output_signals(body):
    """返回 (has_tool_call, output_text)，只看模型真正产出的事件。

    绝不能扫原始 body 判断措辞：response.created 会把 instructions 原样回显回来，
    而我们注入的约束里就写着「正在修」这类词，扫原始文本会把每个响应都判成空转。
    """
    has_tool_call = False
    texts = []
    for frame in _iter_sse_data_frames(body):
        etype = frame.get("type")
        if etype in ("response.output_item.added", "response.output_item.done"):
            item = frame.get("item")
            if isinstance(item, dict) and item.get("type") in ("function_call", "custom_tool_call"):
                has_tool_call = True
        elif etype == "response.output_text.delta":
            delta = frame.get("delta")
            if isinstance(delta, str):
                texts.append(delta)
        elif etype in ("response.completed", "response.failed", "response.incomplete"):
            response_obj = frame.get("response")
            if not isinstance(response_obj, dict):
                continue
            for item in response_obj.get("output") or []:
                if not isinstance(item, dict):
                    continue
                if item.get("type") in ("function_call", "custom_tool_call"):
                    has_tool_call = True
                elif item.get("type") == "message":
                    for part in item.get("content") or []:
                        if isinstance(part, dict) and isinstance(part.get("text"), str):
                            texts.append(part["text"])
    return has_tool_call, "".join(texts)


def _sse_has_terminal_event(body):
    return any(frame.get("type") in ("response.completed", "response.failed", "response.incomplete")
               for frame in _iter_sse_data_frames(body))


def _sse_looks_like_stall(body):
    """判断一次 Muse 响应是不是「只叙述、不调用工具」的空转。

    没有终态事件（真截断）不算——那种情况下面有 response.failed 兜底，重发只会白花钱。
    """
    if b"data:" not in body or not _sse_has_terminal_event(body):
        return False
    has_tool_call, text = _sse_output_signals(body)
    if has_tool_call:
        return False
    stripped = text.strip()
    if not stripped:
        return True
    if len(stripped) > 300:
        return False
    return any(marker in stripped for marker in _MUSE_STALL_MARKERS)


def _sse_event(event_type, payload):
    return f"event: {event_type}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n".encode()


def _split_sse_frame(buffer, max_buffered=8 * 1024 * 1024):
    """Return (frame_bytes|None, rest). The frame INCLUDES its trailing
    delimiter so passthrough stays byte-identical. If no delimiter and the
    buffer exceeds the cap, return the whole buffer as a raw frame to avoid
    stalling (fail-safe)."""
    if len(buffer) > max_buffered:
        raw = bytes(buffer)
        return raw, bytearray()
    for delim in (b"\n\n", b"\r\n\r\n"):
        index = buffer.find(delim)
        if index != -1:
            frame = bytes(buffer[:index + len(delim)])
            rest = bytearray(buffer[index + len(delim):])
            return frame, rest
    return None, buffer


def _flush_apply_patch(entry, interrupted=False):
    """Emit custom_tool_call wire for one tracked apply_patch call."""
    try:
        input_text = _extract_apply_patch_input(entry.get("args_acc"))
        item_id = entry.get("item_id")
        call_id = entry.get("call_id") or item_id
        name = entry.get("name") or "apply_patch"
        output_index = entry.get("output_index", 0)
        if interrupted:
            if "*** Begin Patch" in input_text and "*** End Patch" in input_text:
                _log(f"[vision-proxy] apply_patch interrupted but complete, applying item_id={item_id} input_len={len(input_text)}")
            else:
                # Codex 0.146 ignores custom_tool_call status and would execute
                # the truncated arguments, polluting tool history with a parse
                # failure. The item was announced with empty input; dropping the
                # terminal frame keeps the interrupted call inert.
                _log(f"[vision-proxy] apply_patch interrupted with incomplete patch, dropping item_id={item_id} args_len={len(entry.get('args_acc') or '')}")
                return []
        if not input_text.strip():
            _log(f"[vision-proxy] apply_patch flush EMPTY item_id={item_id}")
            return []
        frames = [
            _sse_event("response.custom_tool_call_input.delta", {
                "type": "response.custom_tool_call_input.delta", "item_id": item_id,
                "output_index": output_index, "call_id": call_id, "delta": input_text}),
            _sse_event("response.custom_tool_call_input.done", {
                "type": "response.custom_tool_call_input.done", "item_id": item_id,
                "output_index": output_index, "call_id": call_id, "input": input_text}),
            _sse_event("response.output_item.done", {
                "type": "response.output_item.done", "output_index": output_index,
                "item": {"type": "custom_tool_call", "id": item_id, "call_id": call_id,
                         "name": name, "input": input_text, "status": "completed"}}),
        ]
        _log(f"[vision-proxy] apply_patch flush OK item_id={item_id} input_len={len(input_text)}")
        return frames
    except Exception as exc:
        _log(f"[vision-proxy] apply_patch flush failed, announced item may hang: {exc!r}")
        return []


def _rebuild_sse_frame(frame, payload, etype):
    """Re-serialize one parsed SSE frame after a targeted payload mutation.

    Preserves the original framing style (bare `data:` vs `event:`+`data:`).
    sequence_number lives inside payload and is kept as-is. Callers only
    invoke this after a successful mutation, so the frame always changes.
    """
    try:
        text = frame.decode("utf-8", errors="replace")
    except Exception:
        text = ""
    data = json.dumps(payload, ensure_ascii=False)
    if any(line.startswith("event:") for line in text.splitlines()):
        return [f"event: {etype}\ndata: {data}\n\n".encode()]
    return [f"data: {data}\n\n".encode()]


def _rewrite_sse_frame(frame, state):
    """One SSE frame. Fail-safe: any anomaly returns the raw frame bytes.

    state: {"pending": {item_id: entry}, "completed": bool}
    """
    pending = state["pending"]
    flushed = state.setdefault("flushed", set())
    try:
        if state.get("completed") or not frame.strip():
            return [frame]
        text = frame.decode("utf-8", errors="replace")
        event = None
        data_lines = []
        for line in text.splitlines():
            line = line.rstrip("\r")
            if line.startswith("event:"):
                event = line[6:].strip()
            elif line.startswith("data:"):
                data_lines.append(line[5:].strip())
        if not data_lines:
            return [frame]
        try:
            payload = json.loads("\n".join(data_lines))
        except json.JSONDecodeError:
            return [frame]
        if not isinstance(payload, dict):
            return [frame]
        etype = payload.get("type") or event

        if etype == "response.completed" or etype == "response.failed" or etype == "response.incomplete":
            state["completed"] = True
            terminal_renamed = False
            if _is_muse_model(_sse_state_model(state)):
                response_obj = payload.get("response")
                if isinstance(response_obj, dict):
                    terminal_renamed = _split_muse_namespaced_items(response_obj.get("output"))
            out = []
            for item_id, entry in list(pending.items()):
                pending.pop(item_id, None)
                state.setdefault("flushed", set()).add(item_id)
                _log(f"[vision-proxy] apply_patch call interrupted by terminal event item_id={item_id}")
                out.extend(_flush_apply_patch(entry, interrupted=True))
            out.extend(_rebuild_sse_frame(frame, payload, etype) if terminal_renamed else [frame])
            return out

        if etype == "response.output_item.added":
            item = payload.get("item") or {}
            if _is_muse_model(_sse_state_model(state)) and _fix_namespaced_tool_name(item):
                _log("[vision-proxy] muse namespaced tool call split (stream added)")
                return _rebuild_sse_frame(frame, payload, etype)
            name = item.get("name") or ""
            if item.get("type") == "function_call" and _is_apply_patch_name(name):
                item_id = item.get("id")
                entry = {
                    "item_id": item_id,
                    "call_id": item.get("call_id") or item_id,
                    "name": name,
                    "args_acc": "",
                    "output_index": payload.get("output_index", 0),
                }
                if item_id:
                    pending[item_id] = entry
                else:
                    _log("[vision-proxy] apply_patch function_call without item id; cannot track stream")
                new_item = dict(item)
                new_item["type"] = "custom_tool_call"
                new_item["input"] = ""
                new_item.pop("arguments", None)
                new_payload = dict(payload)
                new_payload["item"] = new_item
                return [_sse_event("response.output_item.added", new_payload)]
            return [frame]

        if etype == "response.function_call_arguments.delta":
            entry = pending.get(payload.get("item_id"))
            if entry is not None:
                delta = payload.get("delta")
                if not isinstance(delta, str):
                    _log(f"[vision-proxy] non-string function delta, forwarding raw: {type(delta).__name__}")
                    return [frame]
                entry["args_acc"] += delta
                return []
            return [frame]

        if etype == "response.function_call_arguments.done":
            item_id = payload.get("item_id")
            entry = pending.pop(item_id, None)
            if entry is not None:
                arguments = payload.get("arguments")
                if isinstance(arguments, str):
                    entry["args_acc"] = arguments
                flushed.add(item_id)
                return _flush_apply_patch(entry, interrupted=False)
            # Untracked generic call (e.g. Muse exec_command): coerce floats
            # in place so the Codex executor accepts the arguments.
            arguments = payload.get("arguments")
            if isinstance(arguments, str):
                fixed = _coerce_float_ints_in_args_str(arguments)
                if fixed != arguments:
                    payload["arguments"] = fixed
                    return _rebuild_sse_frame(frame, payload, etype)
            return [frame]

        if etype == "response.output_item.done":
            item = payload.get("item") or {}
            item_renamed = _is_muse_model(_sse_state_model(state)) and _fix_namespaced_tool_name(item)
            if item_renamed:
                _log("[vision-proxy] muse namespaced tool call split (stream done)")
            name = item.get("name") or ""
            if item.get("type") == "function_call" and _is_apply_patch_name(name):
                item_id = item.get("id")
                if item_id in flushed:
                    return []  # already flushed at function_call_arguments.done
                entry = pending.pop(item_id, None)
                interrupted = item.get("status") == "incomplete" or payload.get("status") == "incomplete"
                if entry is None:
                    # Untracked: convert directly from the final item (still fail-safe for parsing).
                    entry = {
                        "item_id": item_id,
                        "call_id": item.get("call_id") or item_id,
                        "name": name,
                        "args_acc": item.get("arguments") if isinstance(item.get("arguments"), str) else "",
                        "output_index": payload.get("output_index", 0),
                    }
                else:
                    arguments = item.get("arguments")
                    if isinstance(arguments, str):
                        entry["args_acc"] = arguments
                flushed.add(item_id)
                return _flush_apply_patch(entry, interrupted=interrupted)
            if item.get("type") == "function_call":
                # Untracked generic call: same float->int normalization as the
                # arguments.done branch (covers upstreams that only send the
                # terminal item frame).
                arguments = item.get("arguments")
                if isinstance(arguments, str):
                    fixed = _coerce_float_ints_in_args_str(arguments)
                    if fixed != arguments:
                        item["arguments"] = fixed
                        return _rebuild_sse_frame(frame, payload, etype)
            return _rebuild_sse_frame(frame, payload, etype) if item_renamed else [frame]

        return [frame]
    except Exception as exc:
        _log(f"[vision-proxy] sse frame rewrite failed, forwarding raw: {exc!r}")
        return [frame]


def _rewrite_sse_body(body):
    """Run the frame bridge over a fully buffered SSE body. Fail-safe: any
    anomaly keeps the raw frame; used when the response must be buffered
    anyway (e.g. --inject-reasoning-summary)."""
    state = {"pending": {}, "completed": False}
    buffer = bytearray(body)
    out = bytearray()
    while True:
        frame, rest = _split_sse_frame(buffer)
        if frame is None:
            break
        buffer = rest
        for compat_frame in _complete_sse_frame(frame, state):
            for out_frame in _rewrite_sse_frame(compat_frame, state):
                out.extend(out_frame)
    if buffer:
        for compat_frame in _complete_sse_frame(bytes(buffer), state):
            for out_frame in _rewrite_sse_frame(compat_frame, state):
                out.extend(out_frame)
    compat = state.get("compat")
    if compat and compat.get("started") and not compat.get("saw_created") and not state.get("completed"):
        close_frame = b"event: response.completed\ndata: {\"type\": \"response.completed\"}\n\n"
        for compat_frame in _complete_sse_frame(close_frame, state):
            for out_frame in _rewrite_sse_frame(compat_frame, state):
                out.extend(out_frame)
    for item_id, entry in list(state["pending"].items()):
        state["pending"].pop(item_id, None)
        state.setdefault("flushed", set()).add(item_id)
        _log(f"[vision-proxy] apply_patch stream ended mid-call item_id={item_id}")
        for out_frame in _flush_apply_patch(entry, interrupted=True):
            out.extend(out_frame)
    return bytes(out)


def _complete_sse_frame(frame, state):
    """Repair chat-adapted zen/go streams (mimo/glm/kimi/hy3) that omit the
    standard Responses SSE envelope: no response.created/in_progress, and
    output_text.delta / function_call_arguments.delta events without
    item_id. Codex cannot render such a stream (UI completes with no text
    and tool calls never fire), so we synthesize the missing envelope:
      - response.created + response.in_progress once per stream
      - response.output_item.added (message) + content_part.added before the
        first output_text.delta, and a matching done triplet at stream end
      - an item_id on every delta/done event so the client and the
        apply_patch bridge can correlate frames
    Streams that already carry response.created pass through untouched.
    Fail-safe: any anomaly returns the raw frame."""
    compat = state.setdefault("compat", {})
    if compat.get("saw_created"):
        return [frame]
    try:
        text = frame.decode("utf-8", errors="replace")
        event = None
        data_lines = []
        for line in text.splitlines():
            line = line.rstrip("\r")
            if line.startswith("event:"):
                event = line[6:].strip()
            elif line.startswith("data:"):
                data_lines.append(line[5:].strip())
        if not data_lines:
            return [frame]
        payload = json.loads("\n".join(data_lines))
        if not isinstance(payload, dict):
            return [frame]
        etype = payload.get("type") or event
        if etype == "response.created":
            compat["saw_created"] = True
            return [frame]
        if not etype:
            return [frame]

        out = []
        seq = compat.get("seq", 0)

        def ensure_started(response_id, model):
            nonlocal seq
            if compat.get("started"):
                return
            compat["started"] = True
            response_obj = {
                "id": response_id or "gen-compat",
                "object": "response",
                "status": "in_progress",
                "model": model or "unknown",
                "output": [],
            }
            out.append(_sse_event("response.created", {
                "type": "response.created", "sequence_number": seq,
                "response": response_obj}))
            out.append(_sse_event("response.in_progress", {
                "type": "response.in_progress", "sequence_number": seq + 1,
                "response": response_obj}))
            seq += 2
            compat["seq"] = seq

        rid = (payload.get("response") or {}).get("id") or payload.get("id")
        rmodel = (payload.get("response") or {}).get("model") or payload.get("model")

        def close_message():
            nonlocal seq
            item = compat.get("msg_item")
            if not item or item.get("done"):
                return
            item["done"] = True
            text_acc = item.get("text", "")
            item_id = item["item_id"]
            output_index = item["output_index"]
            out.append(_sse_event("response.output_text.done", {
                "type": "response.output_text.done", "sequence_number": seq,
                "item_id": item_id, "output_index": output_index, "content_index": 0,
                "text": text_acc, "annotations": []}))
            out.append(_sse_event("response.content_part.done", {
                "type": "response.content_part.done", "sequence_number": seq + 1,
                "item_id": item_id, "output_index": output_index, "content_index": 0,
                "part": {"type": "output_text", "text": text_acc, "annotations": []}}))
            out.append(_sse_event("response.output_item.done", {
                "type": "response.output_item.done", "sequence_number": seq + 2,
                "output_index": output_index,
                "item": {"id": item_id, "type": "message", "status": "completed",
                         "role": "assistant",
                         "content": [{"type": "output_text", "text": text_acc, "annotations": []}]}}))
            seq += 3
            compat["seq"] = seq

        def close_function_call():
            nonlocal seq
            item = compat.get("fc_item")
            if not item or item.get("done"):
                return
            item["done"] = True
            item_id = item["item_id"]
            output_index = item["output_index"]
            repaired = _repair_json_object_args(item.get("args_acc", ""))
            if repaired != item.get("args_acc", ""):
                _log(f"[vision-proxy] repaired fc args at stream close item_id={item_id} "
                     f"model={compat.get('model')}")
            out.append(_sse_event("response.function_call_arguments.done", {
                "type": "response.function_call_arguments.done", "sequence_number": seq,
                "item_id": item_id, "output_index": output_index,
                "arguments": repaired}))
            out.append(_sse_event("response.output_item.done", {
                "type": "response.output_item.done", "sequence_number": seq + 1,
                "output_index": output_index,
                "item": {"id": item_id, "type": "function_call", "status": "completed",
                         "name": item.get("name") or "tool", "call_id": item.get("call_id") or item_id,
                         "arguments": repaired}}))
            seq += 2
            compat["seq"] = seq

        if etype == "response.output_text.delta":
            ensure_started(rid, rmodel)
            if not compat.get("msg_item"):
                item_id = f"msg_{compat.get('seq', 0)}"
                output_index = compat.get("next_index", 0)
                compat["msg_item"] = {"item_id": item_id, "output_index": output_index,
                                      "text": "", "done": False}
                out.append(_sse_event("response.output_item.added", {
                    "type": "response.output_item.added", "sequence_number": seq,
                    "output_index": output_index,
                    "item": {"id": item_id, "type": "message", "status": "in_progress",
                             "role": "assistant",
                             "content": [{"type": "output_text", "text": "", "annotations": []}]}}))
                out.append(_sse_event("response.content_part.added", {
                    "type": "response.content_part.added", "sequence_number": seq + 1,
                    "item_id": item_id, "output_index": output_index, "content_index": 0,
                    "part": {"type": "output_text", "text": "", "annotations": []}}))
                seq += 2
                compat["seq"] = seq
            item = compat["msg_item"]
            delta = payload.get("delta", "")
            if isinstance(delta, str):
                item["text"] += delta
            new_payload = dict(payload)
            new_payload["item_id"] = item["item_id"]
            new_payload["output_index"] = item["output_index"]
            new_payload["content_index"] = 0
            out.append(_sse_event("response.output_text.delta", new_payload))
            return out

        if etype == "response.output_item.added":
            item = payload.get("item") or {}
            if item.get("type") == "function_call":
                ensure_started(rid or item.get("id"), rmodel)
                item_id = item.get("id") or f"fc_{compat.get('seq', 0)}"
                output_index = payload.get("output_index", compat.get("next_index", 0) or 0)
                compat["fc_item"] = {
                    "item_id": item_id,
                    "output_index": output_index,
                    "name": item.get("name"),
                    "call_id": item.get("call_id") or item_id,
                    "args_acc": item.get("arguments") if isinstance(item.get("arguments"), str) else "",
                    "done": False,
                }
            return [frame]

        if etype == "response.function_call_arguments.delta":
            ensure_started(rid, rmodel)
            item = compat.get("fc_item")
            if not item:
                item_id = f"fc_{compat.get('seq', 0)}"
                output_index = compat.get("next_index", 1) or 1
                compat["fc_item"] = {"item_id": item_id, "output_index": output_index,
                                     "name": None, "call_id": None,
                                     "args_acc": "", "done": False}
                item = compat["fc_item"]
                out.append(_sse_event("response.output_item.added", {
                    "type": "response.output_item.added", "sequence_number": seq,
                    "output_index": output_index,
                    "item": {"id": item_id, "type": "function_call", "status": "in_progress",
                             "name": "unknown", "call_id": item_id, "arguments": ""}}))
                seq += 1
                compat["seq"] = seq
            delta = payload.get("delta", "")
            if isinstance(delta, str):
                item["args_acc"] += delta
            new_payload = dict(payload)
            new_payload["item_id"] = item["item_id"]
            new_payload["output_index"] = item["output_index"]
            out.append(_sse_event("response.function_call_arguments.delta", new_payload))
            return out

        if etype == "response.function_call_arguments.done":
            item = compat.get("fc_item")
            if item:
                if isinstance(payload.get("arguments"), str):
                    item["args_acc"] = payload["arguments"]
                raw_args = payload.get("arguments")
                new_payload = dict(payload)
                new_payload["item_id"] = item["item_id"]
                new_payload["output_index"] = item["output_index"]
                if _fc_args_broken(raw_args):
                    repaired = _repair_json_object_args(raw_args)
                    if repaired != raw_args:
                        _log(f"[vision-proxy] repaired fc args in arguments.done item_id={item['item_id']} "
                             f"model={compat.get('model')} broken={raw_args[:60]!r}")
                        new_payload["arguments"] = repaired
                        return [_sse_event("response.function_call_arguments.done", new_payload)]
                return [_sse_event("response.function_call_arguments.done", new_payload)]
            # no tracked fc_item (e.g. args.done without prior added/delta): repair in place
            raw_args = payload.get("arguments")
            if _fc_args_broken(raw_args):
                repaired = _repair_json_object_args(raw_args)
                if repaired != raw_args:
                    _log(f"[vision-proxy] repaired fc args in arguments.done (untracked) "
                         f"broken={raw_args[:60]!r}")
                    new_payload = dict(payload)
                    new_payload["arguments"] = repaired
                    return [_sse_event("response.function_call_arguments.done", new_payload)]
            return [frame]

        if etype in ("response.completed", "response.failed", "response.incomplete"):
            if compat.get("started"):
                close_message()
                close_function_call()
            out.append(frame)
            return out

        if etype == "response.output_item.done":
            item = payload.get("item") or {}
            if item.get("type") == "function_call" and compat.get("fc_item"):
                compat["fc_item"]["done"] = True
            if item.get("type") == "function_call" and _fc_args_broken(item.get("arguments")):
                repaired = _repair_json_object_args(item.get("arguments"))
                if repaired != item.get("arguments"):
                    _log(f"[vision-proxy] repaired fc args in output_item.done call_id={item.get('call_id')} "
                         f"model={compat.get('model')} broken={str(item.get('arguments'))[:60]!r}")
                    new_payload = dict(payload)
                    fixed_item = dict(item)
                    fixed_item["arguments"] = repaired
                    new_payload["item"] = fixed_item
                    return [_sse_event("response.output_item.done", new_payload)]
            return [frame]

        if etype in ("response.output_text.done", "response.output_text.delta.any", "response.content_part.added"):
            return [frame]

        return [frame]
    except Exception as exc:
        _log(f"[vision-proxy] sse envelope completion failed, forwarding raw: {exc!r}")
        return [frame]
