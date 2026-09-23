"""Unit tests for vision_proxy protocol-translation helpers.

Run: python3 tests/test_units.py   (from the agent-vision-toolkit dir)
No network required.
"""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

spec = importlib.util.spec_from_file_location("vp", os.path.join(ROOT, "vision_proxy.py"))
vp = importlib.util.module_from_spec(spec)
sys.modules["vp"] = vp
spec.loader.exec_module(vp)

PASS, FAIL = [], []


def check(name, fn):
    try:
        fn()
        PASS.append(name)
        print(f"  PASS {name}")
    except Exception as exc:  # noqa: BLE001
        FAIL.append((name, repr(exc)))
        print(f"  FAIL {name}: {exc!r}")


# ---------------------------------------------------------------- request translation
def t_request_basic():
    req = {"model": "mimo-v2.5", "instructions": "You are Codex", "stream": True,
           "input": [
               {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "列出文件"}]},
               {"type": "reasoning", "summary": []},
               {"type": "function_call", "call_id": "call_a", "name": "shell", "arguments": "{\"cmd\":\"ls\"}"},
               {"type": "function_call_output", "call_id": "call_a", "output": "a.txt"},
               {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "done"}]}],
           "tools": [{"type": "function", "name": "shell", "description": "run",
                      "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}}, "required": ["cmd"]},
                      "strict": False}],
           "tool_choice": "auto", "parallel_tool_calls": False,
           "reasoning": {"effort": "high"}, "store": False}
    chat = vp._responses_request_to_chat(req)
    assert chat["messages"][0] == {"role": "system", "content": "You are Codex"}
    assert chat["messages"][1]["content"] == "列出文件"
    assert chat["messages"][2]["tool_calls"][0]["id"] == "call_a"
    assert chat["messages"][3] == {"role": "tool", "tool_call_id": "call_a", "content": "a.txt"}
    assert chat["tools"][0]["function"]["name"] == "shell"
    assert "strict" not in json.dumps(chat)
    assert chat["reasoning_effort"] == "high"
    assert "max_tokens" not in chat and chat["stream"] is True


def t_request_developer_role():
    req = {"model": "glm-5.3", "input": [{"type": "message", "role": "developer",
                                          "content": [{"type": "input_text", "text": "rules"}]}]}
    assert vp._responses_request_to_chat(req)["messages"] == [{"role": "system", "content": "rules"}]


def t_request_image():
    req = {"model": "mimo-v2.5", "input": [{"type": "message", "role": "user", "content": [
        {"type": "input_text", "text": "看图"},
        {"type": "input_image", "image_url": "data:image/png;base64,iVBOR"}]}]}
    parts = vp._responses_request_to_chat(req)["messages"][0]["content"]
    assert parts[0] == {"type": "text", "text": "看图"}
    assert parts[1]["type"] == "image_url"


def t_request_string_input():
    req = {"model": "mimo-v2.5", "input": "hi"}
    assert vp._responses_request_to_chat(req)["messages"] == [{"role": "user", "content": "hi"}]


def t_multi_tool_merge():
    req = {"model": "mimo-v2.5", "input": [
        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "two"}]},
        {"type": "function_call", "call_id": "c1", "name": "shell", "arguments": "{\"a\":1}"},
        {"type": "function_call", "call_id": "c2", "name": "shell", "arguments": "{\"b\":2}"}]}
    msgs = vp._responses_request_to_chat(req)["messages"]
    assert len(msgs) == 2 and [t["id"] for t in msgs[1]["tool_calls"]] == ["c1", "c2"]


# ---------------------------------------------------------------- stream aggregation / events
def _sse_bytes(chunks):
    return b"".join(("data: " + json.dumps(c) + "\n\n").encode() for c in chunks) + b"data: [DONE]\n\n"


def t_stream_text_and_tool():
    sse = _sse_bytes([
        {"choices": [{"delta": {"role": "assistant", "content": "你"}}]},
        {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "call_z", "type": "function",
                                                "function": {"name": "shell", "arguments": "{\"cmd\""}}]}}]},
        {"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"arguments": ":\"pwd\"}"}}]}}]},
        {"choices": [{"delta": {}, "finish_reason": "tool_calls"}],
         "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}},
    ])
    frames = vp._build_chat_fallback_events("mimo-v2.5", sse, "high")
    lines = [l for l in frames.decode().split("\n") if l.startswith("data: ")]
    types = [json.loads(l[6:])["type"] for l in lines]
    assert types[0] == "response.created" and types[-1] == "response.completed"
    completed = json.loads(lines[-1][6:])
    assert completed["response"]["status"] == "completed"
    assert completed["response"]["usage"]["total_tokens"] == 15
    fc = [o for o in completed["response"]["output"] if o["type"] == "function_call"][0]
    assert json.loads(fc["arguments"]) == {"cmd": "pwd"}


