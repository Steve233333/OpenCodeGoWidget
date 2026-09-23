#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# 2026-09-23（Phase 0）：**版本号只有一个真源** = ./VERSION。
# 以前每次发版要手改 build.sh 里的 4 处（两个 plist × 2 个键），25 个提交里改了 19 次。
# CFBundleVersion 由版本号推导（1.1.11.25 → 111125），保证单调递增、也不用第二个文件。
APP_VERSION="$(tr -d ' \n' < VERSION)"
BUILD_NUMBER="$(printf '%s' "$APP_VERSION" | tr -d '.')"

# --test：只跑测试门槛，不打包（CI/本地自检用）。不加参数时也会先过同一套门槛。
TEST_ONLY=0
if [ "${1:-}" = "--test" ]; then TEST_ONLY=1; fi

# 发布直链跟着 VERSION 走（2026-09-23）：README 里 4 条 releases/latest/download/OpenCodeGoWidget-<版本>*
# 以前每版要手改，漏改就 404。打包时（--test 不动文件）自动改到当前版本。
if [ "$TEST_ONLY" != "1" ] && [ -f README.md ]; then
  # 用 (.dmg|.zip) 结尾来锚定，别写 `[0-9.]+`：那个会把版本号后面那个点也吃进去 → 链接变成 1.1.11.26dmg
  /usr/bin/sed -i '' -E "s#(releases/latest/download/OpenCodeGoWidget-)[0-9]+(\.[0-9]+)+\.(dmg|zip)#\1${APP_VERSION}.\3#g" README.md
fi

APP_BUNDLE_ID="com.steve233.opencodego"
WIDGET_BUNDLE_ID="com.steve233.opencodego.widget"
APP_NAME="OpenCodeGoWidget"
APP_BUNDLE_NAME="OpenCode 小组件"
WIDGET_NAME="OpenCodeGoWidget"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SDKVER="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo unknown)"
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
cp Resources/MenuBarIcon.png "build/${APP_BUNDLE_NAME}.app/Contents/Resources/" 2>/dev/null || true
cp Resources/MenuBarIcon@2x.png "build/${APP_BUNDLE_NAME}.app/Contents/Resources/" 2>/dev/null || true
cp Resources/BrandLight.png "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex/Contents/Resources/" 2>/dev/null || true
cp Resources/BrandDark.png "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex/Contents/Resources/" 2>/dev/null || true
# Codex 一键配置资源（供设置页内调用）
if [ -d "Resources/codex" ]; then
  mkdir -p "build/${APP_BUNDLE_NAME}.app/Contents/Resources/codex"
  ditto "Resources/codex" "build/${APP_BUNDLE_NAME}.app/Contents/Resources/codex"
  # 兼容 installer 脚本的 resources/ 前缀：建 resources 软链指向自身
  ln -sfn . "build/${APP_BUNDLE_NAME}.app/Contents/Resources/codex/resources" 2>/dev/null || true
  chmod +x "build/${APP_BUNDLE_NAME}.app/Contents/Resources/codex/codex-oneclick-setup.command" 2>/dev/null || true
  chmod +x "build/${APP_BUNDLE_NAME}.app/Contents/Resources/codex/patch/patch.sh" 2>/dev/null || true
  chmod +x "build/${APP_BUNDLE_NAME}.app/Contents/Resources/codex/scripts/"*.sh 2>/dev/null || true
fi

echo "==> 检查电脑和小组件是不是一样（不一样就停）"
if [ "${SKIP_DRIFT_CHECK:-0}" != "1" ]; then
  if [ -x "Resources/codex/skills/codex-widget-sync/scripts/check-drift.sh" ]; then
    if ! "Resources/codex/skills/codex-widget-sync/scripts/check-drift.sh"; then
      echo "!! 检查没过，先去把两边弄成一样再打包（或 SKIP_DRIFT_CHECK=1 ./build.sh 跳过）"
      exit 1
    fi
  fi
fi

echo "==> 配额解析自检（离线 fixture；官方给配额表加装饰时会立刻报错）"
if [ "${SKIP_QUOTA_TEST:-0}" != "1" ]; then
  if [ -x "scripts/test-quota-parse.sh" ]; then
    if ! "scripts/test-quota-parse.sh"; then
      echo "!! 配额解析自检没过，先修好再打包（或 SKIP_QUOTA_TEST=1 ./build.sh 跳过）"
      exit 1
    fi
  fi
fi

echo "==> 密钥页解析自检（离线 fixture；浏览器登录自动获取依赖它）"
if [ "${SKIP_KEY_TEST:-0}" != "1" ]; then
  if [ -x "scripts/test-key-parse.sh" ]; then
    if ! "scripts/test-key-parse.sh"; then
      echo "!! 密钥解析自检没过，先修好再打包（或 SKIP_KEY_TEST=1 ./build.sh 跳过）"
      exit 1
    fi
  fi
fi

