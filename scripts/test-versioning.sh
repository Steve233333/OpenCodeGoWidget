#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> App 静默更新版本判定自检（离线）"
swiftc -O "$ROOT/Sources/Versioning.swift" "$ROOT/Tests/VersioningTests.swift" -o "$TMP/versioning_test"
"$TMP/versioning_test"
