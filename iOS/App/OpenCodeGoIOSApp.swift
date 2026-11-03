import SwiftUI
import UIKit

@main
struct OpenCodeGoIOSApp: App {
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            IOSRootView()
        }
    }
}

final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        IOSBackgroundRefresh.register()
        IOSBackgroundRefresh.schedule()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        IOSBackgroundRefresh.schedule()
    }
}
