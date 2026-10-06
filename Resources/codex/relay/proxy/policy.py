"""模型策略层：每个模型家族的"怪癖"在**这一处**定义（2026-09-23）。

为什么要有它：路由、搜索能力、终止宽限、输出预算、空转守卫这些判断以前散在 4~5 个地方
（同一句 `model.startswith(("deepseek-", "gpt-5.6-luna", "muse-spark"))` 写了 4 遍），
改一处漏一处 —— 过去一个月的反复 bug 大多是这么来的。

两层结构：
  * `MODEL_FAMILIES`：家族级默认（按前缀匹配，最长前缀赢）
  * `MODEL_OVERRIDES`：单个 slug 覆盖（例如 grok-4.7 走原生、grok-4.5/4.6 走桥）
入口只有 `policy_for(model)`；它顺手把名字归一（去 `-go`/`-zen` 后缀与 `opencode-go/` 前缀），
所以调用方不用自己剥。

字段含义：
  route            native（只用原生）/ native-or-bridge（先试原生，坏了走 chat 桥并学习）/
                   bridge（直接走 chat 桥）/ messages（只认 Anthropic Messages 格式）
  native_search    模型自带 web_search；False 的由 search_sidecar 合成
  terminal_grace   上游没发终止帧时的宽限秒数；None = 用全局默认
  min_output_tokens 输出预算下限；None = 不干预（注意 muse 的推理也吃这个预算）
  stall_guard      是否启用"只叙述不调用工具"的空转守卫
  smoothing        正文是否做漏桶平滑（上游一次性涌出时按速率滴）
"""

from __future__ import annotations

import time
from dataclasses import dataclass, replace

ROUTE_NATIVE = "native"
ROUTE_NATIVE_OR_BRIDGE = "native-or-bridge"
ROUTE_BRIDGE = "bridge"
ROUTE_MESSAGES = "messages"

MUSE_MIN_OUTPUT_TOKENS = 16384      # 实测 80 预算里 reasoning 占 77 → 一个字没吐就 incomplete


@dataclass(frozen=True)
class ModelPolicy:
    route: str = ROUTE_NATIVE
    native_search: bool = False
    terminal_grace: float | None = None
    min_output_tokens: int | None = None
    stall_guard: bool = False
    smoothing: bool = True


# ---- 家族级默认（前缀匹配，最长前缀赢）----
MODEL_FAMILIES: dict[str, ModelPolicy] = {
    # 原生 Responses + 自带搜索
    "deepseek": ModelPolicy(route=ROUTE_NATIVE, native_search=True),
    "gpt-": ModelPolicy(route=ROUTE_NATIVE, native_search=True),
    "muse-spark": ModelPolicy(route=ROUTE_NATIVE, native_search=True,
                              stall_guard=True, min_output_tokens=MUSE_MIN_OUTPUT_TOKENS),
    # chat 适配家族：先试原生，坏了走桥（并且记住这个模型坏了，按指数退避）
    "mimo": ModelPolicy(route=ROUTE_NATIVE_OR_BRIDGE),
    "glm": ModelPolicy(route=ROUTE_NATIVE_OR_BRIDGE),
    "kimi": ModelPolicy(route=ROUTE_NATIVE_OR_BRIDGE),
    "qwen": ModelPolicy(route=ROUTE_NATIVE_OR_BRIDGE),
    "minimax": ModelPolicy(route=ROUTE_NATIVE_OR_BRIDGE),
    "longcat": ModelPolicy(route=ROUTE_NATIVE_OR_BRIDGE),
    "hy": ModelPolicy(route=ROUTE_NATIVE_OR_BRIDGE),
    "grok": ModelPolicy(route=ROUTE_NATIVE_OR_BRIDGE),
    # 2026-09-24 实测（Go 网关）：space-bunny-free 的 /responses 恒 503
    # "Upstream request failed: Endpoint is unavailable."，/chat/completions 200
    # （官方文档也把它标成 @ai-sdk/openai-compatible）。所以直接走 chat 桥，
    # 不学"先试原生、坏了再桥"，省掉每次上线后那一次注定失败的探测。
    "space-bunny": ModelPolicy(route=ROUTE_BRIDGE),
    # Zen 免费家族（同样是 chat 适配）
    "ox-alpha": ModelPolicy(route=ROUTE_NATIVE_OR_BRIDGE),
    "x-preview": ModelPolicy(route=ROUTE_NATIVE_OR_BRIDGE),
    "big-pickle": ModelPolicy(route=ROUTE_NATIVE_OR_BRIDGE),
    "ling-": ModelPolicy(route=ROUTE_NATIVE_OR_BRIDGE),
    "nemotron-": ModelPolicy(route=ROUTE_NATIVE_OR_BRIDGE),
}

# ---- 单模型覆盖（第二层）----
MODEL_OVERRIDES: dict[str, dict] = {
    # grok 4.7 原生可用，4.5/4.6 只能走桥（家族默认是 native-or-bridge）
    "grok-4.7": {"route": ROUTE_NATIVE},
    # 只认 Anthropic Messages 格式的模型：/responses 必失败，别浪费探测
    "union-alpha": {"route": ROUTE_MESSAGES},
    # 明确"必须走 chat 桥"的：不试探原生
    "omen-alpha": {"route": ROUTE_BRIDGE},
    # 2026-09-27：Go 的免费预览模型（限时免费）都只挂 chat/completions
    #（官方文档标 @ai-sdk/openai-compatible）。实测 space-bunny-free 的 /responses 恒 503、
    # longcat-2.5-preview-free 的 /responses 恒 400 "ModelProtocolUnsupported"，
    # 而 chat 都是 200 —— 所以直接走桥，不浪费那一次注定失败的探测。
    "longcat-2.5-preview-free": {"route": ROUTE_BRIDGE},
}

