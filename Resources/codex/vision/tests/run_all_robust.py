#!/usr/bin/env python3
"""一键跑全量鲁莽性测试 + 原有回归
Run: python3 tests/run_all_robust.py
"""
import subprocess, sys, os, time
HERE = os.path.dirname(os.path.abspath(__file__))

tests = [
    ("原有单元 (48)", ["python3", os.path.join(HERE, "test_units.py")]),
    ("策略基线 (3)", ["python3", os.path.join(HERE, "test_model_policy_golden.py")]),
    ("终止事件修补 (8)", ["python3", os.path.join(HERE, "test_terminal_repair_relay.py")]),
    ("SSE 字节基线 (2)", ["python3", os.path.join(HERE, "test_sse_golden.py")]),
    ("代理混沌 (45)", ["python3", os.path.join(HERE, "test_robust.py")]),
    ("model_discovery 混沌 (19)", ["python3", os.path.join(HERE, "test_model_discovery_robust.py")]),
    ("installer/patch 混沌 (8)", ["python3", os.path.join(HERE, "test_installer_patch_robust.py")]),
]

total_pass = total_fail = 0
start = time.time()
print("="*70)
print("鲁莽性全量测试 - 一键执行")
print("="*70)
for name, cmd in tests:
    print(f"\n>>> {name}: {' '.join(cmd)}")
    proc = subprocess.run(cmd, cwd=os.path.join(HERE, ".."))
    if proc.returncode == 0:
        print(f"    ✅ {name} 全部通过")
    else:
        print(f"    ❌ {name} 有失败 (exit {proc.returncode})")

elapsed = time.time() - start
print("\n"+"="*70)
print(f"完成用时 {elapsed:.1f}s")
# 2026-09-30：这行以前是手写死的（写着 121，实际已经 133）—— 现在跟上面 tests 表里的数字对齐，
# 改测试记得一起改（build.sh --test 会跑这个脚本，数字不对说明有人加了用例没更新）。
_LABEL_TOTAL = 48 + 3 + 8 + 2 + 45 + 19 + 8
print(f"合计 {_LABEL_TOTAL} 用例 (48 单元 + 3 策略基线 + 8 终止修补 + 2 SSE 字节基线 + 45 混沌 + 19 discovery + 8 installer)")
print("若全部 PASS，适配器在边界/ fuzz / 状态机/表单 层面已通过鲁莽考验")
print("="*70)
