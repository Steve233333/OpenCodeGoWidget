"""工具调用修正：JSON 参数修复、历史里的坏参数、input_ids、tool_required。"""

from __future__ import annotations

import json
import re

from .config import (
    _SEARCH_TRUE_PREFIXES,
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
        if _fc_args_broken(args):
            fixed = _repair_json_object_args(args)
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


def _intercept_unsupported_history(parsed, model):
    """Intercept search=true history -> search=false model.

    Preserve context integrity: do not silently drop web_search_call history.
    Return True if interception should happen (caller must return 400 with
    user-facing guidance to start a new session).
    """
    if not isinstance(model, str):
        return False
    # strip -go / -zen suffix already done by caller; model is bare id
    # Generic future-proof: only search-true whitelist keeps history, all others (known + unknown) intercept
    if model.startswith(_SEARCH_TRUE_PREFIXES):
        return False
    input_items = parsed.get("input")
    if not isinstance(input_items, list):
        return False
    for item in input_items:
        if isinstance(item, dict) and item.get("type") == "web_search_call":
            return True
    # also check tools? history alone is enough
    return False


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
