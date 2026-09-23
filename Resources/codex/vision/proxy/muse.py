"""Muse 兼容层：schema 修补、禁止空转前缀、空转重试。"""

from __future__ import annotations

import hashlib
import json
import os
import time

from .config import (
    MUSE_MODEL_PREFIX,
    MUSE_NO_PREAMBLE_INSTRUCTION,
    MUSE_SCHEMA_MAX_DEPTH,
    MUSE_STALL_RETRY_INSTRUCTION,
    MUSE_STALL_RETRY_INSTRUCTION_HARD,
    MUSE_TOOL_FIRST_INSTRUCTION,
    _JSON_SCHEMA_TYPES,
    _MUSE_RETRY_HISTORY,
    _MUSE_RETRY_LIMIT,
    _MUSE_RETRY_WINDOW,
    _log,
)


def _muse_flag(name, default=True):
    """env 开关（从 env 文件灌进 os.environ）：1/true/yes/on 开，0/false/no/off 关。"""
    raw = os.environ.get(name)
    if raw is None:
        return default
    return str(raw).strip().lower() not in ("", "0", "false", "no", "off")


def _is_muse_model(model):
    return isinstance(model, str) and model.startswith(MUSE_MODEL_PREFIX)


def _split_namespaced_tool_name(name):
    """'multi_agent_v1.spawn_agent' -> ('multi_agent_v1', 'spawn_agent')；不是点号名则 None。"""
    if not isinstance(name, str) or "." not in name or any(ch.isspace() for ch in name):
        return None
    namespace, _, bare = name.rpartition(".")
    if not namespace or not bare:
        return None
    return namespace, bare


def _fix_namespaced_tool_name(item):
    """把点号工具名拆成 name + namespace（就地改名）。已拆分/不适用返回 False。"""
    if not isinstance(item, dict):
        return False
    if item.get("type") != "function_call" or item.get("namespace"):
        return False
    split = _split_namespaced_tool_name(item.get("name"))
    if not split:
        return False
    item["name"], item["namespace"] = split[1], split[0]
    return True


def _split_muse_namespaced_items(items):
    changed = False
    if isinstance(items, list):
        for item in items:
            if _fix_namespaced_tool_name(item):
                changed = True
    return changed


def _sse_state_model(state):
    compat = state.get("compat") if isinstance(state, dict) else None
    return compat.get("model") if isinstance(compat, dict) else None


def _repair_muse_schema_stubs(node):
    """Codex 的延迟工具会发 {"type": {}, "description": {}}，Meta 直接判非法。

    只走 schema 语义下的子键（properties 的值、items、anyOf/oneOf/allOf、not/if/then/else、
    additionalProperties），绝不盲递归：properties 里本来就可能有名叫 description 的属性。
    """
    if not isinstance(node, dict):
        return False
    changed = False
    if "type" in node:
        value = node["type"]
        valid = (isinstance(value, str) and value in _JSON_SCHEMA_TYPES) or (
            isinstance(value, list)
            and bool(value)
            and all(isinstance(item, str) and item in _JSON_SCHEMA_TYPES for item in value)
        )
        if not valid:
            node["type"] = "string"
            changed = True
    if "description" in node and not isinstance(node["description"], str):
        node["description"] = ""
        changed = True
    for key in ("items", "additionalProperties", "not", "if", "then", "else", "contains", "propertyNames"):
        sub = node.get(key)
        if isinstance(sub, dict) and _repair_muse_schema_stubs(sub):
            changed = True
    props = node.get("properties")
    if isinstance(props, dict):
        for sub in props.values():
            if isinstance(sub, dict) and _repair_muse_schema_stubs(sub):
                changed = True
    for key in ("anyOf", "oneOf", "allOf", "prefixItems"):
        seq = node.get(key)
        if isinstance(seq, list):
            for sub in seq:
                if isinstance(sub, dict) and _repair_muse_schema_stubs(sub):
                    changed = True
    return changed


def _cap_schema_depth(node, depth=1, max_depth=None):
    """砍掉第 8 层以外的 properties/required/items（第 9 层 Meta 必拒）。

    返回 (node, changed)。
    """
    if max_depth is None:
        max_depth = MUSE_SCHEMA_MAX_DEPTH
    if not isinstance(node, dict):
        return node, False
    changed = False
    if depth >= max_depth:
        for key in ("properties", "required", "items"):
            if key in node:
                node.pop(key, None)
                changed = True
        return node, changed
    props = node.get("properties")
    if isinstance(props, dict):
        for key, sub in list(props.items()):
            new_sub, sub_changed = _cap_schema_depth(sub, depth + 1, max_depth)
            if sub_changed:
                props[key] = new_sub
                changed = True
    items = node.get("items")
    if isinstance(items, dict):
        new_items, sub_changed = _cap_schema_depth(items, depth + 1, max_depth)
        if sub_changed:
            node["items"] = new_items
            changed = True
    return node, changed


