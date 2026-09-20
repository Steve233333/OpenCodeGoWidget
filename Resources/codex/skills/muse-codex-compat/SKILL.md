---
name: muse-codex-compat
description: Make a Muse Spark model (OpenCode Zen/Go) work through Codex or another OpenAI Responses client behind a local proxy — invalid-JSON-schema 400s, free-tier 403s, dropped tool calls, and narration-only turns. Use when a Muse model fails or misbehaves while other models on the same gateway work fine.
metadata:
  short_description: Fix Muse Spark through a Codex proxy
---

# Muse Spark ⇄ Codex compatibility

Muse Spark runs on Meta's backend behind `https://opencode.ai/zen/go`. Its tool-schema
validator and tool-call streaming differ from every other model on that gateway, so a proxy
that works for DeepSeek / GLM / MiMo can still fail on Muse. This skill covers the known
incompatibilities, how to tell them apart, and how to patch them without touching other models.

## When this applies

- A `-go` / `-zen` Muse model returns `400 invalid_request_error … Invalid JSON schema`.
- Requests return `403 FreeTierError: OpenCode's free tier can only be used from within OpenCode`.
- The model answers "I'll now do X" without any tool call, turn after turn, and never finishes.
- Tool calls are dropped, or named `namespace.tool` instead of `name` + `namespace`.

Not for: switching models, provider setup, or general proxy debugging unrelated to Muse.

## Diagnose before patching

1. Read the proxy log for the failing transaction: `… route=go status=400/403 …`, plus the
   rewrite lines immediately before it. The error text normally names the schema that failed.
2. Match the symptom to a cause in [references/upstream-limits.md](references/upstream-limits.md).
   It records each measured limit with evidence and date, so you can tell "Meta rejects this
   construct" from "this client sends it wrong".
3. Confirm the limit still exists before coding around it:

   ```bash
   python3 scripts/probe_muse_schema.py --base http://127.0.0.1:19100 --model muse-spark-1.3-contributor-go
   ```

   It sends a small ladder of probes (schema nesting depth, `strict` on/off, recursive `$ref`)
   and prints PASS/FAIL per probe.

## Fixes

Implement as request/response rewrites in the proxy, gated on the model name starting with
`muse-spark`. Hook points, code snippets, switches, and rollback:
[references/patch-playbook.md](references/patch-playbook.md).

| Symptom | Fix |
| --- | --- |
| 400 `Invalid JSON schema` on the client's own tools | repair empty `{"type": {}}` stubs, then cap nesting at 8 levels |
| 400 `Recursive JSON schemas are not currently supported` | inline local `$ref` |
| 400 strict-validation complaints (`additionalProperties`, `anyOf`) | usually the empty stubs above; forcing `strict: false` is cheap insurance, not the fix |
| `unsupported call: ns.tool` | split dotted tool names into `name` + `namespace` in the response |
| Turns that only narrate ("正在修…", "I'll now…") | hard "tool call or final answer" constraint at the end of `input`; optional buffered stall-retry |

## Constraints that keep this safe

- Gate every rewrite on the Muse model name, and assert in tests that other models' request and
  response bytes are unchanged.
- Keep each fix behind its own env switch so it can be turned off without editing code.
- Back up the proxy file before editing; restart the proxy only after `py_compile` and the offline
  tests pass.
- Do not weaken the client checks OpenCode uses to gate its free tier. A 403 there is answered by
  a paid route or the official client, never by spoofing client headers.
- Muse trains on request data and is region-restricted by Meta's policy; warn the user rather than
  routing sensitive content through it or trying to work around those terms.

## Verify

```bash
python3 scripts/test_muse_compat.py ~/.local/share/agent-vision-toolkit/vision_proxy.py
```

Twelve offline assertions: each rewrite fires for Muse, no-ops for other models, and stall
detection ignores replayed `instructions`. After a live run, replay a real failing request and
confirm `200` plus the expected rewrite lines in the proxy log.
