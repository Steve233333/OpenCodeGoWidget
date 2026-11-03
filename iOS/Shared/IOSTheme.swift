import SwiftUI
import UIKit

enum IOSTheme {
    static let brand = adaptive(
        light: UIColor(red: 0.15, green: 0.53, blue: 0.33, alpha: 1),
        dark: UIColor(red: 0.45, green: 0.84, blue: 0.60, alpha: 1)
    )

    static let brandSoft = adaptive(
        light: UIColor(red: 0.15, green: 0.53, blue: 0.33, alpha: 0.12),
        dark: UIColor(red: 0.45, green: 0.84, blue: 0.60, alpha: 0.16)
    )

    static let warning = adaptive(
        light: UIColor(red: 0.82, green: 0.49, blue: 0.12, alpha: 1),
        dark: UIColor(red: 0.98, green: 0.67, blue: 0.28, alpha: 1)
    )

    static let danger = adaptive(
        light: UIColor(red: 0.78, green: 0.27, blue: 0.25, alpha: 1),
        dark: UIColor(red: 0.95, green: 0.44, blue: 0.40, alpha: 1)
    )

    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let insetBackground = Color.primary.opacity(0.045)
    static let track = Color.primary.opacity(0.09)
    static let stroke = Color.primary.opacity(0.075)
    static let secondaryText = Color.secondary

    static func quotaColor(_ percent: Int) -> Color {
        if percent >= 80 { return danger }
        if percent >= 50 { return warning }
        return brand
    }

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

struct IOSCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IOSTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(IOSTheme.stroke, lineWidth: 0.75)
            }
    }
}
