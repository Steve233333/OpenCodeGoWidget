"""工具调用修正：JSON 参数修复、历史里的坏参数、input_ids、tool_required。"""

from __future__ import annotations

import json
import re

from .config import (
    _log,
)


def _sanitize_fc_args(args):
    """Ensure tool-call arguments are valid JSON object bytes (fault 21 insurance).

    Also normalizes whole-number floats to int: Muse via Zen/Go emits e.g.
    yield_time_ms 30000.0 / max_output_tokens 8000.0 while the Codex Rust
    executor parses integer params as u64 and rejects the call, which the
    model then retries forever. Healthy args pass through byte-identical.
    """
    try:
        json.loads(args)
        repaired = args
    except Exception:
        repaired = _repair_json_object_args(args)
        if not repaired:
            return args
    return _coerce_float_ints_in_args_str(repaired)


def _coerce_float_ints(obj):
    """Recursively convert whole-number floats to int, in place.

    Returns True if anything changed. True floats (0.5, 2.5...), strings,
    bools and out-of-int64-range values are left untouched (fail-safe).
    """
    changed = False
    if isinstance(obj, dict):
        items = obj.items()
    elif isinstance(obj, list):
        items = enumerate(obj)
    else:
        return False
    for key, value in items:
        if isinstance(value, float):
            if value.is_integer() and abs(value) < 2 ** 53:
                obj[key] = int(value)
                changed = True
        elif isinstance(value, (dict, list)):
            if _coerce_float_ints(value):
                changed = True
    return changed


def _coerce_float_ints_in_args_str(args):
    """Coerce whole-number floats to int inside a tool-call arguments JSON string.

    Response-path counterpart of the request-history repair: the parsed shape
    is what the Codex executor validates, so normalizing here (before the
    client ever sees the bytes) breaks the Muse float retry loop at the source.
    Fail-safe: returns the input unchanged when it is not a JSON object string
    or when nothing needs fixing (no log spam, byte-identical passthrough).
    """
    if not isinstance(args, str) or not args:
        return args
    try:
        obj = json.loads(args)
    except Exception:
        return args
    if not isinstance(obj, dict):
        return args
    try:
        if not _coerce_float_ints(obj):
            return args
    except Exception:
        return args
    try:
        fixed = json.dumps(obj, ensure_ascii=False)
    except Exception:
        return args
    _log("[vision-proxy] coerced float->int in tool-call arguments for Codex u64 params")
    return fixed


def _repair_json_object_args(s):
    """Repair tool-call arguments mangled by chat->responses adapters.

    2026-08-23: the Go gateway's streaming adapter for ox-alpha-free / glm-5.3
    drops the leading `{"` of function-call argument chunks, so Codex receives
    e.g. `cmd":"pwd"}` instead of `{"cmd":"pwd"}`. Non-streaming output is
    intact. Strategy: validate first (healthy args pass through untouched);
    then try structural candidates -- bare first key (`^[A-Za-z_]\\w*\\s*:`)
    gets a `{"` prefix, plus brace-prefix/suffix combinations. Returns the
    input unchanged when nothing valid is found (fail-safe).
    """
    if not isinstance(s, str) or not s.strip():
        return s
    try:
        if isinstance(json.loads(s), dict):
            return s
    except Exception:
        pass
    t = s.strip()
    prefixes = ["", "{"]
    suffixes = ["", "}"]
    if re.match(r"^[A-Za-z_][A-Za-z0-9_]*\s*\"?\s*:", t):
        prefixes.insert(0, '{"')
    for p in prefixes:
        for x in suffixes:
            cand = p + t + x
            if cand == s:
                continue
            try:
                if isinstance(json.loads(cand), dict):
                    return cand
            except Exception:
                continue
    return s


def _fc_args_broken(args):
    if not isinstance(args, str) or args == "":
        return False
    try:
        return not isinstance(json.loads(args), dict)
    except Exception:
        return True


def _repair_history_args(args):
    """把回放历史里的 `arguments` 修成合法 JSON（2026-09-23）。

    上游（Go/Zen 网关）会直接 400：「`arguments` must be valid JSON」。而历史里真的会有坏值 ——
    实测本线程里就有 4 条：`proposed_plan` 的空串、`request_user_input` 被截断的 JSON、
    `write_stdin` 少半截的 JSON（都是某次工具调用没发完整留下的）。
    依次尝试：本来就合法 → 不动；补 `{"` 前缀；逐步补闭合符号；实在救不回来 → `{}`（丢这一条的参数，
    但比让整轮对话被上游拒掉强），并记一行日志。
    """
    if not isinstance(args, str):
        return args
    if not args.strip():
        return "{}"
    try:
        json.loads(args)
        return args
    except Exception:
        pass
    fixed = _repair_json_object_args(args)
    try:
        json.loads(fixed)
        return fixed
    except Exception:
        pass
    stripped = args.rstrip().rstrip(',').rstrip()          # 截断常见的尾逗号/半截冒号
    for base in (args, stripped):
        for suffix in ('"', '}', '"}', '"]}', '"}]}', '}]}}', '}}'):
            try:
                json.loads(base + suffix)
                return base + suffix
            except Exception:
                continue
    _log(f"[vision-proxy] unrecoverable history arguments, replaced with {{}}: {args[:60]!r}")
    return "{}"


