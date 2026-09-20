# Measured limits and known defects (Muse Spark via OpenCode Zen/Go)

All items below were verified against `https://opencode.ai/zen/go` in September 2026, mostly on
`muse-spark-1.3-contributor` and `muse-spark-1.2-contributor`. Treat them as hypotheses to
re-probe (`scripts/probe_muse_schema.py`), not as permanent truths — the gateway changes often.

## Routing and auth

| Fact | Evidence |
| --- | --- |
| Muse is served on `/v1/responses`; the same model on `/v1/chat/completions` returns 500 | issue #44659 (2026-08-24) |
| The gateway requires a stable `x-opencode-session` header; missing it returns 400 `MissingSessionID` | proxy logs + gateway behavior, 2026-09-17 |
| Free (`-zen`) models are locked to OpenCode's own client: `403 FreeTierError: OpenCode's free tier can only be used from within OpenCode` | enforcement landed 2026-09-17/18; OpenCode maintainer in #49621: "We've been tightening our logic to fight abuse. You cannot use the free tier in other harnesses (this is only a limitation for the free tier nothing else)" |
| Paid (`-go`) models are explicitly open to other coding agents when the client identifies itself and sends a session id | `docs/go.mdx`: "OpenCode Go is designed for OpenCode and other coding agents…" |

## Tool-schema validation (the usual source of hard 400s)

| Limit | Evidence |
| --- | --- |
| **Empty property stubs `{"type": {}, "description": {}}`** are invalid → `400 … is not valid under any of the schemas listed in the 'anyOf' keyword`. Codex emits these for deferred tools such as `request_user_input` | direct gateway A/B, 2026-09-20: stub schema fails with `strict` both false and true; rewriting the stubs to `{"type": "string", "description": ""}` makes both pass |
| **Nesting depth ≤ 8 schema nodes** (root counts as 1); level 9 or deeper → 400 | direct depth-ladder probe, 2026-09-20: 1–8 pass, 9–10 fail |
| Recursive `$ref` → `400 Recursive JSON schemas are not currently supported` | issues #47157, #45800, #48151; reproduced directly 2026-09-20 |
| `strict` itself is **not** a trigger on this gateway — a schema that is valid for strict mode passes with `strict: true` | direct A/B 2026-09-20 |

Two lessons worth carrying forward:

- **Measure against the gateway directly.** The first pass at these limits was measured through a
  local proxy and produced two wrong conclusions (a "5-level" cap and `strict` as the trigger). Run
  `scripts/probe_muse_schema.py` with `--base https://opencode.ai/zen/go` and a real key, not at your
  own patched proxy — a patched proxy makes every probe pass and hides the upstream behavior.
- **Direct calls need client identity.** Cloudflare answers plain `python-urllib` user agents with
  error 1010, and the gateway requires `x-opencode-session`; the probe script sets both.

## Tool-call behavior

| Defect | Evidence |
| --- | --- |
| Namespaced tools come back as dotted names (`multi_agent_v1.spawn_agent`) with no `namespace` field; Codex's router rejects them (`unsupported call`) | issue #49915 (2026-09-19) |
| "text → tool" stall: the model writes "Next I'll run a command", returns `finish_reason: stop` with **zero** function calls, and the turn loops | issue #44659 (2026-08-24); also #43913. Reporter's workaround: instruct "no text before tool" |
| Streaming can truncate mid-word (`shell` → `shel`) without any error | issue #46236 (2026-08-30) |
| `max` reasoning effort is advertised but rejected (`invalid_request_error`); `xhigh` is the top usable level | PR #49995 (2026-09-19) |

## Commercial and privacy constraints

- Muse Spark Contributor is cheap because prompts and completions may be used to train future
  Meta models (OpenCode's privacy table marks it `Yes / Not ZDR`).
- Availability is limited to regions permitted by Meta's Geographic Use Policy.
- The free-model roster rotates every few weeks (Ox Alpha added/removed in August 2026,
  Union Alpha retired 2026-09-18), so "it worked last week" is often a roster change rather
  than a policy change.
