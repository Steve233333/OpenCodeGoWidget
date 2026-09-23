"""配置与常量：env 文件、CA 证书兜底、日志、模型/协议名单、推理档位注册表。"""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.request
import uuid



# 2026-09-19：python.org 装的 Python 如果没跑过 "Install Certificates.command"，
# 是没有 CA 根证书的 —— 所有 HTTPS 会直接抛
#   [SSL: CERTIFICATE_VERIFY_FAILED] unable to get local issuer certificate
# 表现是代理能把 502 吐给 Codex，但 Codex 只说 "Upstream proxy request failed"，很难查。
# macOS 自带一份 CA bundle（/etc/ssl/cert.pem），这里在发起任何 TLS 之前指过去兜底，
# 用户就不用再去双击那个 .command 了（1.1.10.3）。
if not os.environ.get("SSL_CERT_FILE") and os.path.exists("/etc/ssl/cert.pem"):
    os.environ["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"


HOP_HEADERS = {"connection", "content-length", "host", "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade"}


CODEX_HEADERS = {"originator", "session-id", "thread-id", "user-agent"}


DIRECT_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def load_env_file(path):
    """把 env 文件里的键值灌进 os.environ。

    2026-09-10 之前这里调用 vision_client.load_env_file；视觉链路下线后内联进来，
    代理不再依赖 vision_client.py。
    """
    if not path:
        return
    env_path = os.path.expanduser(str(path))
    if not os.path.isfile(env_path):
        return
    with open(env_path) as handle:
        raw_text = handle.read()
    for raw_line in raw_text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        # env 文件是用户的显式配置：同名变量以文件为准，覆盖系统环境里的值
        if key:
            os.environ[key] = value


_REASONING_REGISTRY_PATH = os.path.expanduser("~/.local/share/agent-vision-toolkit/reasoning_registry.json")


_REASONING_CACHE = None


_REASONING_CACHE_MTIME = 0


def _load_reasoning_registry():
    global _REASONING_CACHE, _REASONING_CACHE_MTIME
    try:
        mtime = os.path.getmtime(_REASONING_REGISTRY_PATH)
        if _REASONING_CACHE is not None and mtime == _REASONING_CACHE_MTIME:
            return _REASONING_CACHE
        data = json.loads(open(_REASONING_REGISTRY_PATH).read())
        _REASONING_CACHE = data
        _REASONING_CACHE_MTIME = mtime
        return data
    except Exception:
        return {}


def _clamp_reasoning_effort(model, effort):
    """Clamp requested effort to registry, generic fallback high only, no probe. Rank-aware."""
    if not isinstance(effort, str) or not effort:
        return effort
    bare = model or ""
    for suf in ("-go", "-zen"):
        if bare.endswith(suf):
            bare = bare[: -len(suf)]
            break
    reg = _load_reasoning_registry()
    allowed = reg.get(bare)
    if allowed is None:
        allowed = ["high"]
    if effort in allowed:
        return effort
    # handle aliases
    alias = {"minimal": "low", "ultra": "max", "none": None}
    if effort in alias:
        mapped = alias[effort]
        if mapped is None:
            return effort
        if mapped in allowed:
            _log(f"[vision-proxy] reasoning clamp {model} {effort} -> {mapped} (alias)")
            return mapped
        effort = mapped
        if effort in allowed:
            return effort
    # rank-aware nearest
    ORDER = ["low","medium","high","xhigh","max"]
    # map high->xhigh for qwen style where high not in allowed but xhigh is
    if effort == "high" and "xhigh" in allowed and "high" not in allowed:
        _log(f"[vision-proxy] reasoning clamp {model} high -> xhigh (qwen)")
        return "xhigh"
    if effort == "xhigh" and "high" in allowed and "xhigh" not in allowed:
        _log(f"[vision-proxy] reasoning clamp {model} xhigh -> high")
        return "high"
    try:
        req_idx = ORDER.index(effort)
    except ValueError:
        # unknown effort, fallback to high or first
        if "high" in allowed:
            _log(f"[vision-proxy] reasoning clamp {model} {effort} -> high (unknown)")
            return "high"
        return allowed[0] if allowed else effort
    # find nearest allowed by rank distance, prefer higher on tie
    best = allowed[0]
    best_dist = 999
    best_rank = -1
    for a in allowed:
        try:
            a_idx = ORDER.index(a)
        except ValueError:
            continue
        dist = abs(a_idx - req_idx)
        # tie prefer higher rank
        if dist < best_dist or (dist == best_dist and a_idx > best_rank):
            best = a
            best_dist = dist
            best_rank = a_idx
    _log(f"[vision-proxy] reasoning clamp {model} {effort} -> {best} (registry {allowed})")
    return best


ZEN_SUFFIX = "-zen"


ZEN_UPSTREAM = "https://opencode.ai/zen"


GO_SUFFIX = "-go"


GO_UPSTREAM = "https://opencode.ai/zen/go"


# ---------------------------------------------------------------------------
# 模型名的 provider 前缀（2026-09-23）：
# macOS 27 升级后实测 Codex 会发 `opencode-go/deepseek-v4.1-flash` 这种带 provider 前缀的
# 模型名（路由只认 `-go` / `-zen` 后缀，认不出来就当"官方 DeepSeek"转发到 api.deepseek.com → 401）。
# 这里把前缀**等价成后缀**，其它形态原样返回（裸名行为不变）。
# ---------------------------------------------------------------------------
_PROVIDER_PREFIXES = (("opencode-go/", GO_SUFFIX), ("opencode-zen/", ZEN_SUFFIX))


def normalize_route_model(model):
    """`opencode-go/<slug>` → `<slug>-go`，`opencode-zen/<slug>` → `<slug>-zen`；其余原样返回。"""
    if not isinstance(model, str):
        return model
    for prefix, suffix in _PROVIDER_PREFIXES:
        if model.startswith(prefix) and len(model) > len(prefix):
            return model[len(prefix):] + suffix
    return model


RESPONSES_FALLBACK_MODELS = frozenset({
    "mimo-v2.5", "mimo-v2.5-pro", "mimo-v2-pro", "mimo-v2-omni",
    # 2026-09-22：MiMo 2.6 两个新模型同属 chat 适配家族（/responses 需要走 chat 桥）
    "mimo-v2.6-flash", "mimo-v2.6-pro",
    "glm-5", "glm-5.1", "glm-5.2", "glm-5.3", "glm-5.3-flash",
    "ox-alpha-free", "x-preview-f-free",
    "qwen3.5-plus", "qwen3.6-plus", "qwen3.7-plus", "qwen3.7-max", "qwen3.8-max", "qwen3.8-flash",
    "kimi-k3", "kimi-k2.5", "kimi-k2.6", "kimi-k2.7-code",
    "minimax-m3", "minimax-m2.7", "minimax-m2.5",
    "longcat-2.0", "grok-4.5", "grok-4.6",
    "hy3", "hy3-preview", "hy4-preview",
    # Zen Free chat
    "big-pickle", "hy3-free", "ling-3.0-flash-fin-free", "mimo-v2.5-free",
    "nemotron-3-ultra-free", "nemotron-3.5-lightning-free",
})


_RESPONSES_BROKEN_UNTIL = {}      # model -> monotonic deadline to skip probing /responses


_RESPONSES_FALLBACK_TTL = 300.0   # seconds a broken probe result stays cached


RESPONSES_ALWAYS_BRIDGE = frozenset({"omen-alpha"})


MESSAGES_ALWAYS_BRIDGE = frozenset({"union-alpha"})


_UPSTREAM_TRANSIENT_STATUS = frozenset({500, 502, 503, 504})


_ANTHROPIC_VERSION = "2023-06-01"


_OC_SESSION_FALLBACK = uuid.uuid4().hex


_BRIDGE_NONSTREAM_MAX_BYTES = 64 * 1024 * 1024  # P5: cap for buffered non-stream chat bodies

# 终止事件宽限（2026-09-23，对齐 opencodex 的 modelResponsesTerminalRepair 契约）：
# muse-spark 在 OpenCode Go/Zen 的 Responses 模式下，长思考后可能"内容发完了但不发终止帧"，
# 或者干脆挂在连接上不再吐字节。以前前者会被判 response.failed（这一轮算中断），后者会让
# Codex 一直转圈 —— 现在给一个宽限窗口：内容已完整就自己补 response.completed 收尾。
TERMINAL_GRACE_SECONDS = 5.0     # 多久没新字节算"空闲"（socket 读超时）
TERMINAL_IDLE_MAX_ROUNDS = 24    # 内容还没完整时最多容忍多少次空闲（24 × 5s = 120s）才判失败


_SEARCH_TRUE_PREFIXES = ("deepseek-", "gpt-5.6-luna", "muse-spark", "grok-")


MUSE_MODEL_PREFIX = "muse-spark"


MUSE_SCHEMA_MAX_DEPTH = 8


MUSE_MAX_STALL_RETRIES = 2


_JSON_SCHEMA_TYPES = {"object", "array", "string", "number", "integer", "boolean", "null"}


_MUSE_STALL_MARKERS = ("正在", "马上", "这就", "已定位", "我来看看", "I'll", "I will", "let me", "Let me")


MUSE_NO_PREAMBLE_INSTRUCTION = (
    "严格约束（本条优先级最高）：本轮回复要么直接发起工具调用，要么给出最终答复，"
    "不允许只写「正在修」「马上改」「我来看看」这类说明——只描述计划而不调用工具，视为任务失败。"
)


MUSE_TOOL_FIRST_INSTRUCTION = (
    "工具优先约束：需要执行操作时立即调用工具，不要先用文字向用户描述你打算做什么。"
)


MUSE_STALL_RETRY_INSTRUCTION = (
    "上一条回复没有调用任何工具，只写了说明文字，用户拿不到任何结果。本轮要么直接发起工具调用，"
    "要么给出最终答复；需要执行操作就现在调用工具，不要再用文字描述计划。"
)


MUSE_STALL_RETRY_INSTRUCTION_HARD = MUSE_STALL_RETRY_INSTRUCTION + (
    "【第二次提醒】再次强调：禁止只输出「正在处理」这类文字。若本轮仍不调用工具，该任务判定失败。"
)


_MUSE_RETRY_WINDOW = 120.0


_MUSE_RETRY_LIMIT = 6


_MUSE_RETRY_HISTORY = {}


def _log(message):
    path = os.environ.get("VISION_LOG_FILE", "")
    if not message.startswith("[20"):  # already timestamped
        message = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}"
    if path:
        try:
            if os.path.exists(path) and os.path.getsize(path) > 5 * 1024 * 1024:
                open(path, "w").close()
            with open(path, "a") as handle:
                handle.write(message + "\n")
            return
        except OSError:
            pass
    print(message, file=os.sys.stderr, flush=True)


