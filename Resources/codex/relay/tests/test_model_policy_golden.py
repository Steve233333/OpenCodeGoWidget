"""模型策略基线（2026-09-23 转换层收敛 Phase ① 的护栏）。

这张表是**重构前**（1.1.11.34 的行为）对每个模型的路由与搜索能力的判定，逐条抄下来。
此后任何"顺手改行为"都会让这张表变红 —— 要改行为，必须显式改这张表并在 CHANGELOG 说明。

路由含义：
  native            只用原生 /responses
  native-or-bridge  先试原生；坏了走 chat 桥，并记住这个模型坏了（指数退避）
  bridge            直接走 chat 桥（不试探原生）
  messages          只认 Anthropic Messages 格式
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

from proxy.policy import policy_for, has_native_search, family_of  # noqa: E402

PASS, FAIL = [], []

# (模型 slug, 期望路由, 是否自带搜索)
GOLDEN = [
    ("glm-5.3-flash-go", "native-or-bridge", False),
    ("glm-5.3-go", "native-or-bridge", False),
    ("glm-5.2-go", "native-or-bridge", False),
    ("glm-5.1-go", "native-or-bridge", False),
    ("kimi-k3-go", "native-or-bridge", False),
    ("kimi-k2.7-code-go", "native-or-bridge", False),
    ("kimi-k2.6-go", "native-or-bridge", False),
    ("longcat-2.0-go", "native-or-bridge", False),
    ("mimo-v2.6-flash-go", "native-or-bridge", False),
    ("mimo-v2.6-pro-go", "native-or-bridge", False),
    ("mimo-v2.5-go", "native-or-bridge", False),
    ("mimo-v2.5-pro-go", "native-or-bridge", False),
    ("minimax-m3-go", "native-or-bridge", False),
    ("minimax-m2.7-go", "native-or-bridge", False),
    ("qwen3.8-max-go", "native-or-bridge", False),
    ("qwen3.8-flash-go", "native-or-bridge", False),
    ("qwen3.7-max-go", "native-or-bridge", False),
    ("qwen3.7-plus-go", "native-or-bridge", False),
    ("qwen3.6-plus-go", "native-or-bridge", False),
    ("hy4-preview-go", "native-or-bridge", False),
    ("hy3-go", "native-or-bridge", False),
    ("grok-4.6-go", "native-or-bridge", False),
    ("grok-4.7-go", "native", False),                    # 4.7 原生可用（唯一的 grok 覆盖）
    ("muse-spark-1.3-contributor-go", "native", True),    # muse：原生 + 自带搜索 + 空转守卫 + 预算下限
    ("muse-spark-1.2-contributor-go", "native", True),
    ("deepseek-v4.1-flash-go", "native", True),
    ("deepseek-v4-pro-go", "native", True),
    ("deepseek-v4-flash-go", "native", True),
    ("deepseek-v4-flash-vision-exp-go", "native", True),
    ("deepseek-v4-flash-vision-exp", "native", True),
    ("gpt-5.6-luna-go", "native", True),
    # 两个特殊模型：只认 Messages / 必须走桥
    ("union-alpha", "messages", False),
    ("omen-alpha", "bridge", False),
    # 名字归一：provider 前缀与 -zen 后缀都要能认出来
    ("opencode-go/mimo-v2.6-flash", "native-or-bridge", False),
    ("mimo-v2.5-free-zen", "native-or-bridge", False),
    # 表里没有的模型：按原生处理（今天的行为，别擅自改）
    ("brand-new-model-x", "native", False),
]


def check(name, fn):
    try:
        fn()
        PASS.append(name)
        print(f"  PASS {name}")
    except Exception as exc:  # noqa: BLE001
        FAIL.append((name, repr(exc)))
        print(f"  FAIL {name}: {exc!r}")


def t_policy_matches_pre_refactor_baseline():
    for slug, route, search in GOLDEN:
        p = policy_for(slug)
        assert p.route == route, f"{slug}: 路由 {p.route} ≠ 基线 {route}"
        assert has_native_search(slug) is search, f"{slug}: 自带搜索 {p.native_search} ≠ 基线 {search}"


def t_muse_quirks_live_in_one_place():
    p = policy_for("muse-spark-1.3-contributor-go")
    assert p.stall_guard and p.min_output_tokens == 16384, p
    assert family_of("muse-spark-1.2-contributor-free") == "muse-spark"
    for slug in ("mimo-v2.6-flash-go", "glm-5.3-go", "deepseek-v4.1-flash-go"):
        q = policy_for(slug)
        assert not q.stall_guard and q.min_output_tokens is None, f"{slug} 被 muse 规则污染了：{q}"


def t_policy_is_derived_not_duplicated():
    """策略表是唯一真源：config 里不该再有平行名单（以前有 3 份）"""
    import proxy.config as cfg
    leftovers = [n for n in ("RESPONSES_FALLBACK_MODELS", "RESPONSES_ALWAYS_BRIDGE",
                             "MESSAGES_ALWAYS_BRIDGE", "responses_broken_ttl")
                 if hasattr(cfg, n)]
    assert not leftovers, f"config 里还留着平行名单：{leftovers}"


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("t_"):
            check(name, fn)
    print(f"\n{len(PASS)} passed, {len(FAIL)} failed")
    sys.exit(1 if FAIL else 0)