def t_stream_swallowed_brace_repair():
    bad_args = 'cmd":"pwd"}'  # missing {" prefix (fault-20 style)
    chunk = json.dumps({"choices": [{"delta": {"tool_calls": [
        {"index": 0, "id": "c9", "type": "function",
         "function": {"name": "shell", "arguments": bad_args}}]}, "finish_reason": "tool_calls"}]})
    frames = vp._build_chat_fallback_events("glm-5.3", ("data: " + chunk + "\n\n").encode())
    lines = [l for l in frames.decode().split("\n") if l.startswith("data: ")]
    completed = json.loads(lines[-1][6:])
    fc = [o for o in completed["response"]["output"] if o["type"] == "function_call"][0]
    assert json.loads(fc["arguments"]) == {"cmd": "pwd"}, fc["arguments"]


def t_nonstream_json():
    obj = {"choices": [{"message": {"role": "assistant", "content": "ok",
            "tool_calls": [{"id": "c1", "type": "function",
                            "function": {"name": "shell", "arguments": "{\"x\": 1}"}}]},
            "finish_reason": "tool_calls"}],
           "usage": {"prompt_tokens": 3, "completion_tokens": 2}}
    rj = vp._build_chat_fallback_json("glm-5.3", obj)
    assert rj["status"] == "completed"
    assert rj["output"][0]["content"][0]["text"] == "ok"
    assert rj["usage"]["total_tokens"] == 5
    assert json.loads(rj["output"][1]["arguments"]) == {"x": 1}


def t_sanitize_args():
    assert json.loads(vp._sanitize_fc_args('cmd":"pwd"}')) == {"cmd": "pwd"}
    healthy = '{"a": 1}'
    assert vp._sanitize_fc_args(healthy) == healthy


def t_reasoning_delta_events():
    """P4: reasoning_content must surface as reasoning summary deltas (incremental path)."""
    sse = _sse_bytes([
        {"choices": [{"delta": {"reasoning_content": "想一下"}}]},
        {"choices": [{"delta": {"content": "ok"}}], "usage": {"prompt_tokens": 1, "completion_tokens": 1}},
    ])
    tr = vp.ChatBridgeTranslator("mimo-v2.5")
    out = tr.on_created()
    buf = sse
    while not tr.finished:
        frame, rest = vp._split_sse_frame(buf)
        if frame is None:
            break
        out += tr.on_chat_frame(frame)
        buf = rest
    tail = tr.on_finish()
    allbytes = out + tail
    types = [json.loads(l[6:])["type"] for l in allbytes.decode().split("\n") if l.startswith("data: ")]
    assert "response.reasoning_summary_text.delta" in types, types
    completed = last_frame(allbytes)
    kinds = [o["type"] for o in completed["response"]["output"]]
    assert "reasoning" in kinds and "message" in kinds, kinds


def test_incremental_translator():
    """P3/P5: incremental translator emits deltas as they arrive."""
    tr = vp.ChatBridgeTranslator("mimo-v2.5", effort="high")
    first = tr.on_created()
    assert b"response.created" in first and b"in_progress" in first
    d1 = tr.on_content_delta("你")
    assert b"output_item.added" in d1 and b"output_text.delta" in d1
    assert "你".encode() in d1 or b"\\u4f60" in d1
    d2 = tr.on_content_delta("好")
    assert b"output_item.added" not in d2 and b"output_text.delta" in d2
    t1 = tr.on_tool_delta(0, "call_1", "shell", "{\"cmd\": \"pwd\"}")
    assert b"function_call_arguments.delta" in t1
    tail = tr.on_finish("tool_calls", {"prompt_tokens": 2, "completion_tokens": 3})
    assert b"response.completed" in tail
    completed = last_frame(tail)
    fc = [o for o in completed["response"]["output"] if o["type"] == "function_call"][0]
    assert json.loads(fc["arguments"]) == {"cmd": "pwd"}


def last_frame(body: bytes):
    lines = [l for l in body.decode(errors="replace").split("\n") if l.startswith("data: ")]
    return json.loads(lines[-1][6:])


