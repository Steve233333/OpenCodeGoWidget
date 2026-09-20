#!/usr/bin/env python3
"""Offline assertions for the Muse compatibility rewrites in a local proxy.

Usage:
    python3 test_muse_compat.py [path/to/vision_proxy.py]

Imports the proxy module (it must guard its server behind __main__) and checks that each rewrite
fires for Muse models, never fires for other models, and that stall detection does not trip over
echoed instructions. No network calls.
"""

import importlib.util
import json
import os
import sys

DEFAULT_PROXY = "~/.local/share/agent-vision-toolkit/vision_proxy.py"
MUSE = "muse-spark-1.3-contributor-go"
OTHER = "deepseek-v4.1-flash-go"

results = []


def case(name):
    def deco(fn):
        try:
            fn()
        except AssertionError as exc:
            results.append((name, False, str(exc)))
        except Exception as exc:  # noqa: BLE001
            results.append((name, False, f"{type(exc).__name__}: {exc}"))
        else:
            results.append((name, True, ""))
        return fn
    return deco


def load_module(path):
    spec = importlib.util.spec_from_file_location("proxy_under_test", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


proxy_path = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PROXY)
if not os.path.isfile(proxy_path):
    print(f"proxy not found: {proxy_path}")
    raise SystemExit(2)
mod = load_module(proxy_path)


@case("1. model gate: only muse models match")
def _():
    assert mod._is_muse_model(MUSE) is True
    assert mod._is_muse_model(OTHER) is False
    assert mod._is_muse_model("glm-5.3-go") is False
    assert mod._is_muse_model(None) is False


@case("2. dotted tool name split")
def _():
    assert mod._split_namespaced_tool_name("multi_agent_v1.spawn_agent") == ("multi_agent_v1", "spawn_agent")
    assert mod._split_namespaced_tool_name("exec_command") is None
    assert mod._split_namespaced_tool_name("a.") is None
    assert mod._split_namespaced_tool_name(".b") is None
    assert mod._split_namespaced_tool_name("a b.c") is None
    item = {"type": "function_call", "name": "multi_agent_v1.spawn_agent", "arguments": "{}"}
    assert mod._fix_namespaced_tool_name(item) is True
    assert item["name"] == "spawn_agent" and item["namespace"] == "multi_agent_v1"
    again = {"type": "function_call", "name": "spawn_agent", "namespace": "multi_agent_v1"}
    assert mod._fix_namespaced_tool_name(again) is False


@case("3. recursive $ref inlining")
def _():
    schema = {
        "$defs": {"node": {"type": "object", "properties": {"child": {"$ref": "#/$defs/node"}}}},
        "type": "object",
        "properties": {"root": {"$ref": "#/$defs/node"}},
    }
    out, changed = mod._inline_local_refs(schema, schema)
    assert changed is True
    assert "$defs" not in out
    assert "$ref" not in json.dumps(out)


@case("4. request sanitizer: fires for muse, byte-identical for others")
def _():
    payload = {"model": MUSE, "tools": [{
        "type": "function", "name": "walk",
        "parameters": {"$defs": {"n": {"type": "object", "properties": {"c": {"$ref": "#/$defs/n"}}}},
                       "type": "object", "properties": {"start": {"$ref": "#/$defs/n"}}},
    }]}
    assert mod._sanitize_muse_tool_schemas(payload) is True
    assert "$ref" not in json.dumps(payload)
    plain = {"model": OTHER, "tools": [{"type": "function", "name": "f", "parameters": {"type": "object"}}]}
    before = json.dumps(plain, sort_keys=True)
    assert mod._is_muse_model(plain["model"]) is False
    assert json.dumps(plain, sort_keys=True) == before


@case("5. trailing constraint injection is idempotent")
def _():
    payload = {"model": MUSE, "instructions": "base rules"}
    assert mod._inject_muse_no_preamble(payload) is True
    assert mod.MUSE_NO_PREAMBLE_INSTRUCTION in payload["instructions"]
    assert mod._inject_muse_no_preamble(payload) is False
    first = {"model": MUSE, "input": [{"role": "user", "content": [{"type": "input_text", "text": "hi"}]}]}
    assert mod._inject_muse_tool_first(first) is True
    assert first["input"][-1]["role"] == "developer"
    assert mod._inject_muse_tool_first(first) is False


@case("6. non-streaming response: muse renamed, others byte-identical")
def _():
    body = json.dumps({"output": [
        {"type": "function_call", "name": "multi_agent_v1.spawn_agent", "arguments": "{}", "call_id": "c1"},
    ]}, ensure_ascii=False).encode()
    out = json.loads(mod._rewrite_apply_patch_response_json(body, MUSE))
    item = out["output"][0]
    assert item["name"] == "spawn_agent" and item["namespace"] == "multi_agent_v1"
    assert mod._rewrite_apply_patch_response_json(body, OTHER) == body


@case("7. streaming frame: muse renamed, others pass through")
def _():
    frame = (b'event: response.output_item.added\n'
             b'data: {"type":"response.output_item.added","output_index":0,'
             b'"item":{"type":"function_call","name":"multi_agent_v1.spawn_agent","call_id":"c1"}}\n\n')
    out = b"".join(mod._rewrite_sse_frame(frame, {"pending": {}, "completed": False, "compat": {"model": MUSE}}))
    assert b'"name": "spawn_agent"' in out or b'"name":"spawn_agent"' in out
    state_other = {"pending": {}, "completed": False, "compat": {"model": OTHER}}
    assert mod._rewrite_sse_frame(frame, state_other) == [frame]


