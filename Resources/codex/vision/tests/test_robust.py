#!/usr/bin/env python3
"""鲁莽性/混沌测试 - 覆盖 vision_proxy 全量边界和异常路径.
Run: python3 tests/test_robust.py [--verbose]
No network required, all local fuzz.
"""
import importlib.util
import json
import os
import sys
import random
import string
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

spec = importlib.util.spec_from_file_location("vp", os.path.join(ROOT, "vision_proxy.py"))
vp = importlib.util.module_from_spec(spec)
sys.modules["vp"] = vp
spec.loader.exec_module(vp)

PASS, FAIL, SKIP = [], [], []
VERBOSE = "--verbose" in sys.argv

def check(name, fn):
    try:
        fn()
        PASS.append(name)
        print(f"  PASS {name}")
        if VERBOSE:
            pass
    except AssertionError as e:
        FAIL.append((name, f"ASSERT: {e}"))
        print(f"  FAIL {name}: {e!r}")
        if VERBOSE:
            import traceback; traceback.print_exc()
    except Exception as e:
        FAIL.append((name, f"EXC: {e!r}"))
        print(f"  FAIL {name}: {e!r}")
        if VERBOSE:
            import traceback; traceback.print_exc()

def _rand_str(n=20, charset=None):
    charset = charset or string.ascii_letters + string.digits + "-_./:;[]{}"
    return "".join(random.choice(charset) for _ in range(n))

# ---------- 1. _responses_request_to_chat 鲁莽输入 ----------

def t_chat_none_input():
    for bad in [None, "", 123, {}, [], {"input": None}, {"input": 999}]:
        out = vp._responses_request_to_chat(bad if isinstance(bad, dict) else {"input": bad} if bad is not None else {})
        assert isinstance(out["messages"], list)

def t_chat_malformed_items():
    req = {"model": "mimo-v2.5", "input": [
        None, "string", 123,
        {"type": "message", "role": "user"},  # no content
        {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": None}]},
        {"type": "message", "role": "user", "content": "not-a-list-but-string"},
        {"type": "function_call", "name": "", "arguments": None},
        {"type": "function_call_output", "output": {"nested": {"a": 1}}},
        {"type": "reasoning", "summary": []},  # should be dropped
        {"type": "web_search_call", "action": {"type": "web_search"}},
    ]}
    out = vp._responses_request_to_chat(req)
    assert isinstance(out["messages"], list)
    # should not raise, even with completely broken items

def t_chat_huge_input():
    # 500 messages, each huge text 10k
    items = [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "x"*10000}]} for _ in range(100)]
    req = {"model": "glm-5.3-go", "input": items}
    out = vp._responses_request_to_chat(req)
    assert len(out["messages"]) == 100

def t_chat_image_variants():
    # data url, http url, missing url, dict url
    cases = [
        {"type": "input_image", "image_url": "data:image/png;base64,abc"},
        {"type": "input_image", "image_url": {"url": "https://example.com/a.png"}},
        {"type": "input_image", "image_url": ""},
        {"type": "input_image", "image_url": None},
        {"type": "input_image"},  # no url
        {"type": "image_url", "image_url": "data:image/png;base64,xxx"},
        {"type": "input_text", "text": ""},
    ]
    req = {"model": "mimo-v2.5", "input": [{"type": "message", "role": "user", "content": cases}]}
    out = vp._responses_request_to_chat(req)
    # should not crash, may produce 1-2 parts
    assert "messages" in out

