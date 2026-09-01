#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_BUNDLE_ID="com.steve233.opencodego"
WIDGET_BUNDLE_ID="com.steve233.opencodego.widget"
APP_NAME="OpenCodeGoWidget"
APP_BUNDLE_NAME="OpenCode 小组件"
WIDGET_NAME="OpenCodeGoWidget"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"

echo "==> 清理旧构建"
rm -rf build
mkdir -p "build/${APP_BUNDLE_NAME}.app/Contents/MacOS"
mkdir -p "build/${APP_BUNDLE_NAME}.app/Contents/Resources"
mkdir -p "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex/Contents/MacOS"
mkdir -p "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex/Contents/Resources"

echo "==> 拷贝资源"
cp Resources/AppIcon.icns "build/${APP_BUNDLE_NAME}.app/Contents/Resources/" 2>/dev/null || true
cp Resources/BrandLight.png "build/${APP_BUNDLE_NAME}.app/Contents/Resources/" 2>/dev/null || true
cp Resources/BrandDark.png "build/${APP_BUNDLE_NAME}.app/Contents/Resources/" 2>/dev/null || true
cp Resources/BrandLight.png "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex/Contents/Resources/" 2>/dev/null || true
cp Resources/BrandDark.png "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex/Contents/Resources/" 2>/dev/null || true

