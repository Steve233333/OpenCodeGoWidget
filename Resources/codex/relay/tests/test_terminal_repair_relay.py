"""终止事件修补的**中继层**回归测试（2026-09-23）。

背景：muse-spark 在 OpenCode Go/Zen 的 Responses 模式下，长思考后可能
  (a) 内容发完但**不发终止帧**，或 (b) 直接**挂在连接上不再吐字节**。
以前 (a) 会被判 `response.failed`（这一轮算中断），(b) 会让 Codex 一直转圈。
现在对齐 opencodex 的 `modelResponsesTerminalRepair` 契约：内容已完整（开过的输出项都收到
`response.output_item.done`）就补 `response.completed` 收尾；不完整才判失败。

这个文件把「上游怎么发、代理怎么收尾」这一层也钉住 —— 单元测试只测了状态机判定，
真正的合成路径（含 SSE 头、帧重写、兼容层）在这里跑一遍。

Run: python3 tests/test_terminal_repair_relay.py
"""
import asyncio
import json
import os
import socket
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

from proxy.server import Proxy  # noqa: E402
from proxy.config import MUSE_MAX_STALL_RETRIES  # noqa: E402

PASS, FAIL = [], []


class FakeWriter:
    def __init__(self):
        self.buf = b""

    def write(self, data):
        self.buf += data

    async def drain(self):
        pass

    def is_closing(self):
        return False


class FakeUpstream:
    """假上游：先吐给定的 SSE 帧，然后按 mode 收尾。

    mode="close"  → 直接读到 EOF（上游关了连接，但没发终止帧）
    mode="idle"   → 先抛 socket.timeout（模拟"挂着不发"），再 EOF
    mode="failed" → 内容不完整就断（只有一个 output_item.added，没有 done）
    """

    def __init__(self, frames, mode="close"):
        self.chunks = [b"".join(frames), b""]
        self.mode = mode
        self._timed_out = False

    def read1(self, _n=65536):
        if self.mode == "idle" and not self._timed_out:
            self._timed_out = True
            raise socket.timeout("模拟上游挂着不发字节")
        return self.chunks.pop(0) if self.chunks else b""

    # 中继那句 `getattr(response, "read1", response.read)` 会**先**求值默认值，
    # 所以即便走 read1 也要有 read 这个属性（真 urllib 响应两个都有）
    read = read1


def frame(payload):
    return f"data: {json.dumps(payload)}\n\n".encode()


CREATED = frame({"type": "response.created", "response": {"id": "resp_test", "status": "in_progress"}})
ITEM_ADDED = frame({"type": "response.output_item.added", "output_index": 0,
                    "item": {"id": "msg_1", "type": "message", "status": "in_progress"}})
ITEM_DONE = frame({"type": "response.output_item.done", "output_index": 0,
                   "item": {"id": "msg_1", "type": "message", "status": "completed",
                            "content": [{"type": "output_text", "text": "做完了"}]}})


async def run_relay(mode, frames):
    proxy = Proxy(0, "https://api.deepseek.com", "/dev/null")
    writer = FakeWriter()
    upstream = FakeUpstream(frames, mode=mode)
    await proxy._send_response_sse(writer, upstream, 200,
                                  [("Content-Type", "text/event-stream")],
                                  retry=None, model="muse-spark-1.2-contributor")
    return writer.buf.decode("utf-8", errors="replace")


def check(name, fn):
    try:
        fn()
        PASS.append(name)
        print(f"  PASS {name}")
    except Exception as exc:  # noqa: BLE001
        FAIL.append((name, repr(exc)))
        print(f"  FAIL {name}: {exc!r}")


def t_closed_without_terminal_repairs_completed():
    out = asyncio.run(run_relay("close", [CREATED, ITEM_ADDED, ITEM_DONE]))
    assert '"type": "response.completed"' in out or '"type":"response.completed"' in out, out[-400:]
    assert "response.failed" not in out, "内容已完整时不该判失败"
    assert '"msg_1"' in out, "补的 completed 里要带上已经发过的 output 项"


def t_idle_upstream_repairs_completed():
    """挂着不发字节、但内容已完整 → 空闲宽限到点就该收尾，而不是让客户端一直转圈"""
    out = asyncio.run(run_relay("idle", [CREATED, ITEM_ADDED, ITEM_DONE]))
    assert "response.completed" in out, out[-400:]
    assert "response.failed" not in out, out[-400:]


def t_partial_turn_still_fails():
    """内容不完整就断 → 保持老行为判失败（别把半截内容伪装成正常收尾）"""
    out = asyncio.run(run_relay("failed", [CREATED, ITEM_ADDED]))
    assert "response.failed" in out, out[-400:]


def t_real_terminal_is_forwarded_untouched():
    frames = [CREATED, ITEM_ADDED, ITEM_DONE,
              frame({"type": "response.completed",
                     "response": {"id": "resp_test", "status": "completed", "output": []}})]
    out = asyncio.run(run_relay("close", frames))
    assert out.count("response.completed") >= 1
    assert "response.failed" not in out


