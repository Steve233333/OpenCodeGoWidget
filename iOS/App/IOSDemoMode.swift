#if DEBUG
import Foundation

/// 仅 Debug：`-demo` 启动参数进入带演示数据的界面，用于模拟器截图。
enum IOSDemoMode {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-demo")
    }

    static var isWidgetPreviewEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-widget-preview")
    }
}
#endif
