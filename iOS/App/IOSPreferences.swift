import SwiftUI

enum IOSPreferences {
    static let autoRefreshKey = "ios.autoRefreshEnabled"
    static let backgroundRefreshKey = "ios.backgroundRefreshEnabled"
    static let appearanceKey = "ios.appearance"

    static var autoRefreshEnabled: Bool {
        UserDefaults.standard.object(forKey: autoRefreshKey) as? Bool ?? true
    }

    static var backgroundRefreshEnabled: Bool {
        UserDefaults.standard.object(forKey: backgroundRefreshKey) as? Bool ?? true
    }
}

enum IOSAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