def t_chat_tools_weird():
    for tools in [
        None, [], "not-a-list",
        [{"type": "function", "name": "", "parameters": None}],
        [{"type": "function", "function": {"name": "a"}}],
        [{"type": "web_search", "name": "search"}],
        [{"type": "function", "name": "shell", "parameters": {"type": "object", "properties": {"a": {"type": "string"}}}}, {"type": "function", "name": "shell2"}],
    ]:
        req = {"model": "mimo-v2.5", "input": [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hi"}]}], "tools": tools}
        out = vp._responses_request_to_chat(req)
        assert isinstance(out, dict)

def t_chat_tool_choice_variants():
    for choice in [None, "auto", "none", "required", "invalid_choice", "", 123]:
        req = {"model": "mimo-v2.5", "input": [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hi"}]}], "tools": [{"type": "function", "name": "a", "parameters": {}}], "tool_choice": choice}
        out = vp._responses_request_to_chat(req)
        assert out["tool_choice"] in ("auto", "none", "required")

def t_chat_reasoning_clamp_weird():
    # unknown effort, empty, alias
    for effort in [None, "", "unknown_effort", "minimal", "ultra", "none", "super_high", 123]:
        req = {"model": "mimo-v2.5-go", "input": [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hi"}]}], "reasoning": {"effort": effort}}
        out = vp._responses_request_to_chat(req)
        # should not crash, may have reasoning_effort or not
        assert isinstance(out, dict)

def t_chat_multi_tool_merge_stress():
    # 20 parallel tool calls in history should merge into one assistant message with 20 calls
    items = [{"type": "message", "role": "user", "content": [{"type": "input_text", "text": "go"}]}]
    for i in range(20):
        items.append({"type": "function_call", "call_id": f"c{i}", "name": "shell", "arguments": '{"a":1}'})
    req = {"model": "mimo-v2.5", "input": items}
    out = vp._responses_request_to_chat(req)
    # should have user + assistant with 20 calls
    assert len(out["messages"]) == 2
    assert len(out["messages"][1]["tool_calls"]) == 20

# ---------- 2. _content_parts_to_chat 边界 ----------

def t_content_parts_edge():
    assert vp._content_parts_to_chat(None) is None
    assert vp._content_parts_to_chat("") == ""
    assert vp._content_parts_to_chat([]) is None
    assert vp._content_parts_to_chat([{"type": "unknown", "text": "hi"}]) is None
    # mixed valid + invalid
    out = vp._content_parts_to_chat([{"type": "input_text", "text": "a"}, {"type": "input_image", "image_url": "data:image/png;base64,xxx"}, None])
    assert isinstance(out, list) and len(out) == 2

# ---------- 3. Go/Zen 重写 鲁莽 ----------

def t_go_zen_rewrite_fuzz():
    cases = [None, "", "mimo-v2.5", "mimo-v2.5-go", "mimo-v2.5-zen", "-go", "go", "mimo-v2.5-go-go", "ox-alpha-go", "ox-alpha", "X-PREVIEW-F-FREE-zen", "grok-4.6-go", "deepseek-v4-flash-go", "123", "   mimo-v2.5-go  "]
    for m in cases:
        parsed = {"model": m}
        try:
            vp._rewrite_go_model(parsed)
            vp._rewrite_zen_model(parsed)
        except Exception as e:
            assert False, f"rewrite crash on {m!r}: {e}"
        assert isinstance(parsed["model"], (str, type(None)))

def t_go_alias_correctness():
    p = {"model": "ox-alpha-go"}
    vp._rewrite_go_model(p)
    assert p["model"] == "ox-alpha-free", p
    p = {"model": "ox-alpha-zen"}
    vp._rewrite_zen_model(p)
    # Zen alias ox-alpha -> x-preview-f-free
    assert p["model"] == "x-preview-f-free", p

# ---------- 4. _parse_chat_stream_chunks 鲁莽 ----------

def t_parse_stream_malformed():
    # empty, no data, only [DONE], truncated json, invalid base64
    for raw in [
        b"",
        b"data: [DONE]\n\n",
        b"data: not-json\n\n",
        b"data: {\"choices\": [{\"delta\": {\"content\": null}}]}\n\n",
        b"data: {\"choices\": [{\"delta\": {\"content\": 123}}]}\n\n",
        b": comment\n\n",
        b"event: delta\ndata: {\"choices\":[]}\n\n",
        b"data: {\"choices\": [{\"delta\": {\"tool_calls\": [{\"index\": \"not-int\"}]}}]}\n\n",
        b"data: {\"usage\": {\"prompt_tokens\": 1}}\n\n",
    ]:
        text, calls, reason, usage = vp._parse_chat_stream_chunks(raw)
        assert isinstance(text, str)
        assert isinstance(calls, list)

def t_parse_stream_huge():
    # 1k chunks
    parts = []
    for _ in range(1000):
        parts.append(b'data: {"choices": [{"delta": {"content": "a"}}]}\n\n')
    raw = b"".join(parts) + b'data: {"choices": [{"finish_reason": "stop"}]}\n\n'
    text, calls, reason, usage = vp._parse_chat_stream_chunks(raw)
    assert len(text) == 1000

# ---------- 5. _sanitize / _repair 混沌 ----------

def t_sanitize_fuzz():
    cases = [
        '', '   ', 'not json', '{"a":1', '{"a":1,}', 'cmd":"pwd"}', '{"cmd":"pwd"}', '{"a":1, "b":2}', '[]', '123', 'null',
        '{"cmd": "echo \\"hi\\""}', '{"a": "b", "c":}',
        _rand_str(500), '{"' + _rand_str(100) + '}',
    ]
    for s in cases:
        out = vp._sanitize_fc_args(s)
        assert isinstance(out, str)
        # if it returns something, attempt to see it doesn't crash on json.loads downstream
        try:
            json.loads(out)
        except:
            pass
        # repair should not crash
        rep = vp._repair_json_object_args(s)
        assert isinstance(rep, str)

def t_repair_edge():
    assert vp._repair_json_object_args('cmd":"pwd"}') == '{"cmd":"pwd"}'
    assert vp._repair_json_object_args('{"a":1}') == '{"a":1}'
    assert vp._repair_json_object_args('') == ''
    assert vp._repair_json_object_args(None) is None or isinstance(vp._repair_json_object_args(None), str)

# ---------- 6. Translator 混沌 ----------

def t_translator_order_chaos():
    tr = vp.ChatBridgeTranslator("mimo-v2.5-go", byte_budget=1024*1024)
    tr.on_created()
    # random interleaving of content, reasoning, tool calls
    for _ in range(100):
        r = random.random()
        if r < 0.4:
            tr.on_content_delta(_rand_str(5))
        elif r < 0.6:
            tr.on_reasoning_delta(_rand_str(5))
        elif r < 0.8:
            idx = random.randint(0,3)
            tr.on_tool_delta(idx, f"call_{idx}_{_rand_str(2)}", "shell", _rand_str(10))
        else:
            # empty
            tr.on_content_delta("")
            tr.on_reasoning_delta("")
    tail = tr.on_finish("stop", {"prompt_tokens": 1, "completion_tokens": 1})
    assert b"response.completed" in tail

def t_translator_budget_panic():
    tr = vp.ChatBridgeTranslator("glm-5.3-go", byte_budget=10)  # tiny
    tr.on_created()
    out = b""
    for _ in range(5):
        chunk = tr.on_content_delta("x"*20)
        if chunk:
            out += chunk
        if tr.finished:
            break
    assert tr.truncated or tr.finished
    # on_finish is idempotent, so check combined buffer contains terminal
    tail = tr.on_finish("stop", None)
    combined = out + tail
    assert b"incomplete" in combined or b"completed" in combined

def t_translator_duplicate_tool_index():
    tr = vp.ChatBridgeTranslator("mimo-v2.5")
    tr.on_created()
    tr.on_tool_delta(0, "call_1", "shell", '{"a":')
    tr.on_tool_delta(0, None, None, '1}')
    tr.on_tool_delta(0, "call_1_dup", "shell2", '{"b":2}')  # same index, different name should be ignored second name
    tail = tr.on_finish("tool_calls", None)
    assert b"function_call" in tail

def t_translator_on_chat_frame_malformed():
    tr = vp.ChatBridgeTranslator("mimo-v2.5")
    tr.on_created()
    malformed_frames = [
        b"not a sse frame",
        b"data: not-json\n\n",
        b"data: {\"choices\": null}\n\n",
        b"data: {\"choices\": [{\"delta\": null}]}\n\n",
        b"data: {\"choices\": [{\"delta\": {\"content\": [123]}}]}\n\n",
        b"data: {\"choices\": [{\"delta\": {\"tool_calls\": \"not-a-list\"}}]}\n\n",
        b"data: [DONE]\n\n",
        b"",
    ]
    for f in malformed_frames:
        out = tr.on_chat_frame(f)
        assert isinstance(out, bytes)
    tail = tr.on_finish(None, None)
    assert b"response.completed" in tail

def t_translator_tool_broken_args():
    tr = vp.ChatBridgeTranslator("ox-alpha-free")
    tr.on_created()
    # feed broken JSON args like installer historically produced
    tr.on_tool_delta(0, "c1", "shell", 'cmd":"pwd"}')
    tail = tr.on_finish("tool_calls", None)
    assert b"cmd" in tail

# ---------- 7. synthetic web_search 注入 鲁莽 ----------
# 2026-09-05: t_strip_web_search_fuzz 退役（_strip 已删）；同等输入矩阵改测注入函数不断言崩溃

def t_synthetic_web_search_fuzz():
    for model in [None, "", "mimo-v2.5", "deepseek-v4-flash", "gpt-5.6-luna", "muse-spark-1.2", "omen-alpha", "unknown-model", "ox-alpha-free"]:
        for tools in [None, [], [{"type": "web_search"}], [{"type": "function", "name": "a"}], [{"type": "web_search"}, {"type": "function", "name": "b"}], "not-a-list"]:
            parsed = {"model": model, "tools": tools}
            orig_has_ws = isinstance(tools, list) and any(isinstance(t, dict) and t.get("type") == "web_search" for t in tools)
            # go_route random
            try:
                vp._inject_synthetic_web_search(parsed, model, go_route=random.choice([True, False]))
            except Exception as e:
                assert False, f"synth crash {model} {tools}: {e}"
            # 不变量：原生模型的 web_search 不应被替换（仅当 tools 本来就是 list 才断言）
            if orig_has_ws and model in ("deepseek-v4-flash", "gpt-5.6-luna", "muse-spark-1.2"):
                assert {"type": "web_search"} in (parsed.get("tools") or []), f"native stripped {model}"

def t_normalize_web_search_call_fuzz():
    cases = [
        {"input": None},
        {"input": []},
        {"input": [{"type": "web_search_call", "action": None}]},
        {"input": [{"type": "web_search_call", "action": {"type": "web_search", "queries": None}}]},
        {"input": [{"type": "web_search_call", "action": {"type": "search", "query": ""}}]},
        {"input": [{"type": "web_search_call", "action": {"type": "unknown", "query": "hi"}}]},
        {"input": [{"type": "web_search_call", "search_query": "hello"}]},
        {"input": [{"type": "message", "role": "user", "content": []}]},
    ]
    for p in cases:
        out = vp._normalize_web_search_call(p)
        assert isinstance(out, bool)

def t_sanitize_input_ids_fuzz():
    # rs_ with colon should be dropped
    parsed = {"input": [
        {"type": "message", "id": "rs_abc:rs_def", "role": "user"},
        {"type": "message", "id": "msg_123", "role": "user"},
        {"type": "message", "id": "rs_single", "role": "user"},
        None, "string",
    ]}
    vp._sanitize_input_ids(parsed)
    # should have dropped 2 (colon and rs_)
    assert len(parsed["input"]) == 2 or len(parsed["input"]) <= 3

# 2026-09-23：t_intercept_unsupported_history_fuzz 退役（400 拦截已删，改翻译）。
# 下面这批测试锁的是新行为：历史里的 web_search_call 必须被翻成工具调用 + 诚实占位结果。

def t_web_search_query_of_fallback():
    assert vp.web_search_query_of({"action": {"queries": ["q1", "q2"]}}) == "q1"
    assert vp.web_search_query_of({"action": {"queries": []}, "search_query": "sq"}) == "sq"
    assert vp.web_search_query_of({"action": {"query": "aq"}}) == "aq"
    assert vp.web_search_query_of({"action": {"type": "search"}}) == "search"
    assert vp.web_search_query_of({"action": None}) == "search"
    assert vp.web_search_query_of({}) == "search"
    assert vp.web_search_query_of(None) == "search"
    assert vp.web_search_query_of({"action": {"queries": [None, "ok"]}}) == "ok"
    # 空白串不算查询词，继续往后兜底
    assert vp.web_search_query_of({"action": {"queries": ["   "], "query": "q"}}) == "q"
    assert vp.web_search_query_of({"action": {"queries": "not-a-list"}, "search_query": " s "}) == " s "

def t_web_search_call_id_fallback():
    assert vp.web_search_call_id({"id": "ws_1", "call_id": "ws_x"}) == "ws_1"
    assert vp.web_search_call_id({"call_id": "ws_x"}) == "ws_x"
    assert vp.web_search_call_id({"id": ""}).startswith("call_ws_")
    assert vp.web_search_call_id(None).startswith("call_ws_")

def t_web_search_history_chat_bridge():
    req = {"model": "mimo-v2.6-flash-go", "stream": False, "input": [
        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "换壳教程"}]},
        {"type": "reasoning", "id": "rs_1", "summary": []},
        {"type": "web_search_call", "id": "ws_1", "status": "completed",
         "action": {"type": "search", "query": "iPhone 12 mini 换壳", "queries": ["iPhone 12 mini 换壳"]}},
        {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "答案"}]},
    ], "tools": [{"type": "function", "name": "shell", "parameters": {"type": "object", "properties": {}}}]}
    out = vp._responses_request_to_chat(req)
    msgs = out["messages"]
    assert msgs[0]["role"] == "user"
    call_msg = msgs[1]
    assert call_msg["role"] == "assistant" and call_msg["content"] is None
    call = call_msg["tool_calls"][0]
    assert call["id"] == "ws_1" and call["type"] == "function"
    assert call["function"]["name"] == "web_search"
    assert json.loads(call["function"]["arguments"]) == {"query": "iPhone 12 mini 换壳"}
    tool_msg = msgs[2]
    assert tool_msg["role"] == "tool" and tool_msg["tool_call_id"] == "ws_1"
    assert "iPhone 12 mini 换壳" in tool_msg["content"] and "结果未保留" in tool_msg["content"]
    # 回放过搜索调用就必须有对应工具声明（否则上游认为调用了未声明的工具）
    names = [t["function"]["name"] for t in out["tools"]]
    assert names.count("web_search") == 1, names
    # 幂等：已经声明过就不重复
    req2 = dict(req, tools=[{"type": "function", "name": "web_search",
                             "parameters": {"type": "object", "properties": {}}}])
    out2 = vp._responses_request_to_chat(req2)
    assert [t["function"]["name"] for t in out2["tools"]].count("web_search") == 1

def t_web_search_history_chat_consecutive():
    # 连续两条搜索 → 一条 assistant 带 2 个 tool_calls + 紧随两条 tool 结果
    items = [
        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "go"}]},
        {"type": "web_search_call", "id": "ws_1", "action": {"type": "search", "queries": ["a"]}},
        {"type": "web_search_call", "id": "ws_2", "action": {"type": "search", "queries": ["b"]}},
        {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "ok"}]},
    ]
    out = vp._responses_request_to_chat({"model": "mimo-v2.5", "input": items})
    msgs = out["messages"]
    assert len(msgs) == 5, msgs
    assert [c["id"] for c in msgs[1]["tool_calls"]] == ["ws_1", "ws_2"]
    assert [m["tool_call_id"] for m in msgs[2:4]] == ["ws_1", "ws_2"]
    assert msgs[4] == {"role": "assistant", "content": "ok"}
    # 搜索连击不能吞掉后面的 function_call（两种 call 各自成格）
    items.append({"type": "function_call", "call_id": "fc_1", "name": "shell", "arguments": '{"a":1}'})
    msgs2 = vp._responses_request_to_chat({"model": "mimo-v2.5", "input": items})["messages"]
    assert msgs2[-1]["tool_calls"][0]["id"] == "fc_1"