class SlowMuseUpstream:
    """模拟 muse：先发 reasoning，再发正文；每次 read 只给一块（用来验证"边流边转"）。"""

    def __init__(self, blocks):
        self.blocks = list(blocks)
        self.status = 200
        self.headers = {"Content-Type": "text/event-stream"}
        self.reads = 0

    def read(self, _n=-1):
        self.reads += 1
        return self.blocks.pop(0) if self.blocks else b""

    def close(self):
        pass


def _muse_frames(text, with_terminal=True):
    frames = [frame({"type": "response.created", "response": {"id": "r1"}}),
              frame({"type": "response.output_item.added", "output_index": 0,
                     "item": {"id": "msg_1", "type": "message", "status": "in_progress"}}),
              frame({"type": "response.output_text.delta", "item_id": "msg_1",
                     "output_index": 0, "delta": text})]
    if with_terminal:
        frames.append(frame({"type": "response.output_item.done", "output_index": 0,
                             "item": {"id": "msg_1", "type": "message", "status": "completed"}}))
        frames.append(frame({"type": "response.completed",
                             "response": {"id": "r1", "status": "completed"}}))
    return b"".join(frames)


def t_muse_long_answer_streams_without_waiting_for_the_whole_stream():
    """2026-09-23：muse 长回合以前要等整段读完才显示（客户端一直"正在思考"）。
    现在正文够长就立刻放行 —— 第一个 chunk 之后就应该有内容可读。"""
    long_text = "先说明一下：" + "这是正文。" * 60      # > 300 字
    up = SlowMuseUpstream([_muse_frames(long_text, with_terminal=False), b""])
    proxy = Proxy(0, "https://api.deepseek.com", "/dev/null")
    out = asyncio.run(proxy._guard_muse_stall(up, 200, [("Content-Type", "text/event-stream")], retry=None))
    resp, status, _headers = out
    first = resp.read(65536)
    assert b"response.output_text.delta" in first, "放行后第一个 read 就该拿到内容"
    assert b"response.created" in first


def t_muse_short_narration_still_gets_retried():
    """短叙述 + 没工具调用 + 已结束 = 经典空转 → 仍然要重发（别把老功能改没了）"""
    calls = {"n": 0}
    good = "这次真的干活了：" + "正文。" * 80      # 重发后拿到正常长回答

    async def retry(_attempt):
        calls["n"] += 1
        return SlowMuseUpstream([_muse_frames(good)])

    up = SlowMuseUpstream([_muse_frames("我先看看情况，然后马上开始。")])
    proxy = Proxy(0, "https://api.deepseek.com", "/dev/null")
    out = asyncio.run(proxy._guard_muse_stall(up, 200, [("Content-Type", "text/event-stream")], retry))
    assert calls["n"] == 1, f"重发一次就该拿到正常回答，实际重发 {calls['n']} 次"
    assert b"response.completed" in out[0].read(65536)


def t_muse_retry_gives_up_after_max_attempts():
    """一直空转也不能无限重发（上限 2 次），最后照样把内容交给客户端"""
    calls = {"n": 0}

    async def retry(_attempt):
        calls["n"] += 1
        return SlowMuseUpstream([_muse_frames("我马上开始，先说说计划。")])   # 带空转标记词

    up = SlowMuseUpstream([_muse_frames("我先看看情况，然后马上开始。")])
    proxy = Proxy(0, "https://api.deepseek.com", "/dev/null")
    out = asyncio.run(proxy._guard_muse_stall(up, 200, [("Content-Type", "text/event-stream")], retry))
    assert calls["n"] == MUSE_MAX_STALL_RETRIES, f"最多重发 {MUSE_MAX_STALL_RETRIES} 次，实际 {calls['n']}"
    assert b"response.output_text.delta" in out[0].read(1 << 20)


def t_muse_tool_call_releases_immediately():
    """一出现工具调用就放行（这才是正常干活的回合）"""
    frames = [frame({"type": "response.created", "response": {"id": "r1"}}),
              frame({"type": "response.output_item.added", "output_index": 0,
                     "item": {"id": "fc_1", "type": "function_call", "name": "shell",
                              "call_id": "c1", "arguments": ""}}),
              frame({"type": "response.output_item.done", "output_index": 0,
                     "item": {"id": "fc_1", "type": "function_call", "name": "shell",
                              "call_id": "c1", "arguments": "{}"}})]
    up = SlowMuseUpstream([b"".join(frames), b""])
    proxy = Proxy(0, "https://api.deepseek.com", "/dev/null")

    async def retry(_attempt):
        raise AssertionError("有工具调用就不该重发")

    resp, _status, _h = asyncio.run(
        proxy._guard_muse_stall(up, 200, [("Content-Type", "text/event-stream")], retry))
    assert b"function_call" in resp.read(65536)


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("t_"):
            check(name, fn)
    print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
    sys.exit(1 if FAIL else 0)