def _resolve_json_pointer(root, ref):
    """解析本地 '#/...' 指针；不是本地指针或解析不到返回 None。"""
    if ref in ("#", "#/"):
        return root
    if not isinstance(ref, str) or not ref.startswith("#/"):
        return None
    node = root
    for raw in ref[2:].split("/"):
        token = raw.replace("~1", "/").replace("~0", "~")
        if isinstance(node, dict) and token in node:
            node = node[token]
        elif isinstance(node, list) and token.isdigit() and int(token) < len(node):
            node = node[int(token)]
        else:
            return None
    return node


def _inline_local_refs(node, root, _depth=0, _seen=frozenset()):
    """就地展开本地 $ref（Meta 不支持递归 schema），循环引用用 {} 截断。

    返回 (new_node, changed)：只有真的展开了才返回 changed=True。
    """
    if _depth > MUSE_SCHEMA_MAX_DEPTH:
        return node, False
    if isinstance(node, list):
        out, changed = [], False
        for sub in node:
            new_sub, sub_changed = _inline_local_refs(sub, root, _depth + 1, _seen)
            out.append(new_sub)
            changed = changed or sub_changed
        return (out if changed else node), changed
    if not isinstance(node, dict):
        return node, False
    ref = node.get("$ref")
    if isinstance(ref, str) and ref.startswith("#"):
        if ref in _seen:
            return {}, True
        target = _resolve_json_pointer(root, ref)
        if target is None:
            return node, False
        expanded, _ = _inline_local_refs(target, root, _depth + 1, _seen | {ref})
        return expanded, True
    out, changed = {}, False
    for key, value in node.items():
        if key in ("$defs", "definitions"):
            changed = True
            continue
        new_value, value_changed = _inline_local_refs(value, root, _depth + 1, _seen)
        out[key] = new_value
        changed = changed or value_changed
    return (out if changed else node), changed


def _sanitize_muse_tool_schemas(parsed):
    """Muse 请求侧净化：修空 stub + 展开 $ref + 砍超深层 + 松掉 strict。

    只对 muse-spark 生效；其他模型连函数体都不进（返回 False，payload 字节不变）。
    """
    if not isinstance(parsed, dict) or not _is_muse_model(parsed.get("model")):
        return False
    if not _muse_flag("VISION_PROXY_MUSE_SCHEMA_FIX"):
        return False
    tools = parsed.get("tools")
    if not isinstance(tools, list):
        return False
    changed = False
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        entries = [tool]
        nested = tool.get("tools")
        if isinstance(nested, list):
            entries.extend([entry for entry in nested if isinstance(entry, dict)])
        for entry in entries:
            params = entry.get("parameters")
            if isinstance(params, dict):
                before = len(json.dumps(params, ensure_ascii=False))
                if _repair_muse_schema_stubs(params):
                    changed = True
                if _muse_flag("VISION_PROXY_MUSE_SCHEMA_REF_FIX"):
                    expanded, ref_changed = _inline_local_refs(params, params)
                    if ref_changed:
                        after = len(json.dumps(expanded, ensure_ascii=False))
                        # 展开后爆量的宁可跳过（好过把请求撑爆）：>3 倍且 +200KB 以上就放弃
                        if after > before * 3 and after - before > 200 * 1024:
                            _log(f"[vision-proxy] muse $ref inline skipped tool={entry.get('name')} {before}->{after}")
                        else:
                            entry["parameters"] = expanded
                            params = expanded
                            changed = True
                capped, cap_changed = _cap_schema_depth(params)
                if cap_changed:
                    entry["parameters"] = capped
                    changed = True
            if entry.get("strict") is True:
                entry["strict"] = False
                changed = True
    if changed:
        _log(f"[vision-proxy] muse tool schema sanitized tools={len(tools)}")
    return changed


