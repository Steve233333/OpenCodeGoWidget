#!/bin/bash
# 说大白话：把密钥页解析器和 fixture 测试一起编译跑一遍，看官网页面结构变了之后
# "浏览器登录自动获取"还灵不灵（离线，不联网）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 密钥页解析自检（离线 fixture）"
swiftc -O "$ROOT/Sources/OpenCodeKeyFetcher.swift" "$ROOT/Tests/OpenCodeKeyParseTests.swift" -o "$TMP/key_parse_test"
"$TMP/key_parse_test"

# 2026-09-24：控制台密钥列表（GET /console/api/service-accounts）的解析规则自检 ——
# "只留 active 且没过期的钥匙"就是下拉框内容，以前零测试覆盖（新建 Key 永远不出现那次就栽在这）。
echo "==> 控制台密钥列表解析自检（离线 fixture）"
swiftc -O \
  "$ROOT/Sources/ChartFormatters.swift" \
  "$ROOT/Sources/BillingCycle.swift" \
  "$ROOT/Sources/UsageCostModels.swift" \
  "$ROOT/Tests/KeyListParseTests.swift" \
  -o "$TMP/key_list_parse_test"
"$TMP/key_list_parse_test"