def test_budget():
    """P5: byte budget forces truncation instead of unbounded buffering."""
    tr = vp.ChatBridgeTranslator("mimo-v2.5", byte_budget=1024)
    tr.on_created()
    out = b""
    for _ in range(100):
        out = out + (tr.on_content_delta("x" * 512) or b"")
        if tr.finished:
            break
    assert tr.truncated, "budget never triggered"
    tail = tr.on_finish("stop", None)
    completed = last_frame(out + tail)
    assert completed["response"]["status"] in ("completed", "incomplete")


# ---------------------------------------------------------------- muse float->int (fault: Codex u64 vs 30000.0)
MUSE_FLOAT_ARGS = '{"cmd":"curl -sL \\"https://example.com\\" | head -150","yield_time_ms":30000.0}'


def t_coerce_float_muse_case():
    """Exact 2026-09-12 Muse loop: yield_time_ms 30000.0 must become int 30000."""
    fixed = vp._coerce_float_ints_in_args_str(MUSE_FLOAT_ARGS)
    obj = json.loads(fixed)
    assert obj["yield_time_ms"] == 30000 and isinstance(obj["yield_time_ms"], int), fixed
    assert obj["cmd"].startswith("curl -sL"), fixed


def t_coerce_float_nested_and_preserve():
    src = '{"a": {"b": [1.0, 2.5, {"c": 8000.0}]}, "t": 0.5, "s": "30000.0", "flag": true, "n": null}'
    obj = json.loads(vp._coerce_float_ints_in_args_str(src))
    assert obj["a"]["b"] == [1, 2.5, {"c": 8000}], obj
    assert isinstance(obj["a"]["b"][0], int) and isinstance(obj["a"]["b"][1], float)
    assert obj["t"] == 0.5 and obj["s"] == "30000.0" and obj["flag"] is True and obj["n"] is None


def t_coerce_float_passthrough():
    healthy = '{"yield_time_ms": 30000, "cmd": "ls"}'
    assert vp._coerce_float_ints_in_args_str(healthy) == healthy
    for bad in ("", "not json", "[1, 2]", "42", "null"):
        assert vp._coerce_float_ints_in_args_str(bad) == bad, bad
    assert vp._coerce_float_ints_in_args_str(None) is None


def t_sanitize_fc_args_coerces_float():
    out = vp._sanitize_fc_args(MUSE_FLOAT_ARGS)
    assert json.loads(out)["yield_time_ms"] == 30000, out
    healthy = '{"a": 1}'
    assert vp._sanitize_fc_args(healthy) == healthy


def _done_frame(args, event_style=False):
    payload = {"type": "response.function_call_arguments.done", "item_id": "fc_1",
               "output_index": 0, "arguments": args}
    body = json.dumps(payload)
    if event_style:
        return f"event: response.function_call_arguments.done\ndata: {body}\n\n".encode()
    return f"data: {body}\n\n".encode()


def t_sse_done_frame_coerce():
    for event_style in (False, True):
        out = vp._rewrite_sse_frame(_done_frame(MUSE_FLOAT_ARGS, event_style),
                                    {"pending": {}, "completed": False})
        assert len(out) == 1, out
        text = out[0].decode()
        if event_style:
            assert text.startswith("event: response.function_call_arguments.done"), text
        else:
            assert text.startswith("data: "), text
        data_line = [l for l in text.splitlines() if l.startswith("data: ")][0]
        assert json.loads(json.loads(data_line[6:])["arguments"])["yield_time_ms"] == 30000, text


def t_sse_done_frame_healthy_passthrough():
    healthy = '{"yield_time_ms": 30000}'
    frame = _done_frame(healthy)
    assert vp._rewrite_sse_frame(frame, {"pending": {}, "completed": False}) == [frame]


def t_sse_output_item_done_coerce():
    item = {"id": "fc_1", "type": "function_call", "status": "completed",
            "call_id": "call_1", "name": "exec_command", "arguments": MUSE_FLOAT_ARGS}
    frame = ("data: " + json.dumps({"type": "response.output_item.done",
                                    "output_index": 0, "item": item}) + "\n\n").encode()
    out = vp._rewrite_sse_frame(frame, {"pending": {}, "completed": False})
    assert len(out) == 1
    got = json.loads([l for l in out[0].decode().splitlines() if l.startswith("data: ")][0][6:])
    assert json.loads(got["item"]["arguments"])["yield_time_ms"] == 30000, got


def t_nonstream_json_coerce_generic():
    body = json.dumps({"output": [
        {"type": "function_call", "name": "exec_command", "call_id": "call_1",
         "arguments": MUSE_FLOAT_ARGS, "status": "completed"}]}).encode()
    out = vp._rewrite_apply_patch_response_json(body)
    assert out != body
    item = json.loads(out)["output"][0]
    assert item["type"] == "function_call"  # generic call untouched except args
    assert json.loads(item["arguments"])["yield_time_ms"] == 30000, item


