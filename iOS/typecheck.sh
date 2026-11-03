#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

COMMON=(
  "$ROOT/Sources/PlatformConfig.swift"
  "$ROOT/Sources/BillingCycle.swift"
  "$ROOT/Sources/ChartFormatters.swift"
  "$ROOT/Sources/ChartWindow.swift"
  "$ROOT/Sources/ConsoleUsageAPI.swift"
  "$ROOT/Sources/CostCrawler.swift"
  "$ROOT/Sources/GoQuotaRegistry.swift"
  "$ROOT/Sources/KeyDirectory.swift"
  "$ROOT/Sources/ModelPalette.swift"
  "$ROOT/Sources/ModelRegistry.swift"
  "$ROOT/Sources/NetworkManager.swift"
  "$ROOT/Sources/UsageCostModels.swift"
  "$ROOT/Sources/UsageMerge.swift"
  "$ROOT/Sources/UsageModels.swift"
  "$ROOT/Sources/UsagePipeline.swift"
  "$ROOT/Sources/UsageRows.swift"
  "$ROOT/Sources/WidgetDataStore.swift"
  "$ROOT/Sources/WidgetTimeline.swift"
)

APP=(
  "${COMMON[@]}"
  "$ROOT/Sources/GoQuotaChart.swift"
  "$ROOT/Sources/OpenCodeKeyFetcher.swift"
  "$ROOT/Sources/Versioning.swift"
  "$ROOT/Sources/Views/ChartViews.swift"
  "$ROOT/Sources/Views/QuotaViews.swift"
  "$ROOT/iOS/App/OpenCodeGoIOSApp.swift"
  "$ROOT/iOS/App/IOSRootView.swift"
  "$ROOT/iOS/App/IOSSessionStore.swift"
  "$ROOT/iOS/App/ConsoleAccountModel.swift"
  "$ROOT/iOS/App/ConsoleLoginWebView.swift"
  "$ROOT/iOS/App/IOSUsageRefresher.swift"
  "$ROOT/iOS/App/BackgroundRefresh.swift"
  "$ROOT/iOS/App/IOSDashboardViews.swift"
)

WIDGET=(
  "${COMMON[@]}"
  "$ROOT/iOS/App/IOSSessionStore.swift"
  "$ROOT/iOS/Widget/OpenCodeGoIOSWidget.swift"
)

echo "==> iOS App typecheck"
swiftc -typecheck -parse-as-library -target arm64-apple-ios18.0 -sdk "$SDK" -swift-version 5 "${APP[@]}"

echo "==> iOS Widget typecheck"
swiftc -typecheck -parse-as-library -application-extension -target arm64-apple-ios18.0 -sdk "$SDK" \
  -swift-version 5 "${WIDGET[@]}"

echo "iOS typecheck OK"