def t_web_search_history_messages_bridge():
    req = {"model": "union-alpha", "stream": False, "input": [
        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "q"}]},
        {"type": "web_search_call", "id": "ws_1", "action": {"type": "search", "queries": ["hello"]}},
        {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "答案"}]},
    ]}
    out = vp._responses_request_to_messages(req)
    msgs = out["messages"]
    assert msgs[0]["role"] == "user"
    tool_use = msgs[1]["content"][0]
    assert tool_use["type"] == "tool_use" and tool_use["name"] == "web_search"
    assert tool_use["id"] == "ws_1" and tool_use["input"] == {"query": "hello"}
    tool_result = msgs[2]["content"][0]
    assert tool_result["type"] == "tool_result" and tool_result["tool_use_id"] == "ws_1"
    assert "hello" in tool_result["content"]
    assert [t["name"] for t in out["tools"]] == ["web_search"]
    assert "input_schema" in out["tools"][0]

def t_history_replay_stats_reasoning():
    # reasoning 仍不回放，但必须计数（以前是静默丢弃）
    items = [
        {"type": "reasoning", "id": "rs_1", "summary": []},
        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hi"}]},
        {"type": "reasoning", "id": "rs_2", "summary": []},
    ]
    msgs, stats = vp._bridges_chat._translate_history(items)
    assert stats["dropped_reasoning"] == 2 and stats["web_search_replayed"] == 0
    assert len(msgs) == 1 and msgs[0]["role"] == "user"
    msgs2, stats2 = vp._bridges_messages._translate_history(items, [])
    assert stats2["dropped_reasoning"] == 2 and len(msgs2) == 1