def t_history_coerce_float():
    parsed = {"model": "muse-spark-1.3-contributor", "input": [
        {"type": "function_call", "call_id": "c1", "name": "exec_command",
         "arguments": MUSE_FLOAT_ARGS}]}
    assert vp._normalize_fc_args_history(parsed) is True
    assert json.loads(parsed["input"][0]["arguments"])["yield_time_ms"] == 30000


# ------------------------------------------------- messages bridge (union-alpha, 2026-09-17)
CODEX_MESSAGES_REQ = {
    "model": "union-alpha",
    "instructions": "You are Codex",
    "stream": True,
    "max_output_tokens": 8000,
    "tool_choice": "auto",
    "parallel_tool_calls": False,
    "tools": [
        {"type": "function", "name": "shell", "description": "run a command",
         "parameters": {"type": "object", "properties": {"cmd": {"type": "string"}}, "required": ["cmd"]}},
        {"type": "web_search_preview"},
    ],
    "input": [
        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "看看目录"}]},
        {"type": "reasoning", "summary": []},
        {"type": "function_call", "call_id": "call_1", "name": "shell", "arguments": "{\"cmd\": \"ls\"}"},
        {"type": "function_call_output", "call_id": "call_1", "output": "a.txt"},
        {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "只有一个文件"}]},
        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "再列一次"}]},
    ],
}


def t_messages_request_translation():
    payload = vp._responses_request_to_messages(CODEX_MESSAGES_REQ)
    assert payload["model"] == "union-alpha"
    assert payload["stream"] is True
    assert payload["max_tokens"] == 8000, payload["max_tokens"]
    assert payload["system"] == "You are Codex"
    # 首条必须是 user；reasoning 条目被丢掉；tool_result 自成下一轮 user
    roles = [m["role"] for m in payload["messages"]]
    assert roles == ["user", "assistant", "user", "assistant", "user"], payload["messages"]
    assert payload["messages"][0]["content"] == [{"type": "text", "text": "看看目录"}]
    assert payload["messages"][2]["content"][0]["type"] == "tool_result", payload["messages"][2]
    assert payload["messages"][2]["content"][0]["tool_use_id"] == "call_1"
    assert payload["messages"][3]["content"][0]["text"] == "只有一个文件"
    # 工具：function -> input_schema；原生 web_search 不下发
    assert len(payload["tools"]) == 1, payload["tools"]
    tool = payload["tools"][0]
    assert tool["name"] == "shell" and tool["input_schema"]["type"] == "object"
    assert tool["description"] == "run a command"
    assert payload["tool_choice"] == {"type": "auto"}


def t_messages_tool_use_history():
    payload = vp._responses_request_to_messages(CODEX_MESSAGES_REQ)
    # function_call 要落成 assistant 的 tool_use 块（Anthropic 只认这个形状）
    assistant = payload["messages"][1]
    assert assistant["role"] == "assistant"
    assert [b["type"] for b in assistant["content"]] == ["tool_use"], assistant
    tool_use = assistant["content"][0]
    assert tool_use["id"] == "call_1" and tool_use["name"] == "shell"
    assert tool_use["input"] == {"cmd": "ls"}, tool_use
    # 连续 assistant（tool_use 后面又跟一条 assistant 文本）要合并成一格，不能再开一轮
    assert [b["type"] for b in payload["messages"][3]["content"]] == ["text"]


def t_messages_request_leading_assistant():
    parsed = {"model": "union-alpha",
              "input": [{"type": "message", "role": "assistant", "content": "上一轮"}]}
    payload = vp._responses_request_to_messages(parsed)
    assert payload["messages"][0]["role"] == "user", payload["messages"]
    assert payload["max_tokens"] > 0  # Anthropic 必填


def t_messages_custom_tool_fallback():
    parsed = {"model": "union-alpha", "input": [],
              "tools": [{"type": "custom", "name": "apply_patch", "description": "V4A"}]}
    payload = vp._responses_request_to_messages(parsed)
    assert payload["tools"][0]["name"] == "apply_patch"
    assert payload["tools"][0]["input_schema"]["properties"]["input"]["type"] == "string"


def t_oc_session_stable_per_conversation():
    first = vp._oc_session_id(CODEX_MESSAGES_REQ)
    again = vp._oc_session_id(CODEX_MESSAGES_REQ)
    other = vp._oc_session_id({"model": "union-alpha", "instructions": "别的对话",
                               "input": [{"type": "message", "role": "user", "content": "hi"}]})
    assert first == again
    assert first != other
    assert len(first) == 36