def _normalize_fc_args_history(parsed):
    """Repair broken assistant function_call arguments in replayed history.

    Same root cause as _repair_json_object_args: sessions that ran while the
    upstream adapter was dropping `{"` carry malformed arguments items; the
    model imitates its own malformed history when they are replayed verbatim.
    Whole-number floats are coerced to int for the same imitation reason
    (Muse re-emits yield_time_ms 30000.0 seen in its own history).
    Only zen/go routes call this; healthy history is left byte-identical.
    """
    input_items = parsed.get("input") if isinstance(parsed, dict) else None
    if not isinstance(input_items, list):
        return False
    changed = False
    for item in input_items:
        if not isinstance(item, dict) or item.get("type") != "function_call":
            continue
        args = item.get("arguments")
        if isinstance(args, str):
            fixed = _repair_history_args(args)          # 合法 JSON 是上游硬要求（截断/空串都会 400）
            if fixed != args:
                item["arguments"] = fixed
                changed = True
        args = item.get("arguments")
        if isinstance(args, str):
            coerced = _coerce_float_ints_in_args_str(args)
            if coerced != args:
                item["arguments"] = coerced
                changed = True
    if changed:
        _log("[vision-proxy] repaired malformed function_call arguments in zen/go request history")
    return changed


def _sanitize_input_ids(parsed):
    """Fix Zen/Go gateway 400 for store=false reasoning expiry.

    Codex can emit rs_ IDs joined with ':' (e.g. 'rs_aaa:rs_bbb') when reasoning
    summaries are replayed. OpenAI accepts it; opencode.ai Go/Zen gateway validates
    id as ^[a-zA-Z0-9_-]+$ and rejects ':' with 400, or with 'Referenced reasoning
    item ... was not found or has expired' when the encrypted reasoning item has
    expired (store=false). The safest fix is to drop the entire input item.
    Previously Go-only; 2026-09-02 expanded to Zen (muse-spark-free-zen same 400).
    Losing one reasoning history item is negligible vs 400.
    """
    input_items = parsed.get("input")
    if not isinstance(input_items, list):
        return False
    orig_len = len(input_items)
    filtered = [
        it
        for it in input_items
        if not (
            isinstance(it, dict)
            and isinstance(it.get("id"), str)
            and (":" in it["id"] or it["id"].startswith("rs_"))
        )
    ]
    if len(filtered) != orig_len:
        parsed["input"] = filtered
        _log(f"[vision-proxy] dropped {orig_len - len(filtered)} input item(s) with ':' or rs_ prefix in id for Zen/Go store=false 400")
        return True
    return False


def _fix_tool_required(parsed):
    """Fix Zen/Go gateway 400 for strict JSON-schema validation.

    OpenAI strict mode requires every key in `properties` to appear in
    `required` (and `additionalProperties: false`). Codex emits `list_threads`
    with `properties:{limit:{...}}` but `required:[]`, which Luna/Muse reject
    with 400 'Missing limit'. Patch only that case; previous generalized
    patch made shell's optional `budget/workdir/timeout` required and broke
    Muse (loop on integer budget).
    """
    tools = parsed.get("tools")
    if not isinstance(tools, list):
        return False
    changed = False
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        for holder in (tool, tool.get("function") if isinstance(tool.get("function"), dict) else None):
            if not isinstance(holder, dict):
                continue
            params = holder.get("parameters")
            if not isinstance(params, dict):
                continue
            props = params.get("properties")
            if not isinstance(props, dict) or not props:
                continue
            # Only patch the known strict case: `limit` missing
            if "limit" not in props:
                continue
            req = params.get("required")
            if not isinstance(req, list):
                # Keep original required if missing, but ensure limit is present
                # Most tools have required = ["limit"] or [], we set to ["limit"]
                if "limit" in props:
                    params["required"] = ["limit"]
                    changed = True
            else:
                if "limit" not in req:
                    req.append("limit")
                    changed = True
    if changed:
        _log("[vision-proxy] patched tool required[] to include limit for Zen/Go strict 400")
    return changed