def t_web_search_history_fuzz():
    for _ in range(100):
        items = []
        for _ in range(random.randint(1, 8)):
            kind = random.choice(["message", "web_search_call", "reasoning", "function_call",
                                  "function_call_output", "unknown_xyz"])
            if kind == "message":
                items.append({"type": "message", "role": random.choice(["user", "assistant", "developer"]),
                              "content": [{"type": "input_text", "text": _rand_str(8)}]})
            elif kind == "web_search_call":
                items.append({"type": "web_search_call",
                              "action": random.choice([None, {"type": "search", "queries": ["a"]},
                                                       {"type": "search", "query": "b"},
                                                       {"type": "search", "queries": []}])})
            else:
                items.append({"type": kind})
        req = {"model": random.choice(["mimo-v2.6-flash-go", "glm-5.3-go", "union-alpha", None]),
               "input": items, "tools": random.choice([None, [], [{"type": "function", "name": "shell"}]]), }
        try:
            chat = vp._responses_request_to_chat(req)
            _msgs, stats = vp._bridges_chat._translate_history(items)
            _msgs2, stats2 = vp._bridges_messages._translate_history(items, [])
        except Exception as e:
            assert False, f"history translation crash {items}: {e}"
        assert isinstance(chat["messages"], list)
        assert stats["web_search_replayed"] == stats2["web_search_replayed"]
        assert stats["dropped_reasoning"] == stats2["dropped_reasoning"]