echo "==> 编写 Info.plist"
cat > "build/${APP_BUNDLE_NAME}.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIconName</key><string>AppIcon</string>
	<key>CFBundleExecutable</key><string>${APP_NAME}</string>
	<key>CFBundleIdentifier</key><string>${APP_BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>OpenCode 小组件</string>
	<key>CFBundleDisplayName</key><string>OpenCode 小组件</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.1.4</string>
	<key>CFBundleVersion</key><string>6</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><false/>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>com.steve233.opencodego</string><key>CFBundleURLSchemes</key><array><string>opencodego</string></array></dict></array>
</dict>
</plist>
PLIST

cat > "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex/Contents/Info.plist" <<PLIST
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
	<key>CFBundleShortVersionString</key><string>1.1.4</string>
	<key>CFBundleVersion</key><string>6</string>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
	<key>DTPlatformName</key><string>macosx</string>
	<key>NSExtension</key><dict>
		<key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
	</dict>
</dict>
</plist>
PLIST

echo "==> 编译 App"
swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" -swift-version 5 -module-cache-path /tmp/mcp \
  Sources/App.swift Sources/UsageModels.swift Sources/KeychainStore.swift Sources/NetworkManager.swift Sources/WidgetDataStore.swift Sources/CostCrawler.swift Sources/ModelPalette.swift Sources/ModelRegistry.swift Sources/GoQuotaRegistry.swift Sources/GoQuotaChart.swift Sources/BillingCycle.swift \
  -o "build/${APP_BUNDLE_NAME}.app/Contents/MacOS/${APP_NAME}"

echo "==> 编译 Widget"
swiftc -parse-as-library -application-extension -target "$TARGET" -sdk "$SDK" -swift-version 5 -module-cache-path /tmp/mcp \
  -Xlinker -e -Xlinker _NSExtensionMain \
  Widget/OpenCodeGoWidget.swift Sources/UsageModels.swift Sources/KeychainStore.swift Sources/NetworkManager.swift Sources/WidgetDataStore.swift Sources/CostCrawler.swift Sources/ModelPalette.swift Sources/ModelRegistry.swift Sources/GoQuotaRegistry.swift Sources/GoQuotaChart.swift Sources/BillingCycle.swift \
  -o "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex/Contents/MacOS/${WIDGET_NAME}"

SIGN_IDENTITY="-"
SIGN_ARGS=(--sign "$SIGN_IDENTITY")
echo "!! 强制 ad-hoc 签名（保证 Dock 中文名与签名校验通过）"

echo "==> 签名 Widget"
if [ "$SIGN_IDENTITY" = "-" ]; then
  # ad-hoc：不带 --options runtime，但保留 entitlements（App Groups/沙盒），否则 widget 无法共享数据且可能触发 invalid blob
  codesign --force --deep "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex"
else
  codesign --force --deep --options runtime "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex"
fi
echo "==> 签名 App"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "build/${APP_BUNDLE_NAME}.app"
else
  codesign --force --deep --options runtime "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "build/${APP_BUNDLE_NAME}.app"
fi

echo "==> 安装到 /Applications"
rm -rf "/Applications/OpenCodeGoWidget.app"
rm -rf "/Applications/${APP_BUNDLE_NAME}.app"
ditto "build/${APP_BUNDLE_NAME}.app" "/Applications/${APP_BUNDLE_NAME}.app"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "/Applications/${APP_BUNDLE_NAME}.app" 2>/dev/null || true
else
  codesign --force --deep --options runtime "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "/Applications/${APP_BUNDLE_NAME}.app" 2>/dev/null || true
fi

echo "==> 注册"
# 生成可安装文件（DMG + ZIP）到 dist/，再清理 build 中间产物
DIST_DIR="$(pwd)/dist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "build/${APP_BUNDLE_NAME}.app/Contents/Info.plist" 2>/dev/null || echo "1.0")"
DMG_NAME="${APP_BUNDLE_NAME}-${VERSION}.dmg"
ZIP_NAME="${APP_BUNDLE_NAME}-${VERSION}.zip"
mkdir -p "$DIST_DIR"
# 保留 build 供打包
STAGING_DIR="build/staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
ditto "build/${APP_BUNDLE_NAME}.app" "$STAGING_DIR/${APP_BUNDLE_NAME}.app"
# 创建带 Applications 替身的 DMG（便于拖拽安装）
DMG_TMP="$STAGING_DIR/dmg"
rm -rf "$DMG_TMP"
mkdir -p "$DMG_TMP"
ditto "build/${APP_BUNDLE_NAME}.app" "$DMG_TMP/${APP_BUNDLE_NAME}.app"
ln -s /Applications "$DMG_TMP/Applications" 2>/dev/null || true
# 生成 DMG（UDZO 压缩，兼容性好）
if hdiutil create -volname "${APP_BUNDLE_NAME}" -srcfolder "$DMG_TMP" -ov -format UDZO "build/${DMG_NAME}" 2>&1 | tail -5; then
  ditto "build/${DMG_NAME}" "$DIST_DIR/${DMG_NAME}"
  echo "DMG 已生成: $DIST_DIR/${DMG_NAME}"
else
  echo "!! DMG 生成失败，回退为 ZIP"
fi
# 生成 ZIP（保留 Finder 拖拽安装可用）
if ditto -c -k --sequesterRsrc --keepParent "build/${APP_BUNDLE_NAME}.app" "build/${ZIP_NAME}" 2>&1 | tail -3; then
  ditto "build/${ZIP_NAME}" "$DIST_DIR/${ZIP_NAME}"
  echo "ZIP 已生成: $DIST_DIR/${ZIP_NAME}"
fi
# 也保留未压缩的 .app 到 dist 供直接分发
ditto "build/${APP_BUNDLE_NAME}.app" "$DIST_DIR/${APP_BUNDLE_NAME}.app"
echo "APP 已复制: $DIST_DIR/${APP_BUNDLE_NAME}.app"
# 清理 build 中间产物（保留 dist）
rm -rf build
# 注册系统服务
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/${APP_BUNDLE_NAME}.app" 2>/dev/null || true
killall pkd 2>/dev/null || true
sleep 1
pluginkit -a "/Applications/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex" 2>/dev/null || true
pluginkit -e use -p com.apple.widgetkit-extension -i "$WIDGET_BUNDLE_ID" 2>/dev/null || true

echo "完成：open /Applications/${APP_BUNDLE_NAME}.app 然后在通知中心添加小组件"
echo "可安装文件位于 dist/:"
ls -lh "$DIST_DIR" 2>&1 | tail -20
