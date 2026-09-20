#!/usr/bin/env python3
"""Probe an OpenAI-Responses-compatible endpoint for the tool-schema limits that break Muse.

Usage:
    python3 probe_muse_schema.py --base https://opencode.ai/zen/go --model muse-spark-1.3-contributor --key $ZEN_API_KEY
    python3 probe_muse_schema.py --base http://127.0.0.1:19100 --model muse-spark-1.3-contributor-go

Each probe sends one tiny request (a two-character prompt plus one tool) so re-measuring an
upstream limit costs almost nothing. Use this before writing a workaround, and again after the
gateway changes, because these limits are not documented anywhere.

Point it at the gateway directly. Against a proxy that already applies the compatibility
patches, every probe passes because the proxy rewrites the request before it leaves the machine —
that tells you the patches work, not that the limits are gone.
"""

import argparse
import json
import re
import sys
import uuid
import urllib.error
import urllib.request

CLIENT_UA = "muse-codex-probe/1.0"
SESSION_ID = "probe-session"


def layered(depth):
    """A schema with `depth` nested objects inside an array: the depth ladder for the cap probe."""
    node = {"type": "string"}
    for _ in range(depth):
        node = {"type": "object", "properties": {"child": node}, "required": ["child"],
                "additionalProperties": False}
    return {"type": "object", "properties": {"top": {"type": "array", "items": node}},
            "required": ["top"], "additionalProperties": False}


RECURSIVE = {
    "$defs": {"node": {"type": "object", "properties": {"child": {"$ref": "#/$defs/node"}}}},
    "type": "object",
    "properties": {"start": {"$ref": "#/$defs/node"}},
}

PLAIN = {"type": "object", "properties": {"value": {"type": "string"}},
         "required": ["value"], "additionalProperties": False}


def post(base, path, model, key, tool, timeout):
    payload = {"model": model, "instructions": "You are a helpful assistant.",
               "input": "只回答两个字：收到", "stream": False, "tools": [tool]}
    request = urllib.request.Request(
        base.rstrip("/") + path, data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            # 直连网关时这两项是硬要求：Cloudflare 会拦 python-urllib 的 UA（error 1010），
            # 而网关自 2026-09-17 起要求 x-opencode-session，缺了直接 400 MissingSessionID。
            "User-Agent": CLIENT_UA,
            "x-opencode-session": SESSION_ID,
        },
        method="POST")
    if key:
        request.add_header("Authorization", f"Bearer {key}")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(body)
        except Exception:
            parsed = None
        if isinstance(parsed, dict):
            error = parsed.get("error")
            # 注意：成功响应里也有 "error": null，不能靠子串判断
            return (False, str(error)[:180]) if error else (True, "ok")
        if "response.completed" in body or "response.created" in body:
            return True, "stream"
        return False, body[:180]
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(detail)
            message = str(parsed.get("error") or parsed)[:180]
        except Exception:
            message = detail[:180]
        return False, message
    except Exception as exc:  # noqa: BLE001
        return False, f"{type(exc).__name__}: {exc}"


def tool(parameters, strict=False, name="probe"):
    return {"type": "function", "name": name, "description": "probe", "strict": strict,
            "parameters": parameters}


def main():
    global SESSION_ID
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True, help="proxy or gateway base URL")
    parser.add_argument("--path", default="/v1/responses")
    parser.add_argument("--model", required=True)
    parser.add_argument("--key", default=None, help="only needed when talking to the gateway directly")
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args()
    SESSION_ID = str(uuid.uuid4())

    probes = [(f"depth {depth}", tool(layered(depth))) for depth in range(1, 11)]
    probes += [
        ("strict: false", tool(PLAIN, strict=False)),
        ("strict: true", tool(PLAIN, strict=True)),
        ("recursive $ref", tool(RECURSIVE)),
    ]

    print(f"endpoint {args.base.rstrip('/') + args.path}  model {args.model}\n")
    unexpected = 0
    outcomes = []
    for label, probe_tool in probes:
        ok, detail = post(args.base, args.path, args.model, args.key, probe_tool, args.timeout)
        outcomes.append(ok)
        status = "PASS" if ok else "FAIL"
        expected = (
            True if label.startswith("depth") and int(label.split()[1]) <= 8
            else False if label.startswith("depth")
            else True if label.startswith("strict")
            else False
        )
        marker = "" if ok == expected else "   <- differs from the September 2026 baseline"
        unexpected += 0 if ok == expected else 1
        short = re.sub(r"\s+", " ", detail)[:120]
        print(f"{status}  {label:<16}{marker}")
        if not ok:
            print(f"      {short}")

    print("\nbaseline (2026-09, measured directly against opencode.ai/zen/go): depth 1-8 pass / "
          "9+ fail, strict:true and strict:false both pass, recursive $ref fails.")
    if unexpected:
        print(f"{unexpected} probe(s) differ — re-check the limits before trusting the patches.")
    elif all(outcomes):
        print("every probe passed: you are probably talking to a patched proxy rather than the raw "
              "gateway. Re-run with --base https://opencode.ai/zen/go and a real key to see the "
              "upstream limits.")
    else:
        print("all probes match the baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
