# Patch playbook: five Muse rewrites in a local proxy

Reference implementation: `~/.local/share/agent-vision-toolkit/vision_proxy.py` (the proxy this
skill was derived from). Adapt names to the proxy you are patching; keep the structure.

## Placement rules

- **Request side** (before the body is serialized upstream): schema depth cap, `$ref` inlining,
  `strict` relaxation, the trailing "tool call or final answer" constraint.
- **Response side**: dotted tool-name splitting, stall detection and retry.
- Gate everything on `model.startswith("muse-spark")`. Other models must keep byte-identical
  payloads — that property is what makes these patches safe to run in a shared proxy.
- Re-serialize the request body only when a rewrite actually changed something.

## 1. Repair empty schema stubs

```python
_JSON_SCHEMA_TYPES = {"object", "array", "string", "number", "integer", "boolean", "null"}

def _repair_muse_schema_stubs(node):
    """Codex emits {"type": {}, "description": {}} for deferred tools; Meta rejects it."""
    if not isinstance(node, dict):
        return False
    changed = False
    if "type" in node:
        value = node["type"]
        valid = (isinstance(value, str) and value in _JSON_SCHEMA_TYPES) or (
            isinstance(value, list) and value
            and all(isinstance(x, str) and x in _JSON_SCHEMA_TYPES for x in value))
        if not valid:
            node["type"] = "string"
            changed = True
    if "description" in node and not isinstance(node["description"], str):
        node["description"] = ""
        changed = True
    ...
```

Walk only schema-bearing keys (`properties` values, `items`, `anyOf`/`oneOf`/`allOf`,
`additionalProperties`, `not`/`if`/`then`/`else`). Do **not** recurse blindly: a property map
legitimately contains a key named `description`, and a blind walk will overwrite it with a string.

## 2. Cap tool-schema nesting at 8 levels

```python
MUSE_SCHEMA_MAX_DEPTH = 8

def _cap_schema_depth(node, depth=1, max_depth=None):
    """Drop properties/required/items at the deepest allowed level (level 9 is rejected)."""
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
```

Walk `tools[*].parameters` and nested namespace tools (`tool["tools"][*]["parameters"]`).

## 3. Inline local `$ref`

Resolve `#/...` pointers against the same schema root, expand them in place, drop `$defs` /
`definitions`, and break cycles by substituting `{}`. Cap expansion depth (8 is plenty) and
revert the whole rewrite if the payload grows beyond ~3× and +200 KB — better to skip a fix than
to blow up a request.

## 4. Relax `strict` (defensive)

```python
if tool.get("strict") is True:
    tool["strict"] = False
```

Apply recursively, including tools nested inside namespace entries. Log the affected tool names
once. Measured evidence says `strict` is not what breaks this gateway (see
`upstream-limits.md`), so treat this as cheap insurance rather than the fix — and if the log stays
empty, that was never your bug.

## 5. Split dotted tool names (response side)

```python
def _fix_namespaced_tool_name(item):
    if not isinstance(item, dict):
        return False
    if item.get("type") != "function_call" or item.get("namespace"):
        return False
    name = item.get("name")
    if not isinstance(name, str) or "." not in name:
        return False
    namespace, _, bare = name.rpartition(".")
    if not namespace or not bare:
        return False
    item["name"] = bare
    item["namespace"] = namespace
    return True
```

Apply to `response.output_item.added`, `response.output_item.done`, and the final
`response.completed` payload. Pass the model name into the SSE rewriter through its state dict.

## 6. Stop narration-only turns

Two layers. The cheap one goes in the request; the expensive one buffers the response.

**Request layer** — append a developer message at the *end* of `input` (the last thing the model
reads), not only in `instructions`:

```
严格约束（本条优先级最高）：本轮回复要么直接发起工具调用，要么给出最终答复，
不允许只写「正在修」「马上改」「我来看看」这类说明——只描述计划而不调用工具，视为任务失败。
```

**Response layer** — for streaming Muse responses, read the body first, then decide. Parse SSE
`data:` frames and look only at *model output items* (`response.output_item.added|done`,
`response.output_text.delta`, `response.completed` → `response.output`):

```python
def _sse_output_signals(body):
    """Return (has_tool_call, output_text). Never scan the raw body:
    response.created echoes `instructions`, and injected constraints contain
    words like 正在修, which would flag every response as a stall."""
```

Treat a response as stalled when it has no `function_call`/`custom_tool_call` **and** either the
output text is empty or it is short (≤ ~300 chars) and contains plan-shaped wording (正在 / 马上 /
这就 / 已定位 / I'll / let me). On a stall, re-issue the request with an extra developer message
("上一条回复没有调用工具…"), up to two times, then forward whatever came back so the client is
never left hanging. Keep a circuit breaker (same request body ≤ 6 retries per 2 minutes) so a
client retry loop cannot multiply upstream calls.

## Switches and rollback

```
VISION_PROXY_MUSE_SCHEMA_FIX=1     # depth cap + $ref inlining + strict relaxation
VISION_PROXY_MUSE_NO_PREAMBLE=1    # trailing constraint in input
VISION_PROXY_MUSE_STALL_RETRY=1    # buffered stall detection + retry
VISION_PROXY_MUSE_TOOLNAME_FIX=1   # dotted tool-name splitting
```

Read them from the proxy's env file so a fix can be disabled without a code change. Rolling the
whole change back is a single file copy from the timestamped backup taken before editing.

## Verification checklist

1. `python3 -m py_compile <proxy>` before restarting anything.
2. `scripts/test_muse_compat.py <proxy>` — offline, 12 assertions, no network.
3. One live Muse request and one non-Muse request; confirm 200 on both and that the non-Muse log
   lines contain nothing Muse-related.
4. Replay the exact failing payload from the proxy log (restore the model's `-go` suffix if the
   dump was taken after rewriting) and confirm it now returns 200.
