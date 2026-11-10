import SwiftUI
import WidgetKit

/// 主题色的单一真源。写入 App Group，让 App 和小组件读同一份；
/// `@Published` 让根视图立即重建，不再需要杀进程。
@MainActor
final class IOSThemeStore: ObservableObject {
    @Published private(set) var theme: IOSColorTheme

    private let defaults: UserDefaults?

    init() {
        let defaults = UserDefaults(suiteName: PlatformConfig.appGroupID)
        self.defaults = defaults
        let raw = defaults?.string(forKey: IOSTheme.colorThemeKey)
        let resolved = IOSColorTheme(rawValue: raw ?? "") ?? .defaultTheme
        theme = resolved
        if raw != resolved.rawValue {
            defaults?.set(resolved.rawValue, forKey: IOSTheme.colorThemeKey)
        }
    }

    func select(_ theme: IOSColorTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        defaults?.set(theme.rawValue, forKey: IOSTheme.colorThemeKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