def _inject_muse_no_preamble(parsed):
    """Muse 专属：instructions 里补一条「要么工具调用要么最终答复」的硬约束（幂等）。"""
    if not isinstance(parsed, dict) or not _is_muse_model(parsed.get("model")):
        return False
    if not _muse_flag("VISION_PROXY_MUSE_NO_PREAMBLE"):
        return False
    instructions = parsed.get("instructions")
    if not isinstance(instructions, str) or MUSE_NO_PREAMBLE_INSTRUCTION in instructions:
        return False
    parsed["instructions"] = instructions.rstrip() + "\n\n" + MUSE_NO_PREAMBLE_INSTRUCTION
    _log("[vision-proxy] muse no-preamble constraint appended to instructions")
    return True


def _inject_muse_tool_first(parsed):
    """Muse 专属：input 末尾（模型最后读到的地方）再压一条工具优先约束（幂等）。"""
    if not isinstance(parsed, dict) or not _is_muse_model(parsed.get("model")):
        return False
    if not _muse_flag("VISION_PROXY_MUSE_NO_PREAMBLE"):
        return False
    items = parsed.get("input")
    if not isinstance(items, list):
        return False
    for item in items:
        if not isinstance(item, dict) or item.get("role") != "developer":
            continue
        for part in item.get("content") or []:
            if isinstance(part, dict) and part.get("text") in (
                    MUSE_TOOL_FIRST_INSTRUCTION, MUSE_NO_PREAMBLE_INSTRUCTION):
                return False
    items.append({
        "type": "message",
        "role": "developer",
        "content": [{"type": "input_text", "text": MUSE_TOOL_FIRST_INSTRUCTION}],
    })
    _log("[vision-proxy] muse tool-first constraint appended to input")
    return True


def _muse_retry_allowed(body):
    """熔断：同一份「空转响应」2 分钟内最多重发 6 次，防止客户端重试循环放大上游调用。"""
    key = hashlib.sha1(body[:8192]).hexdigest()
    now = time.monotonic()
    entry = _MUSE_RETRY_HISTORY.get(key)
    if not entry or now - entry[1] > _MUSE_RETRY_WINDOW:
        if len(_MUSE_RETRY_HISTORY) > 256:
            for stale, (_, ts) in list(_MUSE_RETRY_HISTORY.items()):
                if now - ts > _MUSE_RETRY_WINDOW:
                    _MUSE_RETRY_HISTORY.pop(stale, None)
        _MUSE_RETRY_HISTORY[key] = [1, now]
        return True
    entry[0] += 1
    return entry[0] <= _MUSE_RETRY_LIMIT


def _build_muse_retry_body(body, attempt):
    """重发用的请求体：在原 input 末尾追加一条更硬的 developer 约束。"""
    try:
        parsed = json.loads(body.decode("utf-8", errors="replace"))
    except Exception:
        return body
    if not isinstance(parsed, dict):
        return body
    text = MUSE_STALL_RETRY_INSTRUCTION if attempt <= 1 else MUSE_STALL_RETRY_INSTRUCTION_HARD
    item = {"type": "message", "role": "developer",
            "content": [{"type": "input_text", "text": text}]}
    if isinstance(parsed.get("input"), list):
        parsed["input"].append(item)
    else:
        parsed["input"] = [item]
    return json.dumps(parsed, ensure_ascii=False).encode()


# ---------------------------------------------------------------------------
# Muse 的 max_output_tokens 下限（2026-09-23）
#
# 实测：这个网关把**推理 token 也算进 max_output_tokens**（80 预算的一轮里 reasoning_tokens=77，
# 于是一个字都没吐、直接 response.incomplete + incomplete_details.reason=max_output_tokens）。
# 截图里用户用的是「极高」档推理，budget 小的时候就是"只思考、不出字"。
# 对策：**只在客户端显式给了、且小于下限时抬高**；没给就照上游默认，绝不擅自设上限。
# ---------------------------------------------------------------------------
MUSE_MIN_MAX_OUTPUT_TOKENS = 16384


def _muse_enforce_min_output_tokens(parsed):
    """返回 (是否改过, 原值, 新值)；解析不了就原样返回。"""
    if not isinstance(parsed, dict):
        return False, None, None
    if not _is_muse_model(parsed.get("model")):
        return False, None, None
    current = parsed.get("max_output_tokens")
    if not isinstance(current, int) or current >= MUSE_MIN_MAX_OUTPUT_TOKENS:
        return False, current, current
    parsed["max_output_tokens"] = MUSE_MIN_MAX_OUTPUT_TOKENS
    return True, current, MUSE_MIN_MAX_OUTPUT_TOKENS
