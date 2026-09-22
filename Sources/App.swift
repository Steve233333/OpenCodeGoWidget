import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WidgetKit
import Charts
import ServiceManagement

@main
struct OpenCodeGoWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        // This app has one dashboard. WindowGroup creates a new instance for
        // every external URL event, which is exactly what a widget tap sends.
        Window("OpenCode Go", id: "main") {
            DashboardView()
                // 宽度锁死 620（保持原来的排版），高度留活口：
                // 像「系统设置」那样拖上下边框就能调高矮，拉高会多显示内容而不是留白
                .frame(minWidth: 620, idealWidth: 620, maxWidth: 620,
                       minHeight: 480, idealHeight: 860, maxHeight: .infinity)
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "opencodego"))
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // 菜单栏常驻：像 DeepSeekMonitor 一样即使用户关掉窗口也继续 5 分钟后台刷
        MenuBarExtra {
            Button("打开主面板") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.keyWindow ?? NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                } else {
                    // 兜底：通过 URL 唤起主窗口
                    if let url = URL(string: "opencodego://month") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .keyboardShortcut("o")
            Divider()
            Button("检查更新…") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.keyWindow ?? NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                }
                NotificationCenter.default.post(name: .openCodeGoOpenSettings, object: nil)
                UpdateChecker.shared.check(force: true)
            }
            Divider()
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            MenuBarIconView()
        }
    }
}


struct MenuBarIconView: View {
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                let _ = img.isTemplate = true
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            } else if let nsImg = NSImage(named: "MenuBarIcon") {
                let _ = nsImg.isTemplate = true
                Image(nsImage: nsImg)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "chart.bar.fill")
            }
        }
        .frame(width: 16, height: 16)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 默认开机启动：首次启动即注册，失败静默
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            if service.status != .enabled {
                do {
                    try service.register()
                } catch {
                    print("LoginItem register failed: \(error)")
                }
            }
        }
        // 非 SMAppService 回退（旧系统）由系统登录项手动添加
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) ?? NSApp.keyWindow ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
