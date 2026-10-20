#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> OpenCode auth.json Key 解析自检（离线）"
swiftc -O "$ROOT/Sources/KeychainStore.swift" "$ROOT/Tests/KeychainParseTests.swift" \
  -framework Security -o "$TMP/keychain_parse_test"
"$TMP/keychain_parse_test"