def t_history_interception_removed():
    # 回归锁：旧的 400「换会话」拦截已删（历史里有 web_search_call 不再被拦）
    assert not hasattr(vp, "_intercept_unsupported_history")
    assert not hasattr(vp, "_SEARCH_TRUE_PREFIXES")
    for name in ("pipeline.py", "toolfix.py", "config.py"):
        src = open(os.path.join(ROOT, "proxy", name), encoding="utf-8").read()
        assert "Cross-model history blocked" not in src, f"{name} 还留着 400 文案"

def t_fix_tool_required_fuzz():
    cases = [
        {"tools": None},
        {"tools": []},
        {"tools": [{"type": "function", "name": "a", "parameters": {"type": "object", "properties": {"limit": {"type": "integer"}}}}]},
        {"tools": [{"type": "function", "function": {"name": "b", "parameters": {"type": "object", "properties": {"a": {}, "b": {}}, "required": ["a"]}}}]},
        {"tools": [{"type": "function", "function": {"name": "c", "parameters": {"type": "object", "properties": {}}}}]},
        {"tools": [{"type": "function", "parameters": "not-a-dict"}]},
        {"tools": "not-a-list"},
    ]
    for p in cases:
        try:
            vp._fix_tool_required(p)
        except Exception as e:
            assert False, f"fix_tool_required crash {p}: {e}"

