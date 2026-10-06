"""SSE 引擎的字节级基线测试（2026-09-23 转换层收敛 Phase ③ 的护栏）。

`tests/fixtures/sse_golden.json` 是**重构前**把固定用例喂进 `_complete_sse_frame` +
`_rewrite_sse_frame` 记录下来的逐帧输出。重构之后再跑一遍，必须**一字不差** ——
这就是"没被阶段认领的帧原样字节转发"那条不可变约束的可执行版本。

要故意改行为，就得同时改 baseline（并在 CHANGELOG 说明）。
Run: python3 tests/test_sse_golden.py
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

from proxy.sse import _complete_sse_frame, _rewrite_sse_frame  # noqa: E402

GOLDEN_PATH = os.path.join(HERE, "fixtures", "sse_golden.json")

PASS, FAIL = [], []


def check(name, fn):
    try:
        fn()
        PASS.append(name)
        print(f"  PASS {name}")
    except Exception as exc:  # noqa: BLE001
        FAIL.append((name, repr(exc)))
        print(f"  FAIL {name}: {exc!r}")


CASES = {
    "deepseek_native": [
        {"type": "response.created", "response": {"id": "r1", "status": "in_progress", "model": "deepseek-v4.1-flash"}},
        {"type": "response.in_progress", "response": {"id": "r1"}},
        {"type": "response.output_item.added", "output_index": 0,
         "item": {"id": "msg_1", "type": "message", "status": "in_progress", "role": "assistant", "content": []}},
        {"type": "response.content_part.added", "item_id": "msg_1", "output_index": 0, "content_index": 0,
         "part": {"type": "output_text", "text": ""}},
        {"type": "response.output_text.delta", "item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": "你好"},
        {"type": "response.output_text.delta", "item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": "，世界"},
        {"type": "response.output_text.done", "item_id": "msg_1", "output_index": 0, "content_index": 0, "text": "你好，世界"},
        {"type": "response.output_item.done", "output_index": 0,
         "item": {"id": "msg_1", "type": "message", "status": "completed", "role": "assistant",
                  "content": [{"type": "output_text", "text": "你好，世界"}]}},
        {"type": "response.completed", "response": {"id": "r1", "status": "completed", "output": []}},
    ],
    "muse_namespaced_tool": [
        {"type": "response.created", "response": {"id": "r2", "status": "in_progress",
                                                  "model": "muse-spark-1.3-contributor"}},
        {"type": "response.output_item.added", "output_index": 0,
         "item": {"id": "fc_1", "type": "function_call", "status": "in_progress", "name": "shell:exec",
                  "call_id": "c1", "arguments": ""}},
        {"type": "response.output_item.done", "output_index": 0,
         "item": {"id": "fc_1", "type": "function_call", "status": "completed", "name": "shell:exec",
                  "call_id": "c1", "arguments": "{}"}},
        {"type": "response.completed", "response": {"id": "r2", "status": "completed",
                                                    "output": [{"id": "fc_1", "type": "function_call",
                                                                "name": "shell:exec", "call_id": "c1",
                                                                "arguments": "{}"}]}},
    ],
    "apply_patch_stream": [
        {"type": "response.created", "response": {"id": "r3", "status": "in_progress", "model": "deepseek-v4.1-flash"}},
        {"type": "response.output_item.added", "output_index": 0,
         "item": {"id": "fc_p", "type": "function_call", "status": "in_progress", "name": "apply_patch",
                  "call_id": "cp", "arguments": ""}},
        {"type": "response.function_call_arguments.delta", "item_id": "fc_p", "output_index": 0,
         "delta": "*** Begin Patch\n*** Update File: a.txt\n"},
        {"type": "response.function_call_arguments.delta", "item_id": "fc_p", "output_index": 0,
         "delta": "@@\n-old\n+new\n*** End Patch\n"},
        {"type": "response.function_call_arguments.done", "item_id": "fc_p", "output_index": 0,
         "arguments": "*** Begin Patch\n*** Update File: a.txt\n@@\n-old\n+new\n*** End Patch\n"},
        {"type": "response.output_item.done", "output_index": 0,
         "item": {"id": "fc_p", "type": "function_call", "status": "completed", "name": "apply_patch",
                  "call_id": "cp", "arguments": "*** Begin Patch\n*** End Patch\n"}},
        {"type": "response.completed", "response": {"id": "r3", "status": "completed", "output": []}},
    ],
    "no_terminal_frames": [
        {"type": "response.created", "response": {"id": "r4", "status": "in_progress",
                                                  "model": "muse-spark-1.3-contributor"}},
        {"type": "response.output_item.added", "output_index": 0,
         "item": {"id": "msg_4", "type": "message", "status": "in_progress", "role": "assistant", "content": []}},
        {"type": "response.output_item.done", "output_index": 0,
         "item": {"id": "msg_4", "type": "message", "status": "completed", "role": "assistant",
                  "content": [{"type": "output_text", "text": "好了"}]}},
    ],
    "junk_and_unknown": [
        b'event: ping\ndata: {"type": "response.something.new", "x": 1}\n\n',
        b"data: not-json\n\n",
        b"\n\n",
        b": comment only\n\n",
    ],
    "dup_item_ids": [
        {"type": "response.output_item.added", "output_index": 0,
         "item": {"id": "dup", "type": "message", "status": "in_progress", "content": []}},
        {"type": "response.output_item.added", "output_index": 0,
         "item": {"id": "dup", "type": "message", "status": "in_progress", "content": []}},
        {"type": "response.output_item.done", "output_index": 0,
         "item": {"id": "dup", "type": "message", "status": "completed",
                  "content": [{"type": "output_text", "text": "x"}]}},
    ],
}


def _frame_bytes(case_frame):
    if isinstance(case_frame, bytes):
        return case_frame
    return ("data: " + json.dumps(case_frame, ensure_ascii=False) + "\n\n").encode("utf-8")


def _run_case(frames):
    state = {"pending": {}, "completed": False, "compat": {"model": "muse-spark-1.3-contributor"}}
    out = []
    for case_frame in frames:
        for compat in _complete_sse_frame(_frame_bytes(case_frame), state):
            for final in _rewrite_sse_frame(compat, state):
                out.append(final.decode("utf-8", "replace"))
    return {"frames": out,
            "state": {k: sorted(v) if isinstance(v, set) else v
                      for k, v in state.items() if k != "compat"}}


def t_sse_output_matches_pre_refactor_baseline():
    golden = json.load(open(GOLDEN_PATH, encoding="utf-8"))
    for name, expected in golden.items():
        actual = _run_case(CASES[name])
        assert actual["frames"] == expected["frames"], f"{name}: 逐帧输出变了"
        assert actual["state"] == expected["state"], f"{name}: 状态机结果变了 {actual['state']} ≠ {expected['state']}"


def t_unknown_frames_pass_through_byte_identical():
    """不可变约束：没被阶段认领的帧必须原样字节转发"""
    for raw in CASES["junk_and_unknown"]:
        state = {"pending": {}, "completed": False, "compat": {}}
        out = []
        for compat in _complete_sse_frame(raw, state):
            out.extend(_rewrite_sse_frame(compat, state))
        assert out == [raw], f"帧被改动了：{raw!r} → {out!r}"


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("t_"):
            check(name, fn)
    print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
    sys.exit(1 if FAIL else 0)