MESSAGES_SSE_TEXT = (
    'event: message_start\n'
    'data: {"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[],'
    '"usage":{"input_tokens":11,"output_tokens":1}}}\n\n'
    'event: content_block_start\n'
    'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
    'event: content_block_delta\n'
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好"}}\n\n'
    'event: content_block_stop\n'
    'data: {"type":"content_block_stop","index":0}\n\n'
    'event: message_delta\n'
    'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}\n\n'
    'event: message_stop\n'
    'data: {"type":"message_stop"}\n\n'
)

MESSAGES_SSE_TOOL = (
    'event: message_start\n'
    'data: {"type":"message_start","message":{"id":"msg_2","role":"assistant","content":[],'
    '"usage":{"input_tokens":20,"output_tokens":1}}}\n\n'
    'event: content_block_start\n'
    'data: {"type":"content_block_start","index":0,"content_block":'
    '{"type":"tool_use","id":"toolu_1","name":"shell","input":{}}}\n\n'
    'event: content_block_delta\n'
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta",'
    '"partial_json":"{\\"cmd\\":"}}\n\n'
    'event: content_block_delta\n'
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta",'
    '"partial_json":" \\"ls -la\\"}"}}\n\n'
    'event: content_block_stop\n'
    'data: {"type":"content_block_stop","index":0}\n\n'
    'event: message_delta\n'
    'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}\n\n'
    'event: message_stop\n'
    'data: {"type":"message_stop"}\n\n'
)


def _messages_events(raw_sse):
    tr = vp.MessagesBridgeTranslator("union-alpha")
    out = tr.ensure_created()
    for frame in raw_sse.split("\n\n"):
        if frame.strip():
            out += tr.on_message_frame(frame.encode())
    events = []
    for line in out.decode().split("\n"):
        if line.startswith("data: "):
            events.append(json.loads(line[6:]))
    return events


def t_messages_stream_text():
    events = _messages_events(MESSAGES_SSE_TEXT)
    types = [e["type"] for e in events]
    assert types[0] == "response.created", types
    assert "response.output_text.delta" in types
    assert types[-1] == "response.completed", types
    delta = next(e for e in events if e["type"] == "response.output_text.delta")
    assert delta["delta"] == "你好"
    final = events[-1]["response"]
    assert final["status"] == "completed"
    assert final["output"][0]["content"][0]["text"] == "你好"
    assert final["usage"]["input_tokens"] == 11 and final["usage"]["output_tokens"] == 7, final["usage"]
    # sequence_number 必须连续递增（Codex 依赖它排序）
    seqs = [e["sequence_number"] for e in events]
    assert seqs == sorted(seqs) and len(set(seqs)) == len(seqs), seqs


def t_messages_stream_tool_json_valid():
    events = _messages_events(MESSAGES_SSE_TOOL)
    final = events[-1]["response"]
    item = final["output"][0]
    assert item["type"] == "function_call", item
    assert item["name"] == "shell" and item["call_id"] == "toolu_1"
    assert json.loads(item["arguments"])["cmd"] == "ls -la", item
    done = [e for e in events if e["type"] == "response.function_call_arguments.done"]
    assert done and json.loads(done[-1]["arguments"])["cmd"] == "ls -la"


def t_messages_stream_error_frame_closes():
    raw = ('event: message_start\n'
           'data: {"type":"message_start","message":{"usage":{"input_tokens":3,"output_tokens":0}}}\n\n'
           'event: error\n'
           'data: {"type":"error","error":{"type":"overloaded_error","message":"busy"}}\n\n')
    events = _messages_events(raw)
    assert events[-1]["type"] == "response.completed", [e["type"] for e in events]


def t_messages_nonstream_json():
    obj = {"id": "msg_3", "type": "message", "role": "assistant", "stop_reason": "tool_use",
           "content": [{"type": "text", "text": "先看看"},
                       {"type": "tool_use", "id": "toolu_9", "name": "shell",
                        "input": {"cmd": "pwd"}}],
           "usage": {"input_tokens": 12, "output_tokens": 4, "cache_read_input_tokens": 3}}
    out = vp._build_messages_fallback_json("union-alpha", obj)
    assert out["status"] == "completed"
    assert [i["type"] for i in out["output"]] == ["message", "function_call"], out["output"]
    assert out["output"][0]["content"][0]["text"] == "先看看"
    assert json.loads(out["output"][1]["arguments"])["cmd"] == "pwd"
    assert out["usage"]["input_tokens"] == 12 and out["usage"]["total_tokens"] == 16
    assert out["usage"]["input_tokens_details"]["cached_tokens"] == 3


