"""Responses ⇄ Anthropic Messages 桥（/v1/messages 通道）。"""

from __future__ import annotations

import json
import uuid

from .bridges_chat import (
    ChatBridgeTranslator,
    _bridge_base_response,
    _log_history_replay,
)
from .config import (
    _log,
)
from .search_sidecar import (
    synthetic_web_search_tool,
    web_search_call_id,
    web_search_query_of,
    web_search_result_placeholder,
)
from .toolfix import (
    _sanitize_fc_args,
)


def _messages_content_blocks(content):
    """Responses 的 content（str 或 parts）-> Anthropic content blocks。"""
    if isinstance(content, str):
        return [{"type": "text", "text": content}] if content else []
    blocks = []
    if not isinstance(content, list):
        return blocks
    for part in content:
        if not isinstance(part, dict):
            continue
        ptype = part.get("type")
        if ptype in ("input_text", "output_text", "text", "summary_text"):
            text = part.get("text")
            if isinstance(text, str) and text:
                blocks.append({"type": "text", "text": text})
        elif ptype in ("input_image", "image", "image_url"):
            url = part.get("image_url") or part.get("url")
            if isinstance(url, dict):
                url = url.get("url")
            if not isinstance(url, str):
                continue
            if url.startswith("data:"):
                head, _, data = url.partition(",")
                media = head[5:].split(";")[0] or "image/png"
                blocks.append({"type": "image",
                               "source": {"type": "base64", "media_type": media, "data": data}})
            elif url.startswith("http"):
                blocks.append({"type": "image", "source": {"type": "url", "url": url}})
    return blocks


def _translate_history(items, system_parts):
    """Responses 的 input 条目 → (Anthropic messages, stats)。

    - message / function_call / function_call_output：与搬移前逐行一致。
    - **web_search_call（2026-09-23）**：翻成 tool_use + tool_result（占位结果）。
      以前这里和 chat 桥一样把它静默丢掉，于是"切到无原生搜索的模型"要靠 400 拦；
      现在翻译成 Anthropic 能吃的形状，上下文不断。
    - reasoning：对 Anthropic 无意义，仍不回放，但计数以便日志可见。
    """
    messages = []
    stats = {"dropped_reasoning": 0, "web_search_replayed": 0}

    def push(role, blocks):
        if not blocks:
            return
        # Anthropic 侧连续同角色要合并成一格（连续 user 会被严格校验）
        if messages and messages[-1]["role"] == role:
            messages[-1]["content"].extend(blocks)
        else:
            messages.append({"role": role, "content": blocks})

    for item in items:
        itype = item.get("type") or "message"
        if itype == "message":
            role = item.get("role") or "user"
            if role == "developer":
                text = "".join(b.get("text", "") for b in _messages_content_blocks(item.get("content"))
                               if b.get("type") == "text")
                if text:
                    system_parts.append(text)
                continue
            if role not in ("user", "assistant"):
                role = "user"
            push(role, _messages_content_blocks(item.get("content")))
        elif itype in ("function_call", "custom_tool_call"):
            raw = item.get("arguments")
            if not isinstance(raw, str):
                raw = json.dumps(item.get("input") or {}, ensure_ascii=False)
            try:
                arg_obj = json.loads(raw) if raw.strip() else {}
            except Exception:
                arg_obj = {}
            if not isinstance(arg_obj, dict):
                arg_obj = {"input": arg_obj}
            push("assistant", [{
                "type": "tool_use",
                "id": item.get("call_id") or item.get("id") or ("call_" + uuid.uuid4().hex[:16]),
                "name": item.get("name") or "",
                "input": arg_obj,
            }])
        elif itype == "web_search_call":
            call_id = web_search_call_id(item)
            query = web_search_query_of(item)
            push("assistant", [{
                "type": "tool_use",
                "id": call_id,
                "name": "web_search",
                "input": {"query": query},
            }])
            push("user", [{
                "type": "tool_result",
                "tool_use_id": call_id,
                "content": web_search_result_placeholder(query),
            }])
            stats["web_search_replayed"] += 1
        elif itype in ("function_call_output", "custom_tool_call_output"):
            output = item.get("output")
            if not isinstance(output, str):
                output = json.dumps(output, ensure_ascii=False)
            push("user", [{
                "type": "tool_result",
                "tool_use_id": item.get("call_id") or item.get("id") or "",
                "content": output,
            }])
        elif itype == "reasoning":
            stats["dropped_reasoning"] += 1
        # 其他未知条目类型：与搬移前一致（丢弃）
    return messages, stats


