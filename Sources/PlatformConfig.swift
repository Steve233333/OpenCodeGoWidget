import Foundation

/// Platform-specific identities shared by networking, cache and WidgetKit code.
enum PlatformConfig {
#if os(iOS)
    static let appGroupID: String = {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "OpenCodeAppGroupID") as? String
        return bundled?.isEmpty == false
            ? bundled!
            : "group.com.steve233.opencodego.ios"
    }()
    static let widgetKind = "OpenCodeGoWidgetIOS"
    static let appBundleID = "com.steve233.opencodego.ios"
    static let backgroundRefreshID = "com.steve233.opencodego.ios.refresh"
#else
    static let appGroupID = "2DC432GLL2.com.steve233.opencodego"
    static let widgetKind = "OpenCodeGoWidget"
    static let appBundleID = "com.steve233.opencodego"
    static let backgroundRefreshID = "com.steve233.opencodego.refresh"
#endif
}

/// The data layer in both targets asks this helper for console credentials.
/// macOS keeps its existing App Group storage; iOS reads the login secret only
/// from Keychain and never duplicates it into the shared widget preferences.
enum ConsoleCredentials {
    /// iOS App 仍只从 Keychain 读；小组件扩展读 App Group 里的镜像副本，
    /// 这样它可以在 App 不在前台/没被后台唤醒时自己刷新额度。
    private static var isWidgetExtension: Bool {
        Bundle.main.bundleIdentifier == "com.steve233.opencodego.ios.widget"
    }

    static func auth(defaults: UserDefaults? = UserDefaults(suiteName: PlatformConfig.appGroupID)) -> String {
#if os(iOS)
        if isWidgetExtension {
            return defaults?.string(forKey: "widgetAuthCookie") ?? ""
        }
        return IOSSessionStore.load()?.authCookie ?? ""
#else
        return defaults?.string(forKey: "authCookie") ?? ""
#endif
    }

    static func session(defaults: UserDefaults? = UserDefaults(suiteName: PlatformConfig.appGroupID)) -> String {
#if os(iOS)
        if isWidgetExtension {
            return defaults?.string(forKey: "widgetConsoleSession") ?? ""
        }
        return IOSSessionStore.load()?.consoleSession ?? ""
#else
        return defaults?.string(forKey: "consoleSession") ?? ""
#endif
    }

    static func workspace(defaults: UserDefaults? = UserDefaults(suiteName: PlatformConfig.appGroupID)) -> String {
        defaults?.string(forKey: "workspaceID") ?? ""
    }
}