APPLY_PATCH_TOOL_DESCRIPTION = (
    "Edit files with a V4A patch. ALWAYS use this tool to write file content; never use shell "
    "redirection (cat/printf/echo >) for edits. "
    "Call this function with a single `input` string containing the full patch. "
    "The patch MUST start with exactly `*** Begin Patch` as the first line and end with `*** End Patch`. "
    "File operations: `*** Add File: <path>` (every content line prefixed with `+`, blank lines as bare `+`), "
    "`*** Update File: <path>` (hunks with `-old line` / `+new line`, no space after the prefix; optional context "
    "lines prefixed with a single space; optional single-sided `@@ <header>` anchors such as `@@ def foo():` -- "
    "never write a trailing `@@`), or `*** Delete File: <path>`. "
    "Use relative paths only. `-` lines and context lines must match the file byte-for-byte; if unsure, read the file first. "
    "Prefer surgical targeted edits over rewriting whole files. "
    "Inside the JSON string value, encode real newlines as \\n."
)


APPLY_PATCH_INPUT_DESCRIPTION = (
    "A V4A patch starting with `*** Begin Patch` and ending with `*** End Patch`; "
    "lines are `-text`, `+text`, or ` text` (single prefix char, no space after it). "
    "`*** Add File:` uses only `+`-prefixed lines (blank lines as bare `+`). "
    "Update hunks: `-` removes an existing byte-exact line, `+` adds a new line; "
    "add space-prefixed context lines or a single-sided `@@ <header>` if the `-` line is ambiguous. "
    "Relative paths only; never `@@ ... @@`."
)
