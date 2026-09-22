"""apply_patch 工具描述/参数改写（Codex 专用格式）。"""

from __future__ import annotations

import json

from .config import (
    APPLY_PATCH_INPUT_DESCRIPTION,
    APPLY_PATCH_TOOL_DESCRIPTION,
    _log,
)
from .muse import (
    _fix_namespaced_tool_name,
    _is_muse_model,
    _muse_flag,
)
from .toolfix import (
    _coerce_float_ints_in_args_str,
)


def _is_apply_patch_name(name):
    # Bare name only: namespaced tools (mcp_*.apply_patch, plugin/apply_patch)
    # are different tools and must never be captured by this bridge.
    return name == "apply_patch"


def _rewrite_apply_patch_tool(parsed):
    """Request side: lower Codex freeform custom apply_patch to a chat function tool.

    Codex 0.146 sends the apply_patch freeform tool as ``{"type": "custom", ...}``;
    chat providers (DeepSeek Responses) only accept the flat function shape used
    by every other tool in the request (``type``, ``name``, ``description``,
    ``parameters`` at the top level), so the custom grammar tool is rebuilt in
    that shape with a single string ``input`` argument.
    """
    tools = parsed.get("tools")
    if not isinstance(tools, list):
        return False
    changed = False
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        tool_type = tool.get("type")
        if tool_type == "custom":
            name = tool.get("name")
        elif tool_type == "function":
            # Flat Responses shape only; the nested chat shape stays untouched.
            name = tool.get("name")
        else:
            continue
        if not _is_apply_patch_name(name):
            continue
        parameters = {
            "type": "object",
            "properties": {"input": {"type": "string", "description": APPLY_PATCH_INPUT_DESCRIPTION}},
            "required": ["input"],
        }
        already_flat = (tool_type == "function" and tool.get("name") == "apply_patch"
                        and tool.get("description") == APPLY_PATCH_TOOL_DESCRIPTION
                        and tool.get("parameters") == parameters)
        if already_flat:
            continue
        tool.clear()
        tool["type"] = "function"
        tool["name"] = "apply_patch"
        tool["description"] = APPLY_PATCH_TOOL_DESCRIPTION
        tool["strict"] = False
        tool["parameters"] = parameters
        changed = True
    if changed:
        _log("[vision-proxy] apply_patch tool rewritten custom->function for upstream")
    return changed


def _extract_apply_patch_input(args_acc):
    """Unwrap chat function arguments into bare V4A text. Never raises."""
    try:
        if not isinstance(args_acc, str):
            return ""
        trimmed = args_acc.strip()
        if not trimmed:
            return ""
        try:
            obj = json.loads(trimmed)
        except json.JSONDecodeError:
            return args_acc
        if isinstance(obj, dict):
            for key in ("input", "patch", "text", "payload", "command", "arguments"):
                value = obj.get(key)
                if isinstance(value, str) and "*** Begin Patch" in value:
                    return value
            value = obj.get("input")
            if isinstance(value, str):
                return value
        return args_acc
    except Exception as exc:
        _log(f"[vision-proxy] extract_apply_patch_input failed: {exc!r}")
        return args_acc


def _rewrite_apply_patch_response_json(body, model=None):
    """Non-streaming JSON response rewrite. Fail-safe: returns original bytes on any problem.

    2026-09-20：model 是 muse-spark 时额外拆点号命名空间工具
    （multi_agent_v1.spawn_agent -> name=spawn_agent + namespace=multi_agent_v1），
    Codex 的路由器不认带点号的名字（unsupported call）。
    """
    try:
        parsed = json.loads(body.decode("utf-8", errors="replace"))
        if not isinstance(parsed, dict):
            return body
        output = parsed.get("output")
        if not isinstance(output, list):
            return body
        changed = False
        for item in output:
            if not isinstance(item, dict):
                continue
            if (_is_muse_model(model) and _muse_flag("VISION_PROXY_MUSE_TOOLNAME_FIX")
                    and _fix_namespaced_tool_name(item)):
                _log("[vision-proxy] muse namespaced tool call split (non-stream)")
                changed = True
            if item.get("type") != "function_call":
                continue
            if _is_apply_patch_name(item.get("name")):
                item["type"] = "custom_tool_call"
                item["input"] = _extract_apply_patch_input(item.get("arguments"))
                item.pop("arguments", None)
                item.setdefault("status", "completed")
                changed = True
                continue
            # Generic function calls (e.g. Muse exec_command with float
            # yield_time_ms): coerce whole-number floats so the Codex Rust
            # executor (u64 integer params) accepts the call.
            args = item.get("arguments")
            if isinstance(args, str):
                fixed_args = _coerce_float_ints_in_args_str(args)
                if fixed_args != args:
                    item["arguments"] = fixed_args
                    changed = True
        if not changed:
            return body
        return json.dumps(parsed, ensure_ascii=False).encode()
    except Exception as exc:
        _log(f"[vision-proxy] json response rewrite failed: {exc!r}")
        return body