def _responses_request_to_messages(parsed):
    """Responses API 请求体 -> Anthropic Messages 请求体（union-alpha 这类 messages-only 模型）。"""
    system_parts = []
    instructions = parsed.get("instructions")
    if isinstance(instructions, str) and instructions.strip():
        system_parts.append(instructions.strip())
    raw_input = parsed.get("input")
    if isinstance(raw_input, str):
        items = [{"type": "message", "role": "user", "content": raw_input}]
    elif isinstance(raw_input, list):
        items = [i for i in raw_input if isinstance(i, dict)]
    else:
        items = []

    messages, stats = _translate_history(items, system_parts)
    _log_history_replay(stats, parsed, "messages")

    # Anthropic 要求首条是 user
    if messages and messages[0]["role"] != "user":
        messages.insert(0, {"role": "user", "content": [{"type": "text", "text": "(session start)"}]})

    tools = []
    for tool in parsed.get("tools") or []:
        if not isinstance(tool, dict):
            continue
        ttype = tool.get("type")
        if ttype == "function":
            name = tool.get("name") or ""
            schema = tool.get("parameters") or {"type": "object", "properties": {}}
        elif ttype == "custom":
            # Codex 的 freeform 工具理论上已被 _rewrite_apply_patch_tool 拍平，这里兜底
            name = tool.get("name") or ""
            schema = {"type": "object", "properties": {"input": {"type": "string"}}, "required": ["input"]}
        else:
            continue  # web_search 等交给边车/合成注入，不下发
        if not name:
            continue
        entry = {"name": name, "input_schema": schema if isinstance(schema, dict)
                 else {"type": "object", "properties": {}}}
        if tool.get("description"):
            entry["description"] = tool["description"]
        tools.append(entry)

    # 回放过 web_search 调用就必须有对应工具声明，否则 Anthropic 校验 tool_use 时找不到工具
    if stats["web_search_replayed"] and not any(t.get("name") == "web_search" for t in tools):
        synthetic = synthetic_web_search_tool()
        entry = {"name": synthetic["name"], "input_schema": synthetic["parameters"]}
        if synthetic.get("description"):
            entry["description"] = synthetic["description"]
        tools.append(entry)

    # max_tokens 是 Anthropic 必填；Codex 的 max_output_tokens 给上就照用
    try:
        max_tokens = int(parsed.get("max_output_tokens") or 0)
    except Exception:
        max_tokens = 0
    if max_tokens <= 0:
        max_tokens = 32000
    payload = {
        "model": parsed.get("model"),
        "max_tokens": max(1, min(max_tokens, 128000)),
        "messages": messages,
        "stream": bool(parsed.get("stream")),
    }
    if system_parts:
        payload["system"] = "\n\n".join(system_parts)
    if tools:
        payload["tools"] = tools
        choice = parsed.get("tool_choice")
        if choice == "required":
            payload["tool_choice"] = {"type": "any"}
        elif choice == "none":
            pass  # Anthropic 没有 none，直接不下发 tool_choice
        else:
            payload["tool_choice"] = {"type": "auto"}
    for key in ("temperature", "top_p"):
        value = parsed.get(key)
        if isinstance(value, (int, float)):
            payload[key] = value
    return payload


def _messages_usage_to_responses(usage):
    usage = usage or {}
    prompt = usage.get("input_tokens") or 0
    completion = usage.get("output_tokens") or 0
    cached = usage.get("cache_read_input_tokens") or 0
    return {
        "input_tokens": prompt,
        "input_tokens_details": {"cached_tokens": cached},
        "output_tokens": completion,
        "output_tokens_details": {"reasoning_tokens": 0},
        "total_tokens": prompt + completion,
    }


