#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/iOS"

xcodegen generate
./typecheck.sh

echo "==> xcodebuild App + Widget (arm64, unsigned)"
xcodebuild -quiet \
  -project OpenCodeGoIOS.xcodeproj \
  -target OpenCodeGoIOS \
  -configuration Debug \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "==> xcodebuild tests bundle"
xcodebuild -quiet \
  -project OpenCodeGoIOS.xcodeproj \
  -target OpenCodeGoIOSTests \
  -configuration Debug \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "iOS check OK"