def t_union_alpha_is_messages_only_model():
    assert "union-alpha" in vp.MESSAGES_ALWAYS_BRIDGE
    assert "union-alpha" not in vp.RESPONSES_FALLBACK_MODELS


def t_provider_prefix_routes_like_suffix():
    """2026-09-23：macOS 27 升级后 Codex 发过 opencode-go/<slug>，以前认不出来 → 401。"""
    p = {"model": "opencode-go/deepseek-v4.1-flash"}
    assert vp._rewrite_go_model(p) is True, p
    assert p["model"] == "deepseek-v4.1-flash", p

    p = {"model": "opencode-zen/muse-spark-1.2-contributor"}
    assert vp._rewrite_zen_model(p) is True, p
    assert p["model"] == "muse-spark-1.2-contributor", p


def t_provider_prefix_does_not_steal_other_routes():
    # go 前缀不能被 zen 分支吃掉（顺序是 zen → go）
    p = {"model": "opencode-go/x"}
    assert vp._rewrite_zen_model(p) is False and p["model"] == "opencode-go/x", p
    # 裸名 / 官方模型 / 陌生前缀一律原样，行为不变
    for raw in ("deepseek-v4-flash-vision-exp", "deepseek-v4-pro", "foo/bar", "glm-5.3"):
        p = {"model": raw}
        assert vp._rewrite_go_model(p) is False and vp._rewrite_zen_model(p) is False, raw
        assert p["model"] == raw, raw


def t_provider_prefix_keeps_aliases():
    # 别名表在去前缀后照旧生效
    p = {"model": "opencode-go/ox-alpha"}
    assert vp._rewrite_go_model(p) is True and p["model"] == "ox-alpha-free", p
    p = {"model": "opencode-zen/ox-alpha"}
    assert vp._rewrite_zen_model(p) is True and p["model"] == "x-preview-f-free", p


def _sse(state, payload):
    """把一帧喂进状态机（等价于真实流里的一帧）"""
    return vp._rewrite_sse_frame(f"data: {json.dumps(payload)}\n\n".encode(), state)


def t_terminal_repair_sees_complete_turn():
    """2026-09-23：上游不发终止帧、但内容已完整（开过的项都 done）→ 应判定"可补 completed"。
    对齐 opencodex 的 modelResponsesTerminalRepair（muse-spark 在 Go/Zen 网关的常见收尾）。"""
    st = {"pending": {}, "completed": False}
    _sse(st, {"type": "response.created", "response": {"id": "r1"}})
    _sse(st, {"type": "response.output_item.added", "output_index": 0,
              "item": {"id": "msg_1", "type": "message", "status": "in_progress"}})
    assert vp.sse_turn_looks_complete(st) is False, "项还开着，不该判定完整"
    _sse(st, {"type": "response.output_item.done", "output_index": 0,
              "item": {"id": "msg_1", "type": "message", "status": "completed"}})
    assert vp.sse_turn_looks_complete(st) is True, "开过的项都 done 了，应判定完整"
    assert st["completed_items"] and st["completed_items"][0]["id"] == "msg_1", "要留一份完成的项"


def t_terminal_repair_rejects_partial_turn():
    st = {"pending": {}, "completed": False}
    _sse(st, {"type": "response.output_item.added", "output_index": 0, "item": {"id": "a"}})
    _sse(st, {"type": "response.output_item.done", "output_index": 0, "item": {"id": "a"}})
    _sse(st, {"type": "response.output_item.added", "output_index": 1, "item": {"id": "b"}})
    assert vp.sse_turn_looks_complete(st) is False, "还有项没 done，不能当完整"
    empty = {"pending": {}, "completed": False}
    assert vp.sse_turn_looks_complete(empty) is False, "什么都没有时也不算完整"


def t_terminal_frame_still_wins():
    """真收到终止帧时，状态机照旧标记 completed（不依赖我们的修补）"""
    st = {"pending": {}, "completed": False}
    _sse(st, {"type": "response.completed", "response": {"id": "r1", "status": "completed"}})
    assert st["completed"] is True


