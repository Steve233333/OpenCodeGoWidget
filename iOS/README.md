# OpenCode Go iOS

个人自用 iOS App + Widget Extension。只需登录 OpenCode 控制台账号，不保存或要求 Go API Key。

## 功能

- 5 小时、周、月额度与重置倒计时
- 30 天费用、按模型、按 Key、请求日志明细
- Go 全模型配额表
- 主屏小号/中号与锁屏矩形组件
- 账号登录、失效重登与本地数据清理

## 生成工程

```bash
cd iOS
xcodegen generate
open OpenCodeGoIOS.xcodeproj
```

## 签名与安装

1. Xcode → Settings → Accounts 登录 Apple ID。
2. 在 App 与 Widget 两个 target 的 Signing & Capabilities 中选择同一个 Personal Team。
3. 连接并解锁 iPhone，选择该设备运行。
4. Xcode 会自动创建 App Group 与 provisioning profiles。
5. 免费 Personal Team 通常每 7 天需要重新构建安装一次。

现有云端 `.p12` 和单 App 描述文件不是本工程所需：其固定 App ID 不覆盖独立 Widget Extension，因此不放入仓库。

## 刷新

主 App 在启动、回前台和手动刷新时同步数据。`BGAppRefreshTask` 会请求约 15 分钟后的机会性后台刷新，但执行时间由 iOS 决定。小组件只读取 App Group 中的快照；点击刷新或组件会打开 App。

## 离线检查

```bash
./iOS/check.sh
./iOS/typecheck.sh
./build.sh --test
```
