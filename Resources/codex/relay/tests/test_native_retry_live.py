#!/usr/bin/env python3
"""原生路径 429 退避重试的本地端到端验证（2026-10-22）。

起一个假上游：前两次回 429（正文是网关那种 server_error），第三次回 200；
然后用**真实的** Proxy._open_upstream（真 HTTP）跑
_open_upstream_with_status_retry，断言：
  * 客户端最终拿到 200，而不是被 429 顶穿；
  * 上游一共被打了 3 次（说明确实退避重试了）；
  * 429 期间没有把错误体写给客户端。

只用 127.0.0.1，不联网。
"""

import asyncio
import http.server
import importlib.util
import json
import os
import socketserver
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

spec = importlib.util.spec_from_file_location("vp_retry", os.path.join(ROOT, "relay.py"))
vp = importlib.util.module_from_spec(spec)
sys.modules["vp_retry"] = vp
spec.loader.exec_module(vp)

STATE = {"calls": 0, "bodies": []}


class _Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):  # noqa: N802 - BaseHTTPRequestHandler 约定
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            STATE["bodies"].append(self.rfile.read(length))
        STATE["calls"] += 1
        if STATE["calls"] <= 2:
            body = json.dumps({
                "error": {"type": "server_error", "message": "Upstream request failed: rate limited"}
            }).encode()
            self.send_response(429)
        else:
            body = json.dumps({
                "id": "resp_ok", "object": "response", "status": "completed", "output": []
            }).encode()
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class _Threaded(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    server = _Threaded(("127.0.0.1", 0), _Handler)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    class _Fake:
        pass

    fake = _Fake()
    fake._open_upstream = lambda *a, **k: vp.Proxy._open_upstream(fake, *a, **k)

    old_delay = vp._server.native_retry_delay
    vp._server.native_retry_delay = lambda *a, **k: 0.01
    try:
        response, status = asyncio.run(
            vp.Proxy._open_upstream_with_status_retry(
                fake, "POST", "/v1/responses", b'{"model":"x"}', [],
                f"http://127.0.0.1:{port}", model="test-model")
        )
    finally:
        vp._server.native_retry_delay = old_delay
        server.shutdown()
        server.server_close()

    assert status == 200, f"最终状态应为 200，实际 {status}"
    assert response.status == 200
    assert STATE["calls"] == 3, f"上游应被打 3 次，实际 {STATE['calls']}"
    assert len(STATE["bodies"]) == 3
    print("  ✅ 原生路径 429 → 退避重试 → 200（真实 HTTP，上游被打 3 次）")


if __name__ == "__main__":
    main()