def t_mimo_markup_is_extracted_from_text():
    """2026-09-23：MiMo 把工具调用写成 XML 混在正文里（本机 9/22 真漏过）→ 要摘成 function_call"""
    text = ("好的，我先看看。"
            "<tool_call><function=write_stdin><parameter=session_id>77397</parameter>"
            "<parameter=chars>x</parameter></tool_call>然后继续。")
    clean, calls = vp.parse_mimo_tool_markup(
        text, {"write_stdin": {"session_id": "integer", "chars": "string"}})
    assert clean == "好的，我先看看。然后继续。", repr(clean)
    assert len(calls) == 1 and calls[0]["name"] == "write_stdin", calls
    args = json.loads(calls[0]["args"])
    # 类型按请求里的 schema 转：session_id 是整数、chars 保持字符串（"1" 也不能变成 int）
    assert args == {"session_id": 77397, "chars": "x"}, args


def t_mimo_markup_tolerates_missing_closers():
    """网关经常不补 </function>，还爱多吐孤立的 </parameter>（opencodex #5637 同款）"""
    text = ("<tool_call><function=exec><parameter=cmd>ls -la</parameter>RAW JS</parameter></tool_call>")
    clean, calls = vp.parse_mimo_tool_markup(text, {"exec": {"cmd": "string"}})
    assert clean == "", repr(clean)
    assert calls and calls[0]["name"] == "exec" and json.loads(calls[0]["args"])["cmd"] == "ls -la", calls


def t_mimo_markup_leaves_plain_text_alone():
    for text in ("普通正文，没有 markup", "<tool_call>但没闭合", "说了一半 <foo> 东西"):
        clean, calls = vp.parse_mimo_tool_markup(text)
        assert clean == text and calls == [], (text, clean, calls)
    assert vp.mimo_markup_hold_len("abc<tool") == 5     # 可能是开标签的前缀 → 要扣住
    assert vp.mimo_markup_hold_len("abc") == 0


def _translate_chat_stream(chunks, tool_param_types=None):
    tr = vp.ChatBridgeTranslator("mimo-v2.6-flash", tool_param_types=tool_param_types)
    out = tr.on_created()
    for piece in chunks:
        out += tr.on_chat_frame(("data: " + json.dumps({"choices": [{"delta": {"content": piece}}]}) + "\n\n").encode())
    out += tr.on_finish("stop", None)
    return out.decode("utf-8", errors="replace")


def t_streaming_bridge_converts_markup_to_function_call():
    """流式：正文分批到达，跨 chunk 的 markup 也要认出来，并且不当正文吐出去"""
    pieces = ["我先看看。",
              "<tool_call><function=write_stdin>",
              "<parameter=session_id>77397</parameter>",
              "<parameter=chars>x</parameter></tool_call>",
              "好了。"]
    out = _translate_chat_stream(pieces, {"write_stdin": {"session_id": "integer", "chars": "string"}})
    assert '"type": "function_call"' in out, out[-500:]
    assert '"name": "write_stdin"' in out, out[-500:]
    assert "session_id" in out and "77397" in out, out[-500:]
    assert "<tool_call>" not in out, "markup 不该出现在可见正文里"
    assert "我先看看。" in out and "好了。" in out, "前后的正文要照旧保留"
    assert '"status": "completed"' in out


def t_streaming_bridge_keeps_literal_text():
    """模型真在说这段字面量（一直不闭合）→ 收尾时按正文放出来，不能吃掉用户内容"""
    out = _translate_chat_stream(["我说的是这个写法：", "<tool_call>", "<function=xx>"])
    assert "<tool_call>" in out or "&lt;tool_call&gt;" in out, out[-400:]


def t_nonstream_bridge_converts_markup():
    obj = {"choices": [{"message": {
        "content": "先看看。<tool_call><function=write_stdin><parameter=session_id>1</parameter></tool_call>",
        "tool_calls": []}}]}
    resp = vp._build_chat_fallback_json("mimo-v2.6-flash", obj, None,
                                        tool_param_types={"write_stdin": {"session_id": "integer"}})
    kinds = [i["type"] for i in resp["output"]]
    assert kinds == ["message", "function_call"], kinds
    assert resp["output"][0]["content"][0]["text"] == "先看看。", resp["output"][0]
    assert json.loads(resp["output"][1]["arguments"]) == {"session_id": 1}, resp["output"][1]


