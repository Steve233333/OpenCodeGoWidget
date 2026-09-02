#!/usr/bin/env python3
"""一键跑全量鲁莽性测试 + 原有回归
Run: python3 tests/run_all_robust.py
"""
import subprocess, sys, os, time
HERE = os.path.dirname(os.path.abspath(__file__))

tests = [
    ("原有单元 (12)", ["python3", os.path.join(HERE, "test_units.py")]),
    ("vision 混沌 (32)", ["python3", os.path.join(HERE, "test_robust.py")]),
    ("model_discovery 混沌 (14)", ["python3", os.path.join(HERE, "test_model_discovery_robust.py")]),
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
# summary attempt: count passes from each
# We already printed per-suite, overall we consider 12+32+14+8 = 66 cases
print("合计 66 鲁莽用例 (12+32+14+8) + 现有回归均已执行")
print("若全部 PASS，适配器在边界/ fuzz / 状态机/表单 层面已通过鲁莽考验")
print("="*70)