def t_normalize_assistant_collapse_fuzz():
    parsed = {"input": [
        {"role": "assistant", "content": [{"text": "a"}, {"text": "b"}]},
        {"role": "assistant", "content": "already string"},
        {"role": "user", "content": [{"type": "input_text", "text": "hi"}]},
        None,
    ]}
    vp._normalize_assistant_content(parsed)
    # first item should now be string
    assert isinstance(parsed["input"][0]["content"], str)

# ---------- 8. reasoning registry 混沌 ----------

def t_reasoning_registry_missing():
    # temporarily move file if exists
    p = vp._REASONING_REGISTRY_PATH
    exist = os.path.exists(p)
    bak = p + ".bak.robust"
    if exist:
        os.rename(p, bak)
    try:
        # should not crash, fallback to ["high"]
        out = vp._clamp_reasoning_effort("mimo-v2.5-go", "high")
        assert out in ("high", "low", "max", None)
        out2 = vp._clamp_reasoning_effort("unknown-model", "ultra")
        assert isinstance(out2, (str, type(None)))
    finally:
        if exist:
            os.rename(bak, p)

def t_reasoning_clamp_random():
    for _ in range(100):
        model = random.choice(["mimo-v2.5-go", "glm-5.3-go", "grok-4.6-go", "unknown-xyz", "", None])
        effort = random.choice(["low", "medium", "high", "xhigh", "max", "minimal", "ultra", "none", "", "weird", None, 123])
        try:
            out = vp._clamp_reasoning_effort(model, effort)
            # raw int effort is returned as-is (early return)
            assert isinstance(out, (str, type(None), int))
        except Exception as e:
            assert False, f"clamp crash {model} {effort}: {e}"

