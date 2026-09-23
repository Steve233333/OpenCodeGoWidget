"""SSE 流改写引擎：分帧、重建、apply_patch 参数落盘、整体重写。"""

from __future__ import annotations

import json
import time

from .apply_patch import (
    _extract_apply_patch_input,
    _is_apply_patch_name,
)
from .config import (
    MUSE_STALL_TEXT_LIMIT,
    SSE_MAX_BUFFERED_FRAME,
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
    if len(stripped) > MUSE_STALL_TEXT_LIMIT:
        return False
    return any(marker in stripped for marker in _MUSE_STALL_MARKERS)


def _sse_event(event_type, payload):
    return f"event: {event_type}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n".encode()


def _split_sse_frame(buffer, max_buffered=SSE_MAX_BUFFERED_FRAME):
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


def _item_identity(payload):
    """输出项的身份：output_index 在同一个项的 added/done 之间是稳定的，优先用它；
    没有就退回 item.id / item_id。"""
    idx = payload.get("output_index")
    if isinstance(idx, int):
        return f"#{idx}"
    item = payload.get("item")
    if isinstance(item, dict) and item.get("id"):
        return str(item["id"])
    return str(payload.get("item_id") or "")


def sse_turn_looks_complete(state):
    """上游没发终止事件时，判断"这一轮内容是不是已经完整"。

    判据（对齐 opencodex 的 modelResponsesTerminalRepair）：**开过的每个输出项都收到过
    `response.output_item.done`，且至少有一个项**。满足就说明内容是完整的，只是缺终止帧 ——
    该补 `response.completed` 收尾，而不是把这一轮判成"中断"（muse-spark 在 Go/Zen 网关常见）。
    """
    done = state.get("items_done") or set()
    still_open = state.get("items_open") or set()
    return bool(done) and not still_open


def _parse_sse_frame(frame):
    """帧字节 → (etype, payload)；解析不出来返回 None（调用方原样转发）。"""
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
        return None
    try:
        payload = json.loads("\n".join(data_lines))
    except json.JSONDecodeError:
        return None
    if not isinstance(payload, dict):
        return None
    return payload.get("type") or event, payload


def _track_item_state(state, etype, payload):
    """追踪"开过几个输出项、关掉几个"：上游不发终止帧时靠它判断内容是否已完整
    （2026-09-23，见 sse_turn_looks_complete 的说明）。"""
    if etype == "response.output_item.added":
        state.setdefault("items_open", set()).add(_item_identity(payload))
    elif etype == "response.output_item.done":
        identity = _item_identity(payload)
        state.setdefault("items_open", set()).discard(identity)
        state.setdefault("items_done", set()).add(identity)
        item = payload.get("item")
        if isinstance(item, dict):
            # 留一份完成的项：上游不发终止帧时，补的 response.completed 里要带上 output
            state.setdefault("completed_items", []).append(item)


def _rf_terminal(frame, payload, etype, state):
    """终止帧：标记 completed，收掉未完成的 apply_patch，必要时改回命名空间工具名。"""
    pending = state["pending"]
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


def _rf_output_item_added(frame, payload, etype, state):
    """新增输出项：muse 命名空间工具改名；apply_patch 转成 custom_tool_call 并开始攒参数。"""
    pending = state["pending"]
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


def _rf_fc_args_delta(frame, payload, etype, state):
    """apply_patch 的参数增量：只吃不发（等 done 再一次性落盘）。"""
    pending = state["pending"]
    entry = pending.get(payload.get("item_id"))
    if entry is not None:
        delta = payload.get("delta")
        if not isinstance(delta, str):
            _log(f"[vision-proxy] non-string function delta, forwarding raw: {type(delta).__name__}")
            return [frame]
        entry["args_acc"] += delta
        return []
    return [frame]


def _rf_fc_args_done(frame, payload, etype, state):
    """apply_patch 参数结束：落盘；未跟踪的通用调用只做 float→int 归一。"""
    pending = state["pending"]
    flushed = state.setdefault("flushed", set())
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


def _rf_output_item_done(frame, payload, etype, state):
    """输出项结束：muse 改名；apply_patch 落盘；通用 function_call 只做参数归一。"""
    pending = state["pending"]
    flushed = state.setdefault("flushed", set())
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


# 帧类型 → 处理器（顺序不敏感：按类型查表；没登记的帧一律原样转发）
_FRAME_HANDLERS = {
    "response.completed": _rf_terminal,
    "response.failed": _rf_terminal,
    "response.incomplete": _rf_terminal,
    "response.output_item.added": _rf_output_item_added,
    "response.function_call_arguments.delta": _rf_fc_args_delta,
    "response.function_call_arguments.done": _rf_fc_args_done,
    "response.output_item.done": _rf_output_item_done,
}


def _rewrite_sse_frame(frame, state):
    """一帧 SSE：解析 → 记账 → 按帧类型查表处理 → 没认领就原样字节转发。

    **不可变约束**：这里只做白名单改写，任何异常/没登记的帧都必须返回原字节
    （`tests/test_sse_golden.py` 用重构前的逐帧输出把它钉住了）。
    state: {"pending": {item_id: entry}, "completed": bool, ...}
    """
    try:
        if state.get("completed") or not frame.strip():
            return [frame]
        # 老实现会在函数开头就建好 flushed（哪怕这一帧根本不认领）；保持同一份状态形状，
        # 免得基线和其它读 state 的代码看到不同的键集合。
        state.setdefault("flushed", set())
        parsed = _parse_sse_frame(frame)
        if parsed is None:
            return [frame]
        etype, payload = parsed
        _track_item_state(state, etype, payload)
        handler = _FRAME_HANDLERS.get(etype)
        if handler is None:
            return [frame]
        return handler(frame, payload, etype, state)
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


class _ChatCompatCtx:
    """chat 适配流的"补帧"上下文（原先挤在 _complete_sse_frame 里的三个闭包）。

    compat 是跨帧状态（state["compat"]）；out 是本帧要吐的帧；seq 是 sequence_number 计数器 ——
    三者都归这个对象所有，别再散在函数体里各改一份。
    """

    def __init__(self, compat):
        self.compat = compat
        self.out = []
        self.seq = compat.get("seq", 0)

    def ensure_started(self, response_id, model):
        if self.compat.get("started"):
            return
        self.compat["started"] = True
        response_obj = {
            "id": response_id or "gen-self.compat",
            "object": "response",
            "status": "in_progress",
            "model": model or "unknown",
            "output": [],
        }
        self.out.append(_sse_event("response.created", {
            "type": "response.created", "sequence_number": self.seq,
            "response": response_obj}))
        self.out.append(_sse_event("response.in_progress", {
            "type": "response.in_progress", "sequence_number": self.seq + 1,
            "response": response_obj}))
        self.seq += 2
        self.compat["seq"] = self.seq

    def close_message(self, ):
        item = self.compat.get("msg_item")
        if not item or item.get("done"):
            return
        item["done"] = True
        text_acc = item.get("text", "")
        item_id = item["item_id"]
        output_index = item["output_index"]
        self.out.append(_sse_event("response.output_text.done", {
            "type": "response.output_text.done", "sequence_number": self.seq,
            "item_id": item_id, "output_index": output_index, "content_index": 0,
            "text": text_acc, "annotations": []}))
        self.out.append(_sse_event("response.content_part.done", {
            "type": "response.content_part.done", "sequence_number": self.seq + 1,
            "item_id": item_id, "output_index": output_index, "content_index": 0,
            "part": {"type": "output_text", "text": text_acc, "annotations": []}}))
        self.out.append(_sse_event("response.output_item.done", {
            "type": "response.output_item.done", "sequence_number": self.seq + 2,
            "output_index": output_index,
            "item": {"id": item_id, "type": "message", "status": "completed",
                     "role": "assistant",
                     "content": [{"type": "output_text", "text": text_acc, "annotations": []}]}}))
        self.seq += 3
        self.compat["seq"] = self.seq

    def close_function_call(self, ):
        item = self.compat.get("fc_item")
        if not item or item.get("done"):
            return
        item["done"] = True
        item_id = item["item_id"]
        output_index = item["output_index"]
        repaired = _repair_json_object_args(item.get("args_acc", ""))
        if repaired != item.get("args_acc", ""):
            _log(f"[vision-proxy] repaired fc args at stream close item_id={item_id} "
                 f"model={self.compat.get('model')}")
        self.out.append(_sse_event("response.function_call_arguments.done", {
            "type": "response.function_call_arguments.done", "sequence_number": self.seq,
            "item_id": item_id, "output_index": output_index,
            "arguments": repaired}))
        self.out.append(_sse_event("response.output_item.done", {
            "type": "response.output_item.done", "sequence_number": self.seq + 1,
            "output_index": output_index,
            "item": {"id": item_id, "type": "function_call", "status": "completed",
                     "name": item.get("name") or "tool", "call_id": item.get("call_id") or item_id,
                     "arguments": repaired}}))
        self.seq += 2
        self.compat["seq"] = self.seq

    def _on_text_delta(self, frame, payload, rid, rmodel):
        self.ensure_started(rid, rmodel)
        if not compat.get("msg_item"):
            item_id = f"msg_{compat.get('self.seq', 0)}"
            output_index = compat.get("next_index", 0)
            compat["msg_item"] = {"item_id": item_id, "output_index": output_index,
                                  "text": "", "done": False}
            self.out.append(_sse_event("response.output_item.added", {
                "type": "response.output_item.added", "sequence_number": self.seq,
                "output_index": output_index,
                "item": {"id": item_id, "type": "message", "status": "in_progress",
                         "role": "assistant",
                         "content": [{"type": "output_text", "text": "", "annotations": []}]}}))
            self.out.append(_sse_event("response.content_part.added", {
                "type": "response.content_part.added", "sequence_number": self.seq + 1,
                "item_id": item_id, "output_index": output_index, "content_index": 0,
                "part": {"type": "output_text", "text": "", "annotations": []}}))
            self.seq += 2
            compat["seq"] = self.seq
        item = compat["msg_item"]
        delta = payload.get("delta", "")
        if isinstance(delta, str):
            item["text"] += delta
        new_payload = dict(payload)
        new_payload["item_id"] = item["item_id"]
        new_payload["output_index"] = item["output_index"]
        new_payload["content_index"] = 0
        self.out.append(_sse_event("response.output_text.delta", new_payload))
        return self.out

    def _on_item_added(self, frame, payload, rid, rmodel):
        item = payload.get("item") or {}
        if item.get("type") == "function_call":
            self.ensure_started(rid or item.get("id"), rmodel)
            item_id = item.get("id") or f"fc_{compat.get('self.seq', 0)}"
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

    def _on_fc_args_delta(self, frame, payload, rid, rmodel):
        self.ensure_started(rid, rmodel)
        item = compat.get("fc_item")
        if not item:
            item_id = f"fc_{compat.get('self.seq', 0)}"
            output_index = compat.get("next_index", 1) or 1
            compat["fc_item"] = {"item_id": item_id, "output_index": output_index,
                                 "name": None, "call_id": None,
                                 "args_acc": "", "done": False}
            item = compat["fc_item"]
            self.out.append(_sse_event("response.output_item.added", {
                "type": "response.output_item.added", "sequence_number": self.seq,
                "output_index": output_index,
                "item": {"id": item_id, "type": "function_call", "status": "in_progress",
                         "name": "unknown", "call_id": item_id, "arguments": ""}}))
            self.seq += 1
            compat["seq"] = self.seq
        delta = payload.get("delta", "")
        if isinstance(delta, str):
            item["args_acc"] += delta
        new_payload = dict(payload)
        new_payload["item_id"] = item["item_id"]
        new_payload["output_index"] = item["output_index"]
        self.out.append(_sse_event("response.function_call_arguments.delta", new_payload))
        return self.out

    def _on_fc_args_done(self, frame, payload, rid, rmodel):
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

    def _on_terminal(self, frame, payload, rid, rmodel):
        if compat.get("started"):
            self.close_message()
            self.close_function_call()
        self.out.append(frame)
        return self.out

    def _on_item_done(self, frame, payload, rid, rmodel):
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

    def _on_text_done(self, frame, payload, rid, rmodel):
        return [frame]

# 帧类型 → 补帧处理器（2026-09-23：原先是一条 if/elif 链）
_COMPAT_HANDLERS = {
    "response.output_text.delta": "_on_text_delta",
    "response.output_item.added": "_on_item_added",
    "response.function_call_arguments.delta": "_on_fc_args_delta",
    "response.function_call_arguments.done": "_on_fc_args_done",
    "response.completed": "_on_terminal",
    "response.failed": "_on_terminal",
    "response.incomplete": "_on_terminal",
    "response.output_item.done": "_on_item_done",
}

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
        parsed = _parse_sse_frame(frame)     # 与 _rewrite_sse_frame 共用同一个解析器
        if parsed is None:
            return [frame]
        etype, payload = parsed
        if etype == "response.created":
            compat["saw_created"] = True
            return [frame]
        if not etype:
            return [frame]


        ctx = _ChatCompatCtx(compat)

        handler = _COMPAT_HANDLERS.get(etype)
        if handler is None:
            return [frame]
        return getattr(ctx, handler)(frame, payload, rid, rmodel)

        return [frame]
    except Exception as exc:
        _log(f"[vision-proxy] sse envelope completion failed, forwarding raw: {exc!r}")
        return [frame]


# ---------------------------------------------------------------------------
# 正文"平滑"（2026-09-23）
#
# 上游（尤其 OpenCode Go 网关给 muse）常常把整段正文**一次性 flush** 出来 —— 实测直连时
# 56.2s 那一刻涌进来 397 帧，客户端渲染出来就是"文字闪一下全出来"，而不是逐字。
# 这里只做呈现层的事：一帧里正文超过阈值就切成小片、片间按间隔分发；本来逐字来的流
# （每帧几字）不受影响。解析失败一律原样返回 —— 绝不改内容。
# ---------------------------------------------------------------------------
SMOOTH_TEXT_CHARS = 24         # 单帧正文超过这么多字符才切片
SMOOTH_TEXT_INTERVAL = 0.02    # 每片之间的间隔（秒）


def split_text_delta_frame(frame_bytes, chunk_chars=None):
    """返回 [(frame_bytes, delay_after_seconds), ...]。

    只有"一大段 output_text.delta"会被切开；其它帧原样返回、delay=0（fail-safe）。
    """
    if b"output_text.delta" not in frame_bytes:
        return [(frame_bytes, 0.0)]
    text = frame_bytes.decode("utf-8", errors="replace")
    data_start = text.find("data:")
    if data_start < 0:
        return [(frame_bytes, 0.0)]
    head = text[:data_start + 5]      # 含字面量 "data:"（别丢前缀，否则客户端认不出这帧）
    payload_text = text[data_start + 5:]
    stripped = payload_text.lstrip()
    leading = payload_text[:len(payload_text) - len(stripped)]
    try:
        payload = json.loads(stripped)
    except (json.JSONDecodeError, TypeError):
        return [(frame_bytes, 0.0)]
    if not isinstance(payload, dict) or payload.get("type") != "response.output_text.delta":
        return [(frame_bytes, 0.0)]
    delta = payload.get("delta")
    limit = chunk_chars or SMOOTH_TEXT_CHARS
    if not isinstance(delta, str) or len(delta) <= limit:
        return [(frame_bytes, 0.0)]
    out = []
    for i in range(0, len(delta), limit):
        piece = dict(payload)
        piece["delta"] = delta[i:i + limit]
        # 别忘 SSE 的帧分隔符：少了它客户端会把后面的帧吞掉
        out.append(((head + leading + json.dumps(piece, ensure_ascii=False) + "\n\n").encode("utf-8"),
                    SMOOTH_TEXT_INTERVAL))
    return out


def text_delta_chars(frame_bytes):
    """这一帧里正文有多少字符（非正文帧返回 0）—— 给漏桶算积压用。"""
    if b"output_text.delta" not in frame_bytes:
        return 0
    text = frame_bytes.decode("utf-8", errors="replace")
    idx = text.find("data:")
    if idx < 0:
        return 0
    try:
        payload = json.loads(text[idx + 5:].strip())
    except (json.JSONDecodeError, TypeError):
        return 0
    if not isinstance(payload, dict) or payload.get("type") != "response.output_text.delta":
        return 0
    delta = payload.get("delta")
    return len(delta) if isinstance(delta, str) else 0


class TextDeltaPacer:
    """把"上游憋完一次性涌出来"的正文按固定速率滴出去（显示起来像正常逐字）。

    2026-09-23：muse 那条上游会在末尾把几百个小 delta 一次性推过来，客户端渲染就是"啪一下全出来"。
    这里是个漏桶：
      * 上游本来就均匀（deepseek 那种每帧几字）→ 桶是空的，零延迟、零改动；
      * 上游猛推 → 按 rate 滴，最多容忍 max_lag 秒的积压，超了就直接放行（别让显示落后太久）。
    """

    def __init__(self, chars_per_second=300.0, max_lag_seconds=4.0, max_chars_per_second=1500.0):
        self.rate = float(chars_per_second)
        self.max_rate = float(max_chars_per_second)
        self.max_lag = float(max_lag_seconds)
        self.max_backlog = self.rate * self.max_lag
        self.chunk_chars = max(2, int(self.rate * 0.04))     # 每片 ~40ms
        self.backlog = 0.0
        self.last = time.monotonic()

    def shape(self, frame_bytes):
        """返回 [(帧字节, 发下一片前要等多少秒)]。"""
        now = time.monotonic()
        self.backlog = max(0.0, self.backlog - (now - self.last) * self.rate)
        self.last = now
        chars = text_delta_chars(frame_bytes)
        if chars <= 0:
            return [(frame_bytes, 0.0)]
        if self.backlog + chars > self.max_backlog:
            # 积压太深：**加速**而不是"啪一下全放" —— 直接放会让大答案的结尾又闪一下。
            if self.rate < self.max_rate:
                self.rate = min(self.max_rate, self.rate * 1.6)
                self.chunk_chars = max(2, int(self.rate * 0.04))
                self.max_backlog = self.rate * self.max_lag
            else:
                self.backlog = 0.0
                return [(frame_bytes, 0.0)]
        self.backlog += chars
        piece_delay = self.chunk_chars / self.rate
        return [(piece, piece_delay) for piece, _ in
                split_text_delta_frame(frame_bytes, self.chunk_chars)]