def t_broken_responses_backoff_grows_and_resets():
    """原生路径连坏几次后缓存要变长（别每 5 分钟白试一次），成功一次立刻回到最短"""
    import importlib
    cfg = importlib.import_module("proxy.config")
    cfg._RESPONSES_FAIL_STREAK.clear()
    assert cfg.responses_broken_ttl("mimo-v2.5") == 300.0
    cfg._RESPONSES_FAIL_STREAK["mimo-v2.5"] = 1
    assert cfg.responses_broken_ttl("mimo-v2.5") == 300.0
    cfg._RESPONSES_FAIL_STREAK["mimo-v2.5"] = 2
    assert cfg.responses_broken_ttl("mimo-v2.5") == 900.0
    cfg._RESPONSES_FAIL_STREAK["mimo-v2.5"] = 3
    assert cfg.responses_broken_ttl("mimo-v2.5") == 2700.0
    cfg._RESPONSES_FAIL_STREAK["mimo-v2.5"] = 9
    assert cfg.responses_broken_ttl("mimo-v2.5") == 7200.0      # 上限 2 小时
    cfg._RESPONSES_FAIL_STREAK.pop("mimo-v2.5")
    assert cfg.responses_broken_ttl("mimo-v2.5") == 300.0        # 清零后回到最短


def t_muse_min_output_tokens_floor():
    """muse 的推理也算进 max_output_tokens —— 太小会"只思考不出字"（实测 80 预算里 reasoning 占 77）"""
    p = {"model": "muse-spark-1.3-contributor-go", "max_output_tokens": 80}
    changed, before, after = vp._muse_enforce_min_output_tokens(p)
    assert changed and before == 80 and after == 16384 and p["max_output_tokens"] == 16384
    # 够大就别动
    p = {"model": "muse-spark-1.3-contributor", "max_output_tokens": 64000}
    assert vp._muse_enforce_min_output_tokens(p) == (False, 64000, 64000)
    # 没给就照上游默认，绝不擅自设上限
    p = {"model": "muse-spark-1.3-contributor"}
    assert vp._muse_enforce_min_output_tokens(p) == (False, None, None) and "max_output_tokens" not in p
    # 别的模型不碰
    p = {"model": "deepseek-v4.1-flash-go", "max_output_tokens": 10}
    assert vp._muse_enforce_min_output_tokens(p) == (False, None, None) and p["max_output_tokens"] == 10


def t_text_delta_smoothing_splits_bursts_only():
    """上游一次性 flush 大段正文时切成小片（显示才像逐字）；本来就小的帧原样放行"""
    big = ("data: " + json.dumps({"type": "response.output_text.delta", "delta": "字" * 60}) + "\n\n").encode()
    pieces = vp.split_text_delta_frame(big)
    assert len(pieces) == 3, pieces
    assert all(piece.startswith(b"data:") and piece.endswith(b"\n\n") for piece, _ in pieces), "每片都要是完整 SSE 帧"
    assert all(delay > 0 for _, delay in pieces)
    rejoined = "".join(json.loads(piece.decode()[6:].strip())["delta"] for piece, _ in pieces)
    assert rejoined == "字" * 60, "切完拼回来必须一字不差"

    small = ("data: " + json.dumps({"type": "response.output_text.delta", "delta": "短"}) + "\n\n").encode()
    assert vp.split_text_delta_frame(small) == [(small, 0.0)], "小帧不该被改（逐字来的流零影响）"
    other = b'data: {"type":"response.completed"}\n\n'
    assert vp.split_text_delta_frame(other) == [(other, 0.0)], "非正文帧一律原样"


def t_text_delta_pacer_drips_bursts_and_keeps_gradual_streams():
    """漏桶：上游猛推时按速率滴（显示像逐字），本来就均匀的流零延迟；积压深了会加速"""
    def frame(n):
        return ("data: " + json.dumps({"type": "response.output_text.delta", "delta": "字" * n}) + "\n\n").encode()

    pacer = vp.TextDeltaPacer()
    shaped = pacer.shape(frame(30))
    assert len(shaped) > 1 and all(d > 0 for _, d in shaped), "大帧要切片并带间隔"
    assert "".join(json.loads(p.decode()[6:].strip())["delta"] for p, _ in shaped) == "字" * 30, "内容一字不差"
    assert pacer.shape(frame(2))[0][1] > 0, "小帧按速率滴（有延迟但很小）"
    # 工具参数帧绝不能被节流（apply_patch 的上传要靠它）
    args = ("data: " + json.dumps({"type": "response.function_call_arguments.delta",
                                   "delta": "x" * 500}) + "\n\n").encode()
    assert pacer.shape(args) == [(args, 0.0)], "非正文帧必须零延迟"
    # 猛推 200 帧 × 20 字 → 速率要涨上去，别让长答案滴太久
    start_rate = pacer.rate
    for _ in range(200):
        pacer.shape(frame(20))
    assert pacer.rate > start_rate * 2, f"积压后应该加速（{start_rate} → {pacer.rate}）"


for name, fn in list(globals().items()):
    if name.startswith("t_") or name.startswith("test_"):
        check(name, fn)

print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
if FAIL:
    sys.exit(1)
