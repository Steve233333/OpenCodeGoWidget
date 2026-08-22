#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_BUNDLE_ID="com.steve233.opencodego"
WIDGET_BUNDLE_ID="com.steve233.opencodego.widget"
APP_NAME="OpenCodeGoWidget"
WIDGET_NAME="OpenCodeGoWidget"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"

echo "==> 清理旧构建"
rm -rf build
mkdir -p "build/${APP_NAME}.app/Contents/MacOS"
mkdir -p "build/${APP_NAME}.app/Contents/Resources"
mkdir -p "build/${APP_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex/Contents/MacOS"
mkdir -p "build/${APP_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex/Contents/Resources"

echo "==> 编写 Info.plist"
cat > "build/${APP_NAME}.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
	<key>CFBundleExecutable</key><string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key><string>${APP_BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key><string>OpenCode Go</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><false/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>com.steve233.opencodego</string><key>CFBundleURLSchemes</key><array><string>opencodego</string></array></dict></array>
</dict>
</plist>
PLIST

cat > "build/${APP_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
	<key>CFBundleDisplayName</key><string>OpenCode Go</string>
	<key>CFBundleExecutable</key><string>${WIDGET_NAME}</string>
	<key>CFBundleIdentifier</key><string>${WIDGET_BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>${WIDGET_NAME}</string>
	<key>CFBundlePackageType</key><string>XPC!</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
	<key>DTPlatformName</key><string>macosx</string>
	<key>NSExtension</key><dict>
		<key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
	</dict>
</dict>
</plist>
PLIST

echo "==> 编译 App"
swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" -swift-version 5 \
  Sources/App.swift Sources/UsageModels.swift Sources/KeychainStore.swift Sources/NetworkManager.swift Sources/WidgetDataStore.swift Sources/CostCrawler.swift Sources/ModelPalette.swift \
  -o "build/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

echo "==> 编译 Widget"
swiftc -parse-as-library -application-extension -target "$TARGET" -sdk "$SDK" -swift-version 5 \
  -Xlinker -e -Xlinker _NSExtensionMain \
  Widget/OpenCodeGoWidget.swift Sources/UsageModels.swift Sources/KeychainStore.swift Sources/NetworkManager.swift Sources/WidgetDataStore.swift Sources/CostCrawler.swift Sources/ModelPalette.swift \
  -o "build/${APP_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex/Contents/MacOS/${WIDGET_NAME}"

# Ensure codex-signing keychain is in search list for codesign without explicit --keychain fallback
security list-keychains -d user -s "$HOME/Library/Keychains/codex-signing.keychain-db" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null || true
SIGN_IDENTITY="Codex Patched Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/codex-signing.keychain-db"
for _pw in "0000" "" "codex123"; do security unlock-keychain -p "$_pw" "$SIGN_KEYCHAIN" 2>/dev/null && break; done || true
if ! security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "!! 未找到 $SIGN_IDENTITY，使用 ad-hoc（widget 刷新可能不稳定）"
  SIGN_IDENTITY="-"
  SIGN_ARGS=(--sign "$SIGN_IDENTITY")
else
  # Try common passwords for the codex-signing keychain
  SIGN_ARGS=(--sign "$SIGN_IDENTITY" --keychain "$SIGN_KEYCHAIN")
fi

echo "==> 签名 Widget"
codesign --force --options runtime "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "build/${APP_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex"
echo "==> 签名 App"
codesign --force --options runtime "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "build/${APP_NAME}.app"

echo "==> 安装到 /Applications"
rm -rf "/Applications/${APP_NAME}.app"
ditto "build/${APP_NAME}.app" "/Applications/${APP_NAME}.app"
codesign --force --options runtime "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "/Applications/${APP_NAME}.app" 2>/dev/null || true

echo "==> 注册"
# 清理同名旧 build 产物
rm -rf build
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/${APP_NAME}.app" 2>/dev/null || true
killall pkd 2>/dev/null || true
sleep 1
pluginkit -a "/Applications/${APP_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex" 2>/dev/null || true
pluginkit -e use -p com.apple.widgetkit-extension -i "$WIDGET_BUNDLE_ID" 2>/dev/null || true

echo "完成：open /Applications/${APP_NAME}.app 然后在通知中心添加小组件"
