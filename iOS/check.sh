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

echo "==> xcodebuild Release product"
xcodebuild -quiet \
  -project OpenCodeGoIOS.xcodeproj \
  -target OpenCodeGoIOS \
  -configuration Release \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$ROOT/iOS/build/Release-iphoneos/OpenCode Go.app"
WIDGET="$APP/PlugIns/OpenCodeGoWidgetIOSExtension.appex"
EXPECTED_GROUP="group.3e514c57016aaf19.1"

echo "==> validate Release metadata and resources"
APP_GROUP="$(plutil -extract OpenCodeAppGroupID raw -o - "$APP/Info.plist")"
WIDGET_GROUP="$(plutil -extract OpenCodeAppGroupID raw -o - "$WIDGET/Info.plist")"
test "$APP_GROUP" = "$EXPECTED_GROUP"
test "$WIDGET_GROUP" = "$EXPECTED_GROUP"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Info.plist")" = "1.0.17"
test "$(plutil -extract CFBundleVersion raw -o - "$APP/Info.plist")" = "18"
test "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw -o - "$WIDGET/Info.plist")" \
  = "com.apple.widgetkit-extension"
test -s "$APP/Assets.car"
test "$(plutil -extract CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName raw -o - "$APP/Info.plist")" = "AppIcon"

echo "==> validate iOS design regressions"
if grep -R -n -E '\.blue|tint\(\.blue\)|Color\.accentColor|近 30 天|最近 30 天' \
  "$ROOT/iOS/App" "$ROOT/iOS/Widget" "$ROOT/iOS/Shared"; then
  echo "ERROR: iOS UI still contains a retired blue accent or fixed 30-day window"
  exit 1
fi
if grep -n 'arrow.clockwise' "$ROOT/iOS/Widget/OpenCodeGoIOSWidget.swift"; then
  echo "ERROR: macOS-style iOS widget must not contain a refresh button"
  exit 1
fi
grep -q 'Label("总览"' "$ROOT/iOS/App/IOSRootView.swift"
grep -q 'Label("配额"' "$ROOT/iOS/App/IOSRootView.swift"
grep -q 'Label("设置"' "$ROOT/iOS/App/IOSRootView.swift"

echo "iOS check OK"