# 2026-09-23（Phase 0）：把"测试门槛"补齐 —— 以前只有上面两个解析自检，最容易翻车的
# 用量管线（日界/合并/按 Key 口径）和 Python 代理全量测试都没有进门槛。
echo "==> 用量管线自检（离线；日界 / 增量幂等 / 半窗不冲整天 / 按 Key 覆盖）"
if [ "${SKIP_PIPELINE_TEST:-0}" != "1" ] && [ -x "scripts/test-usage-pipeline.sh" ]; then
  if ! "scripts/test-usage-pipeline.sh"; then
    echo "!! 用量管线自检没过，先修好再打包（或 SKIP_PIPELINE_TEST=1 ./build.sh 跳过）"
    exit 1
  fi
fi

# 2026-09-23：代理生命周期（挑解释器/起服务/探活）也只有一份实现（ensure-proxy.sh），
# 单独验它：坏的会被跳过、全坏不写脏文件、真起一次端口要有响应、已在跑时幂等。
echo "==> 代理生命周期自检（离线；解释器挑选 / 修复 / 幂等）"
if [ "${SKIP_ENSURE_PROXY_TEST:-0}" != "1" ] && [ -x "scripts/test-ensure-proxy.sh" ]; then
  if ! "scripts/test-ensure-proxy.sh"; then
    echo "!! 代理生命周期自检没过，先修好再打包（或 SKIP_ENSURE_PROXY_TEST=1 ./build.sh 跳过）"
    exit 1
  fi
fi

echo "==> 本地代理自检（Python 全量测试 + Muse 兼容层）"
if [ "${SKIP_PROXY_TEST:-0}" != "1" ]; then
  if [ -f "Resources/codex/vision/tests/run_all_robust.py" ]; then
    if ! python3 "Resources/codex/vision/tests/run_all_robust.py" >/tmp/opencodego-proxy-tests.log 2>&1; then
      echo "!! 代理测试没过，日志：/tmp/opencodego-proxy-tests.log"
      tail -20 /tmp/opencodego-proxy-tests.log
      exit 1
    fi
  fi
  if [ -f "Resources/codex/skills/muse-codex-compat/scripts/test_muse_compat.py" ]; then
    if ! python3 "Resources/codex/skills/muse-codex-compat/scripts/test_muse_compat.py" \
          "Resources/codex/vision/vision_proxy.py" >/tmp/opencodego-muse-tests.log 2>&1; then
      echo "!! Muse 兼容自检没过，日志：/tmp/opencodego-muse-tests.log"
      tail -20 /tmp/opencodego-muse-tests.log
      exit 1
    fi
  fi
fi

if [ "$TEST_ONLY" -eq 1 ]; then
  echo "==> --test 模式：测试门槛全绿，未打包 ✅"
  exit 0
fi

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
	<key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>DTSDKName</key><string>macosx${SDKVER}</string>
	<key>DTPlatformVersion</key><string>${SDKVER}</string>
	<key>LSUIElement</key><true/>
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
	<key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
	<key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
	<key>DTPlatformName</key><string>macosx</string>
	<key>DTSDKName</key><string>macosx${SDKVER}</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSExtension</key><dict>
		<key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
	</dict>
</dict>
</plist>
PLIST

echo "==> 编译 App"
# 源码清单（2026-09-23 Phase 1/2）：主 App = Sources/ 全量（含 Views/ 子目录）；Widget = 共享部分。
# 以前两个目标各手写一长串文件名，拆文件时漏加一个就"打包时才编译失败"，现在只维护一份排除名单。
APP_ONLY_SOURCES=(
  "App" "DashboardView" "QuotaViews" "ChartViews" "SelfCheckViews" "SettingsViews" "ProxyWatchdog"
  "CodexInstaller" "CodexSetupView" "UpdateChecker" "HealthCheck" "CookieSync"
  "OpenCodeKeyFetcher" "OpenCodeLoginView"
)
ALL_SOURCES=()
SHARED_SOURCES=()
while IFS= read -r src; do
  ALL_SOURCES+=("$src")
  src_name="$(basename "$src" .swift)"
  is_app_only=0
  for only in "${APP_ONLY_SOURCES[@]}"; do
    [ "$src_name" = "$only" ] && is_app_only=1
  done
  [ "$is_app_only" = "0" ] && SHARED_SOURCES+=("$src")
done < <(find Sources -name '*.swift' | LC_ALL=C sort)

swiftc -parse-as-library -target "$TARGET" -sdk "$SDK" -swift-version 5 -module-cache-path /tmp/mcp \
  "${ALL_SOURCES[@]}" \
  -o "build/${APP_BUNDLE_NAME}.app/Contents/MacOS/${APP_NAME}"

echo "==> 编译 Widget"
swiftc -parse-as-library -application-extension -target "$TARGET" -sdk "$SDK" -swift-version 5 -module-cache-path /tmp/mcp \
  -Xlinker -e -Xlinker _NSExtensionMain \
  Widget/OpenCodeGoWidget.swift "${SHARED_SOURCES[@]}" \
  -o "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex/Contents/MacOS/${WIDGET_NAME}"