# ---------------------------------------------------------------------------
# MiMo 原生 XML 工具调用（2026-09-23，抄 opencodex #5611/#5637 的作业）
#
# 实测（本机 9/22 的会话记录里真漏过）：MiMo 有自己的工具调用语法，网关没能把它转成
# function_call，就把这段 markup 当正文吐出来了 ——
#   <tool_call><function=write_stdin><parameter=session_id>77397</parameter>
#   <parameter=chars>x</parameter></tool_call>
# 形态还可能残缺（网关不补 </function>、多了孤立的 </parameter>），解析器要容错，
# 解析不出来就把原文当普通文本（宁可漏一次修补，也不能把正文吃掉）。
# ---------------------------------------------------------------------------
MIMO_TOOL_CALL_OPEN = "<tool_call>"

_MIMO_FUNCTION_RE = re.compile(r"<function\s*=\s*([A-Za-z_][\w.\-]*)>|<function\s+name\s*=\s*\"([^\"]+)\"\s*>")
_MIMO_PARAM_RE = re.compile(
    r"<parameter\s*=\s*([A-Za-z_][\w.\-]*)\s*>(.*?)</parameter>"
    r"|<parameter\s+name\s*=\s*\"([^\"]+)\"\s*>(.*?)</parameter>",
    re.S,
)


def _coerce_param_value(raw, want_type):
    """按调用方给的 schema 类型转一下（工具参数写在请求的 tools 里，别靠名字猜）。"""
    text = raw.strip()
    if want_type == "integer":
        try:
            return int(text)
        except ValueError:
            return text
    if want_type == "number":
        try:
            return float(text)
        except ValueError:
            return text
    if want_type == "boolean":
        if text.lower() in ("true", "false"):
            return text.lower() == "true"
        return text
    return raw          # string / 未知类型：原样，注意不要 strip（chars 里的空格有意义）


def parse_mimo_tool_markup(text, tool_param_types=None):
    """把正文里的 MiMo XML 工具调用摘出来。

    返回 (clean_text, calls)：
      clean_text = 去掉 markup 之后的可见正文；
      calls      = [{"id": None, "name": ..., "args": <JSON 字符串>}]（与 chat 的 tool_calls 同形状）。
    `tool_param_types` 形如 {"write_stdin": {"session_id": "integer", ...}}，来自请求里的 tools；
    没给就全部当字符串（宁可不猜）。
    """
    if not isinstance(text, str) or MIMO_TOOL_CALL_OPEN not in text:
        return text, []
    clean = []
    calls = []
    cursor = 0
    while True:
        start = text.find(MIMO_TOOL_CALL_OPEN, cursor)
        if start < 0:
            clean.append(text[cursor:])
            break
        end = text.find("</tool_call>", start)
        if end < 0:
            # 没有闭合：整段留在正文里（交给流式那层按超时/上限决定，静态解析不猜）
            clean.append(text[cursor:])
            break
        block = text[start + len(MIMO_TOOL_CALL_OPEN):end]
        m = _MIMO_FUNCTION_RE.search(block)
        if not m:
            clean.append(text[cursor:end + len("</tool_call>")])
            cursor = end + len("</tool_call>")
            continue
        name = m.group(1) or m.group(2)
        args = {}
        for pm in _MIMO_PARAM_RE.finditer(block):
            key = pm.group(1) or pm.group(3)
            raw = pm.group(2) if pm.group(2) is not None else pm.group(4)
            want = ((tool_param_types or {}).get(name) or {}).get(key)
            args[key] = _coerce_param_value(raw if raw is not None else "", want)
        clean.append(text[cursor:start])
        calls.append({"id": None, "name": name, "args": json.dumps(args, ensure_ascii=False)})
        cursor = end + len("</tool_call>")
    clean_text = "".join(clean)
    if calls:
        _log(f"[vision-proxy] MiMo XML 工具调用已从正文摘出 {len(calls)} 个：{[c['name'] for c in calls]}")
    return clean_text, calls


def mimo_markup_hold_len(text):
    """流式用：正文尾巴是不是"可能是 <tool_call> 的开头"，是就返回要扣住几个字符。

    例：尾巴 "<tool" → 3；"<tool_call>xx" 里含完整开标签 → 0（那由块扫描处理）。
    """
    if not text:
        return 0
    max_len = min(len(text), len(MIMO_TOOL_CALL_OPEN) - 1)
    for n in range(max_len, 0, -1):
        if MIMO_TOOL_CALL_OPEN.startswith(text[-n:]):
            return n
    return 0


def find_mimo_block(text):
    """流式用：找一个**完整**的 `<tool_call>…</tool_call>` 块。

    返回 (start, end, name, args_json) 或 None。
    """
    if not isinstance(text, str):
        return None
    start = text.find(MIMO_TOOL_CALL_OPEN)
    if start < 0:
        return None
    end = text.find("</tool_call>", start)
    if end < 0:
        return None
    block = text[start + len(MIMO_TOOL_CALL_OPEN):end]
    m = _MIMO_FUNCTION_RE.search(block)
    if not m:
        return None
    name = m.group(1) or m.group(2)
    return (start, end + len("</tool_call>"), name, block)