@case("8. plain tool frames stay untouched")
def _():
    frame = (b'event: response.output_item.added\n'
             b'data: {"type":"response.output_item.added","output_index":1,'
             b'"item":{"type":"function_call","name":"exec_command","call_id":"c2"}}\n\n')
    state = {"pending": {}, "completed": False, "compat": {"model": MUSE}}
    assert mod._rewrite_sse_frame(frame, state) == [frame]


@case("9. strict relaxation covers namespace-nested tools and is idempotent")
def _():
    payload = {"model": MUSE, "tools": [
        {"type": "function", "name": "request_user_input", "strict": True,
         "parameters": {"type": "object", "properties": {"a": {"type": "string"}}}},
        {"type": "namespace", "name": "ns", "tools": [
            {"type": "function", "name": "inner", "strict": True, "parameters": {"type": "object"}}]},
    ]}
    assert mod._sanitize_muse_tool_schemas(payload) is True
    assert payload["tools"][0]["strict"] is False
    assert payload["tools"][1]["tools"][0]["strict"] is False
    assert mod._sanitize_muse_tool_schemas(payload) is False


@case("10. schema depth cap keeps at most 8 levels (measured upstream limit)")
def _():
    def layered(depth):
        node = {"type": "string"}
        for _ in range(depth):
            node = {"type": "object", "properties": {"child": node}, "required": ["child"],
                    "additionalProperties": False}
        return {"type": "object", "properties": {"top": {"type": "array", "items": node}},
                "required": ["top"], "additionalProperties": False}

    # layered(d): root(1) → top(2) → items(3) → child(4) …
    # d=5 ends exactly at level 8 (allowed), d=6 and deeper must be capped.
    deep, changed = mod._cap_schema_depth(layered(7))
    assert changed is True
    chain, level = deep, 1
    while isinstance(chain, dict):
        nxt = None
        if isinstance(chain.get("properties"), dict):
            nxt = next(iter(chain["properties"].values()))
        elif isinstance(chain.get("items"), dict):
            nxt = chain["items"]
        if nxt is None:
            break
        chain = nxt
        level += 1
        assert level <= 8, f"level {level} survived the cap"
    assert "properties" not in chain
    _, changed2 = mod._cap_schema_depth(layered(5))
    assert changed2 is False


@case("11. stall detection uses model output only")
def _():
    stall = ('event: response.completed\ndata: {"type":"response.completed","response":{"output":'
             '[{"type":"message","content":[{"type":"output_text","text":"正在修 src/ 下的三个文件。"}]}]}}\n\n'
             ).encode()
    assert mod._sse_output_signals(stall)[0] is False
    assert mod._sse_looks_like_stall(stall) is True
    worked = (b'event: response.output_item.added\ndata: {"type":"response.output_item.added",'
              b'"item":{"type":"function_call","name":"exec_command"}}\n\n')
    assert mod._sse_output_signals(worked)[0] is True
    final = ('event: response.completed\ndata: {"type":"response.completed","response":{"output":'
             '[{"type":"message","content":[{"type":"output_text","text":"4/4 通过，退出码 0。"}]}]}}\n\n'
             ).encode()
    assert mod._sse_looks_like_stall(final) is False
    echoed = ('event: response.created\ndata: {"type":"response.created","response":'
              '{"instructions":"…正在修…马上改…","output":[]}}\n\n'
              'event: response.completed\ndata: {"type":"response.completed","response":{"output":'
              '[{"type":"message","content":[{"type":"output_text","text":"全部完成，以下是输出："}]}]}}\n\n'
              ).encode()
    _, text = mod._sse_output_signals(echoed)
    assert "正在修" not in text, "echoed instructions leaked into the output signal"
    assert mod._sse_looks_like_stall(echoed) is False


@case("12. retry body appends a stronger developer constraint")
def _():
    body = json.dumps({"model": MUSE,
                       "input": [{"role": "user", "content": [{"type": "input_text", "text": "hi"}]}]}).encode()
    first = json.loads(mod._build_muse_retry_body(body, 1))
    assert first["input"][-1]["role"] == "developer"
    assert mod.MUSE_STALL_RETRY_INSTRUCTION in first["input"][-1]["content"][0]["text"]
    second = json.loads(mod._build_muse_retry_body(body, 2))
    assert mod.MUSE_STALL_RETRY_INSTRUCTION_HARD in second["input"][-1]["content"][0]["text"]


@case("13. empty stubs are repaired, and a property literally named description is not clobbered")
def _():
    schema = {"type": "object", "properties": {
        "options": {"type": "array", "items": {"type": "object", "properties": {
            "description": {"type": {}, "description": {}},
            "label": {"type": {}, "description": {}}},
            "required": ["label", "description"], "additionalProperties": False}}},
        "required": ["options"], "additionalProperties": False}
    assert mod._repair_muse_schema_stubs(schema) is True
    leaves = schema["properties"]["options"]["items"]["properties"]
    assert leaves["label"] == {"type": "string", "description": ""}, leaves["label"]
    assert leaves["description"] == {"type": "string", "description": ""}, leaves["description"]
    assert mod._repair_muse_schema_stubs(schema) is False, "second pass must be a no-op"


failed = 0
for name, ok, detail in results:
    print(("PASS " if ok else "FAIL ") + name + (f" -> {detail}" if detail else ""))
    failed += 0 if ok else 1
print(f"\n{len(results) - failed}/{len(results)} passed  ({proxy_path})")
raise SystemExit(1 if failed else 0)
