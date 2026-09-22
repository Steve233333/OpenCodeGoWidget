#!/bin/bash
# 说大白话：把"用量管线"的纯数据层（认日 / 合并 / 缺明细判定 / 按 Key 拆分）编译起来跑离线断言。
# 这些是过去一个月反复复发的 bug（纯色、差一天、按 Key 对不上），以前零测试覆盖 → 现在打包前必跑。
# 用法：scripts/test-usage-pipeline.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 用量管线自检（离线断言）"
# 只编译纯数据层：不 import SwiftUI、不碰网络，所以能离线跑（谁把 UI/网络拽进来会直接编译失败）
swiftc -O \
  "$ROOT/Sources/ChartFormatters.swift" \
  "$ROOT/Sources/BillingCycle.swift" \
  "$ROOT/Sources/UsageCostModels.swift" \
  "$ROOT/Sources/UsageMerge.swift" \
  "$ROOT/Sources/UsageRows.swift" \
  "$ROOT/Tests/UsagePipelineTests.swift" \
  -o "$TMP/usage_pipeline_test"
"$TMP/usage_pipeline_test"