def _build_messages_fallback_json(model, obj, effort=None):
    """非流式的 Anthropic Messages 响应 -> Responses 响应对象。"""
    response = _bridge_base_response(model, status="completed")
    items = []
    text_parts = []
    for block in (obj.get("content") if isinstance(obj, dict) else None) or []:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text" and isinstance(block.get("text"), str):
            text_parts.append(block["text"])
        elif btype == "tool_use":
            args = block.get("input")
            args_str = args if isinstance(args, str) else json.dumps(args or {}, ensure_ascii=False)
            items.append({
                "id": "fc_" + uuid.uuid4().hex[:24], "type": "function_call", "status": "completed",
                "call_id": block.get("id") or ("call_" + uuid.uuid4().hex[:16]),
                "name": block.get("name") or "", "arguments": _sanitize_fc_args(args_str),
            })
    text = "".join(text_parts)
    if text:
        items.insert(0, {"id": "msg_" + uuid.uuid4().hex[:24], "type": "message", "status": "completed",
                         "role": "assistant",
                         "content": [{"type": "output_text", "text": text, "annotations": []}]})
    response["output"] = items
    response["usage"] = _messages_usage_to_responses(obj.get("usage") if isinstance(obj, dict) else None)
    return response


class MessagesBridgeTranslator(ChatBridgeTranslator):
    """Anthropic Messages SSE -> Responses SSE（2026-09-17 union-alpha 通道）。

    记账、收尾、字节预算、tool_use→function_call 全部复用 ChatBridgeTranslator，
    只替换「怎么读上游事件」这一层：message_start / content_block_start /
    content_block_delta / message_delta / message_stop。
    """

    def __init__(self, model, effort=None, byte_budget=16 * 1024 * 1024):
        super().__init__(model, effort=effort, byte_budget=byte_budget)
        self.anthropic_usage = None
        self.stop_reason = None
        self.created = False

    def _chat_like_usage(self, usage):
        """Anthropic usage -> chat usage（父类收尾用的是 chat 形状）。"""
        usage = usage or {}
        prompt = usage.get("input_tokens") or 0
        completion = usage.get("output_tokens") or 0
        return {"prompt_tokens": prompt, "completion_tokens": completion,
                "total_tokens": prompt + completion}

    def ensure_created(self):
        if self.created:
            return b""
        self.created = True
        return self.on_created()

    def on_finish(self, finish_reason=None, usage=None):
        if usage is None:
            usage = self.anthropic_usage
        return super().on_finish(finish_reason, self._chat_like_usage(usage) if usage else None)

    def on_message_event(self, event):
        etype = event.get("type")
        if etype == "message_start":
            message = event.get("message") or {}
            usage = message.get("usage")
            if isinstance(usage, dict):
                self.anthropic_usage = dict(usage)
            return self.ensure_created()
        if etype == "content_block_start":
            block = event.get("content_block") or {}
            if block.get("type") == "tool_use":
                return self._open_tool_if_needed(event.get("index") or 0,
                                                 block.get("id"), block.get("name"))
            return b""
        if etype == "content_block_delta":
            delta = event.get("delta") or {}
            dtype = delta.get("type")
            if dtype == "text_delta" and isinstance(delta.get("text"), str):
                return self.on_content_delta(delta["text"])
            if dtype == "input_json_delta" and isinstance(delta.get("partial_json"), str):
                return self.on_tool_delta(event.get("index") or 0, args_delta=delta["partial_json"])
            if dtype == "thinking_delta" and isinstance(delta.get("thinking"), str):
                return self.on_reasoning_delta(delta["thinking"])
            return b""
        if etype == "message_delta":
            delta = event.get("delta") or {}
            if isinstance(delta.get("stop_reason"), str):
                self.stop_reason = delta["stop_reason"]
            usage = event.get("usage")
            if isinstance(usage, dict):
                merged = dict(self.anthropic_usage or {})
                merged.update(usage)
                self.anthropic_usage = merged
            return b""
        if etype == "message_stop":
            return self.on_finish(self.stop_reason, self.anthropic_usage)
        if etype == "error":
            err = event.get("error") or {}
            _log(f"[vision-proxy] messages bridge upstream error model={self.model}: "
                 f"{json.dumps(err, ensure_ascii=False)[:200]}")
            return self.on_finish("error", self.anthropic_usage)
        return b""  # ping / 其它事件忽略

    def on_message_frame(self, frame_bytes):
        """解析一个上游 SSE 帧（Anthropic 的事件体里自带 type 字段）。"""
        out = b""
        for line in frame_bytes.decode(errors="replace").split("\n"):
            line = line.strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if not data or data == "[DONE]":
                continue
            try:
                event = json.loads(data)
            except json.JSONDecodeError:
                continue
            if not isinstance(event, dict):
                continue
            out += self.on_message_event(event)
        return out