SIGN_IDENTITY="-"
SIGN_ARGS=(--sign "$SIGN_IDENTITY")
echo "!! 强制 ad-hoc 签名（保证 Dock 中文名与签名校验通过）"

echo "==> 签名 Widget"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex"
else
  codesign --force --options runtime "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex"
fi
echo "==> 签名 App (先签外壳，再单独重签 Widget 以保留沙盒)"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force "${SIGN_ARGS[@]}" --entitlements Resources/app.entitlements.plist "build/${APP_BUNDLE_NAME}.app"
  # 外壳签名后 Widget 若被覆盖，立即用沙盒配置重签
  codesign --force "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex"
else
  codesign --force --options runtime "${SIGN_ARGS[@]}" --entitlements Resources/app.entitlements.plist "build/${APP_BUNDLE_NAME}.app"
  codesign --force --options runtime "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "build/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex"
fi

echo "==> 安装到 /Applications"
rm -rf "/Applications/OpenCodeGoWidget.app"
rm -rf "/Applications/${APP_BUNDLE_NAME}.app"
ditto "build/${APP_BUNDLE_NAME}.app" "/Applications/${APP_BUNDLE_NAME}.app"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force "${SIGN_ARGS[@]}" --entitlements Resources/app.entitlements.plist "/Applications/${APP_BUNDLE_NAME}.app" 2>/dev/null || true
  codesign --force "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "/Applications/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex" 2>/dev/null || true
else
  codesign --force --options runtime "${SIGN_ARGS[@]}" --entitlements Resources/app.entitlements.plist "/Applications/${APP_BUNDLE_NAME}.app" 2>/dev/null || true
  codesign --force --options runtime "${SIGN_ARGS[@]}" --entitlements Resources/entitlements.plist "/Applications/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex" 2>/dev/null || true
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
# 桌面副本改成可选（2026-09-19）：以前每次构建都往桌面丢一份，几版下来桌面堆一片。
# 需要顺手拿一份时：COPY_TO_DESKTOP=1 ./build.sh
if [ "${COPY_TO_DESKTOP:-0}" = "1" ]; then
  DESKTOP_DMG="$HOME/Desktop/${APP_BUNDLE_NAME}-${VERSION}.dmg"
  DESKTOP_ZIP="$HOME/Desktop/${APP_BUNDLE_NAME}-${VERSION}.zip"
  if [ -f "build/${DMG_NAME}" ]; then ditto "build/${DMG_NAME}" "$DESKTOP_DMG" 2>/dev/null && echo "已拷到桌面: $DESKTOP_DMG" || true; fi
  if [ -f "build/${ZIP_NAME}" ]; then ditto "build/${ZIP_NAME}" "$DESKTOP_ZIP" 2>/dev/null && echo "已拷到桌面: $DESKTOP_ZIP" || true; fi
else
  echo "（跳过桌面副本；要的话 COPY_TO_DESKTOP=1 ./build.sh）"
fi
# 清理 build 中间产物（保留 dist）
rm -rf build

# 发布用 ASCII 资产名（2026-09-10）：中文+空格传上去会被 GitHub 压成 OpenCode.-1.1.8.7.dmg，
# README 里的 releases/latest/download/OpenCodeGoWidget-<版本>.zip 链接会 404。
RELEASE_DIR="$DIST_DIR/release"
mkdir -p "$RELEASE_DIR"
if [ -f "$DIST_DIR/${DMG_NAME}" ]; then
  ditto "$DIST_DIR/${DMG_NAME}" "$RELEASE_DIR/OpenCodeGoWidget-${VERSION}.dmg" \
    && echo "发布用 DMG: $RELEASE_DIR/OpenCodeGoWidget-${VERSION}.dmg"
fi
if [ -f "$DIST_DIR/${ZIP_NAME}" ]; then
  ditto "$DIST_DIR/${ZIP_NAME}" "$RELEASE_DIR/OpenCodeGoWidget-${VERSION}.zip" \
    && echo "发布用 ZIP: $RELEASE_DIR/OpenCodeGoWidget-${VERSION}.zip"
fi

# 注册系统服务
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/${APP_BUNDLE_NAME}.app" 2>/dev/null || true
killall pkd 2>/dev/null || true
sleep 1
pluginkit -a "/Applications/${APP_BUNDLE_NAME}.app/Contents/PlugIns/${WIDGET_NAME}.appex" 2>/dev/null || true
pluginkit -e use -p com.apple.widgetkit-extension -i "$WIDGET_BUNDLE_ID" 2>/dev/null || true

echo "完成：open /Applications/${APP_BUNDLE_NAME}.app 然后在通知中心添加小组件"
echo "可安装文件位于 dist/:"
ls -lh "$DIST_DIR" 2>&1 | tail -20
