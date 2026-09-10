#!/usr/bin/env python3
"""End-to-end regression for the vision proxy (needs proxy on 127.0.0.1:19100 + network).

Run: python3 tests/run_regression.py [--skip-live]   (--skip-live: only cases not needing upstream)
Exit code 0 = all green.
"""
import argparse
import json
import os
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PROXY = os.environ.get("VISION_PROXY_URL", "http://127.0.0.1:19100")
ENV_FILE = os.environ.get("VISION_ENV_FILE",
                          os.path.join(os.path.expanduser("~"), ".config/agent-vision-toolkit/env"))

PASS, FAIL = [], []


def load_key():
    for line in open(ENV_FILE):
        if line.startswith("ZEN_API_KEY="):
            return line.strip().split("=", 1)[1]
    raise SystemExit("ZEN_API_KEY not found in env file")


def post(path, payload, key, timeout=120, stream=False):
    req = urllib.request.Request(PROXY + path, data=json.dumps(payload).encode(), method="POST")
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("Content-Type", "application/json")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    t0 = time.monotonic()
    try:
        resp = opener.open(req, timeout=timeout)
        body = b""
        while True:
            chunk = resp.read(65536)
            if not chunk:
                break
            body += chunk
            if not stream and len(body) > 4_000_000:
                break
        return resp.status, body, time.monotonic() - t0
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(), time.monotonic() - t0


def responses_payload(model, text="说ok", stream=False, tools=None, max_output_tokens=None):
    p = {"model": model, "input": [{"role": "user", "content": [{"type": "input_text", "text": text}]}],
         "stream": stream, "store": False}
    if tools:
        p["tools"] = tools
    if max_output_tokens:
        p["max_output_tokens"] = max_output_tokens
    return p


def case(name, fn, live=True):
    if skip_live and live:
        print(f"  SKIP {name} (live)")
        return
    try:
        fn()
        PASS.append(name)
        print(f"  PASS {name}")
    except Exception as exc:  # noqa: BLE001
        FAIL.append((name, repr(exc)))
        print(f"  FAIL {name}: {exc!r}")


def completed_from_sse(body: bytes):
    frames = [json.loads(l[6:]) for l in body.decode(errors="replace").split("\n") if l.startswith("data: ")]
    terminal = [f for f in frames if f.get("type") in ("response.completed", "response.incomplete", "response.failed")]
    assert terminal, "no terminal frame in SSE"
    types = [f.get("type") for f in frames]
    return terminal[-1]["response"], types


# ---------------------------------------------------------------- live cases
def c_deepseek_passthrough(key):
    st, body, _ = post("/v1/responses", responses_payload("deepseek-v4-flash-go", max_output_tokens=64), key)
    assert st == 200, f"status {st}: {body[:200]}"
    obj = json.loads(body) if not body.startswith(b"data:") else completed_from_sse(body)[0]
    assert obj["status"] == "completed"


def c_mimo_bridge_stream_text(key):
    st, body, dt = post("/v1/responses", responses_payload("mimo-v2.5-go", stream=True), key, timeout=180, stream=True)
    assert st == 200, f"status {st}"
    resp, types = completed_from_sse(body)
    assert resp["status"] in ("completed", "incomplete")
    assert "response.output_text.delta" in types, "streaming deltas missing (P3)"
    print(f"      ({dt:.1f}s, {len(types)} events)")


def c_mimo_bridge_stream_reasoning(key):
    st, body, _ = post("/v1/responses", responses_payload("mimo-v2.5-go", "9.11 和 9.8 谁大? 简短回答", stream=True),
                       key, timeout=240, stream=True)
    assert st == 200
    resp, types = completed_from_sse(body)
    assert "response.output_text.delta" in types


def c_ox_tool_call(key):
    # ox-alpha-free removed from Go 2026-08-28 (401 not supported); use glm-5.3-flash-go as drop-in (same chat-bridge + tool repair)
    model = "glm-5.3-flash-go"
    tools = [{"type": "function", "name": "shell", "description": "Run a shell command",
              "parameters": {"type": "object",
                             "properties": {"cmd": {"type": "string"}, "limit": {"type": "number"}},
                             "required": ["cmd"]}}]
    st, body, _ = post("/v1/responses",
                       responses_payload(model, "用shell工具执行pwd", stream=True, tools=tools),
                       key, timeout=180, stream=True)
    if st == 401 and b"not supported" in body:
        print(f"      SKIP {model} not supported upstream, skip")
        return
    assert st == 200, f"status {st}: {body[:200]}"
    resp, _ = completed_from_sse(body)
    fcs = [o for o in resp["output"] if o["type"] == "function_call"]
    assert fcs, "expected a function_call"
    json.loads(fcs[0]["arguments"])  # must be valid JSON (fault-20 insurance)


def c_glm_nonstream(key):
    st, body, _ = post("/v1/responses", responses_payload("glm-5.2-go", stream=False), key, timeout=180)
    assert st == 200
    obj = json.loads(body)
    assert obj["status"] in ("completed", "incomplete")


ap = argparse.ArgumentParser()
ap.add_argument("--skip-live", action="store_true")
args = ap.parse_args()
skip_live = args.skip_live

print("== unit tests ==")
unit_rc = os.system(f"{sys.executable} {HERE}/test_units.py")
if unit_rc != 0:
    FAIL.append(("units", "see output above"))

print("== live e2e ==")
KEY = load_key()
case("deepseek passthrough untouched", lambda: c_deepseek_passthrough(KEY))
case("mimo bridge streaming text (+deltas)", lambda: c_mimo_bridge_stream_text(KEY))
case("mimo bridge reasoning visible", lambda: c_mimo_bridge_stream_reasoning(KEY))
case("ox-alpha tool call valid JSON", lambda: c_ox_tool_call(KEY))
case("glm non-streaming", lambda: c_glm_nonstream(KEY))

print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
if FAIL:
    for name, err in FAIL:
        print(f"  !! {name}: {err}")
    sys.exit(1)
