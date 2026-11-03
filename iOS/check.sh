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
ICONS=(
  "AppIcon60x60@2x.png"
  "AppIcon60x60@3x.png"
  "AppIcon76x76@2x.png"
  "AppIcon83.5x83.5@2x.png"
)

echo "==> validate Release metadata and resources"
APP_GROUP="$(plutil -extract OpenCodeAppGroupID raw -o - "$APP/Info.plist")"
WIDGET_GROUP="$(plutil -extract OpenCodeAppGroupID raw -o - "$WIDGET/Info.plist")"
test "$APP_GROUP" = "$EXPECTED_GROUP"
test "$WIDGET_GROUP" = "$EXPECTED_GROUP"
test "$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Info.plist")" = "1.0.1"
test "$(plutil -extract CFBundleVersion raw -o - "$APP/Info.plist")" = "2"
test "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw -o - "$WIDGET/Info.plist")" \
  = "com.apple.widgetkit-extension"
for icon in "${ICONS[@]}"; do
  test -s "$APP/$icon"
done

echo "iOS check OK"
