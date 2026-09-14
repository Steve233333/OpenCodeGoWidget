#!/bin/bash
# 说大白话：把配额解析器和 fixture 测试一起编译跑一遍，看官方改表格后解析还对不对（离线，不联网）
# 用法：scripts/test-quota-parse.sh          # 离线 fixture（打包前门禁）
#      scripts/test-quota-parse.sh --live   # 额外抓一次真实页面做冒烟
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

MODE="离线 fixture"
if [ "${1:-}" = "--live" ]; then
  MODE="fixture + 真实页面"
fi
echo "==> 配额解析自检（${MODE}）"
swiftc -O "$ROOT/Sources/GoQuotaRegistry.swift" "$ROOT/Tests/GoQuotaParseTests.swift" -o "$TMP/quota_parse_test"
"$TMP/quota_parse_test" "$@"