# ---------- 9. _build_ fallbacks 大数据 ----------

def t_build_events_huge_text():
    # 5MB text should be handled (16MB budget)
    big = "a"* (5*1024*1024)
    obj = {"choices": [{"message": {"role": "assistant", "content": big}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 1, "completion_tokens": 1}}
    out = vp._build_chat_fallback_json("mimo-v2.5", obj)
    assert out["status"] == "completed"

def t_build_events_many_tools():
    calls = [{"id": f"c{i}", "type": "function", "function": {"name": f"tool{i}", "arguments": '{"x":1}'}} for i in range(50)]
    obj = {"choices": [{"message": {"role": "assistant", "content": "", "tool_calls": calls}, "finish_reason": "tool_calls"}], "usage": {}}
    out = vp._build_chat_fallback_json("glm-5.3", obj)
    assert len(out["output"]) == 50

# ---------- 10. Header helpers 边界 ----------

def t_header_value_fuzz():
    headers = [("Content-Type", "application/json"), ("X-Custom", "value"), ("content-type", "lower")]
    assert vp._header_value(headers, "content-type") is not None
    assert vp._header_value([], "anything") is None
    assert vp._header_value([("a","1")], "b") is None
    # case insensitive
    assert vp._header_value([("Authorization", "Bearer xxx")], "authorization") == "Bearer xxx"

# ---------- runner ----------
for name, fn in list(globals().items()):
    if name.startswith("t_"):
        check(name, fn)

print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
if FAIL:
    for n, e in FAIL:
        print(f"  !! {n}: {e}")
    sys.exit(1)