_DEFAULT_POLICY = ModelPolicy()          # 表里没有的模型：按原生处理（今天的行为）


def normalize_model_name(model):
    """`opencode-go/x-go` → `x`；家族匹配和查表都用归一后的名字。"""
    if not isinstance(model, str) or not model:
        return model
    name = model
    for prefix in ("opencode-go/", "opencode-zen/"):
        if name.startswith(prefix):
            name = name[len(prefix):]
            break
    for suffix in ("-go", "-zen"):
        if name.endswith(suffix):
            return name[: -len(suffix)]
    return name


def family_of(model):
    """命中的家族前缀（最长匹配）；没有就返回 None。"""
    name = normalize_model_name(model)
    if not isinstance(name, str):
        return None
    hit = None
    for prefix in MODEL_FAMILIES:
        if name.startswith(prefix) and (hit is None or len(prefix) > len(hit)):
            hit = prefix
    return hit


def policy_for(model) -> ModelPolicy:
    """家族默认 + 单模型覆盖 → 最终策略。表里没有的模型按原生处理。"""
    name = normalize_model_name(model)
    if not isinstance(name, str) or not name:
        return _DEFAULT_POLICY
    policy = _DEFAULT_POLICY
    family = family_of(name)
    if family:
        policy = MODEL_FAMILIES[family]
    override = MODEL_OVERRIDES.get(name)
    if override:
        policy = replace(policy, **override)
    return policy


class NativeProbeCache:
    """学"这个模型的原生 /responses 坏了"：直接走桥 + 连续失败指数退避。

    逻辑与 2026-09-23 之前一致（只是从 config 搬过来，成为唯一实现）：
    头一次坏 → 缓存 5 分钟；还坏 → 15/45 分钟；上限 2 小时；原生成功一次清零。
    这样既不会每 5 分钟白试一次，也不会在上游修好之后一直不回原生。
    """

    def __init__(self, base_ttl=300.0, max_ttl=7200.0, growth=3.0):
        self.base_ttl = base_ttl
        self.max_ttl = max_ttl
        self.growth = growth
        self._broken_until: dict[str, float] = {}
        self._streak: dict[str, int] = {}

    def is_broken(self, model) -> bool:
        name = normalize_model_name(model)
        if not isinstance(name, str):
            return False
        deadline = self._broken_until.get(name, 0.0)
        return time.monotonic() < deadline

    def ttl_for(self, model) -> float:
        """当前该缓存多久（连续失败次数决定）。"""
        name = normalize_model_name(model)
        streak = self._streak.get(name, 0) if isinstance(name, str) else 0
        steps = max(0, min(streak - 1, 3))
        return min(self.base_ttl * (self.growth ** steps), self.max_ttl)

    def note_failure(self, model) -> float:
        """记一次失败，返回这次要缓存多少秒。"""
        name = normalize_model_name(model)
        if not isinstance(name, str):
            return self.base_ttl
        self._streak[name] = self._streak.get(name, 0) + 1
        ttl = self.ttl_for(name)
        self._broken_until[name] = time.monotonic() + ttl
        return ttl

    def note_success(self, model):
        name = normalize_model_name(model)
        if isinstance(name, str):
            self._streak.pop(name, None)
            self._broken_until.pop(name, None)

    def streak(self, model) -> int:
        name = normalize_model_name(model)
        return self._streak.get(name, 0) if isinstance(name, str) else 0


NATIVE_PROBES = NativeProbeCache()

# 谓词形式的对外接口（旧的那几个 frozenset 名单已删 —— 它们正是"同一规则写好几遍"的来源）
def is_chat_adapted(model) -> bool:
    """chat 适配家族：原生可能可用，坏了就走 chat 桥。"""
    return policy_for(model).route == ROUTE_NATIVE_OR_BRIDGE


def is_always_bridge(model) -> bool:
    return policy_for(model).route == ROUTE_BRIDGE


def is_messages_only(model) -> bool:
    return policy_for(model).route == ROUTE_MESSAGES


def has_native_search(model) -> bool:
    """模型自带 web_search（否则由 search_sidecar 合成）。"""
    return policy_for(model).native_search


# ---- 上游"协议不支持"错误（2026-09-27）----
#
# 背景：chat-only 的模型（mimo/glm/kimi… 以及新的免费预览模型）在 `/responses` 上本来就跑不了，
# 以前网关回 5xx（503 Endpoint is unavailable / 500），我们靠 `needs_bridge = status >= 500` 接住；
# 2026-09-27 网关把 mimo/GLM 的 /responses 改成 **400 ModelProtocolUnsupported**，
# 落在"<500"里 → 桥接不触发 → 用户直接看到 400。这种 400 只是"协议不对"，不是请求写错了，
# 所以要把响应体看一眼再决定切不切桥（真正的 400 仍然原样透传）。
_PROTOCOL_UNSUPPORTED_MARKERS = (
    b"ModelProtocolUnsupported",
    b"does not support this protocol",
    b"Endpoint is unavailable",
)


def protocol_unsupported_error(body: bytes) -> bool:
    """响应体是不是"这个模型不支持该协议"（用来决定该不该切 chat 桥）。"""
    if not body:
        return False
    return any(marker in body for marker in _PROTOCOL_UNSUPPORTED_MARKERS)
