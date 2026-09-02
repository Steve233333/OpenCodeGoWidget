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


for name, fn in list(globals().items()):
    if name.startswith("t_") or name.startswith("test_"):
        check(name, fn)

print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
if FAIL:
    sys.exit(1)
