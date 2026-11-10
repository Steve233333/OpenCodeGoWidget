import SwiftUI
import UIKit

/// iOS 界面的唯一颜色与圆角来源。
///
/// 品牌色来自「色系」设置（10 个玛卡龙色），默认薄荷。额度条的三段是分类色
/// （5h / 周 / 月），是否接近上限由 `quotaColor` 单独表达。
enum IOSTheme {
    static let colorThemeKey = "ios.colorTheme"

    static var currentTheme: IOSColorTheme {
        let raw = UserDefaults(suiteName: PlatformConfig.appGroupID)?
            .string(forKey: colorThemeKey)
        return IOSColorTheme(rawValue: raw ?? "") ?? .defaultTheme
    }

    private static let ink = UIColor(red: 0.08, green: 0.09, blue: 0.07, alpha: 1)

    /// 控制/填充色：浅色是粉彩，深色是亮粉彩。
    static var brand: Color {
        let theme = currentTheme
        return adaptive(light: theme.lightTint, dark: theme.macaronLight)
    }

    /// 小面积文字/图标色：浅色压深，深色用亮粉彩。
    static var brandText: Color {
        let theme = currentTheme
        return adaptive(light: theme.lightText, dark: theme.macaronLight)
    }

    /// 浅色是粉彩 Hero，深色是深色 Hero。
    static var brandStrong: Color {
        let theme = currentTheme
        return adaptive(light: theme.lightHeroStart, dark: theme.darkHeroStart)
    }

    static var brandDeep: Color {
        let theme = currentTheme
        return adaptive(light: theme.lightHeroEnd, dark: theme.darkHeroEnd)
    }

    static var brandSoft: Color {
        let theme = currentTheme
        return adaptive(light: theme.lightSoft, dark: theme.macaronLight.withAlpha(0.16))
    }

    /// 品牌填充上的前景：粉彩底一律用深墨字。
    static var brandOn: Color {
        Color(uiColor: ink)
    }

    static var heroForeground: Color {
        adaptive(light: ink, dark: .white)
    }

    static var heroSecondary: Color {
        adaptive(light: ink.withAlpha(0.62), dark: UIColor.white.withAlpha(0.72))
    }

    static var heroMuted: Color {
        adaptive(light: ink.withAlpha(0.42), dark: UIColor.white.withAlpha(0.55))
    }

    static var heroSpark: Color {
        adaptive(light: ink.withAlpha(0.20), dark: UIColor.white.withAlpha(0.28))
    }

    static var heroSparkLast: Color {
        let theme = currentTheme
        return adaptive(light: theme.lightText, dark: theme.macaronLight)
    }

    /// 周：主色的浅一档。
    static var lime: Color {
        let theme = currentTheme
        return adaptive(
            light: theme.macaronLight.blended(with: .white, amount: 0.35),
            dark: theme.macaronLight.blended(with: .white, amount: 0.25)
        )
    }

    /// 月：主色的深一档。
    static var sand: Color {
        let theme = currentTheme
        return adaptive(
            light: theme.macaronLight.darkened(0.22),
            dark: theme.macaronLight.darkened(0.10)
        )
    }

    /// 图例里的中性色，暖灰。
    static var slate: Color {
        adaptive(
            light: UIColor(red: 0.48, green: 0.45, blue: 0.40, alpha: 1),
            dark: UIColor(red: 0.64, green: 0.61, blue: 0.55, alpha: 1)
        )
    }

    /// 限时免费分类色（金色），与 5h/周/月 三段区分开。
    static let free = adaptive(
        light: UIColor(hex: 0xC79A3F),
        dark: UIColor(hex: 0xE3BC63)
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

    static var heroGradient: LinearGradient {
        LinearGradient(
            colors: [brandStrong, brandDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 百分比文字：正常档用可读的文字色，接近上限用状态色。
    static func quotaTextColor(_ percent: Int) -> Color {
        if percent >= 80 { return danger }
        if percent >= 50 { return warning }
        return brandText
    }

    /// 进度条填充：正常档用粉彩，接近上限用状态色。
    static func quotaBarColor(_ percent: Int) -> Color {
        if percent >= 80 { return danger }
        if percent >= 50 { return warning }
        return brand
    }

    static func quotaColor(_ percent: Int) -> Color {
        quotaTextColor(percent)
    }

    // 4pt 网格。组件里尽量只引用这几个值。
    enum Radius {
        static let card: CGFloat = 20
        static let tile: CGFloat = 16
        static let control: CGFloat = 12
        static let bar: CGFloat = 4
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

/// 10 个玛卡龙色系。每个色系存：
/// - `macaronLight`：选择器里看到的粉彩色；
/// - `lightBase`：浅色模式下用于文字/按钮的深一档同色相；
/// - `darkBase`：深色模式下用于文字/按钮的粉彩同色相。
enum IOSColorTheme: String, CaseIterable, Identifiable, Equatable {
    case sakura
    case grapefruit
    case peach
    case lemon
    case pistachio
    case mint
    case seaSalt
    case periwinkle
    case taro
    case grape

    static let defaultTheme: IOSColorTheme = .mint

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sakura: return "樱花"
        case .grapefruit: return "西柚"
        case .peach: return "蜜桃"
        case .lemon: return "柠檬"
        case .pistachio: return "开心果"
        case .mint: return "薄荷"
        case .seaSalt: return "海盐"
        case .periwinkle: return "蓝莓"
        case .taro: return "香芋"
        case .grape: return "葡萄"
        }
    }

    /// 选择器里的粉彩本身。
    var macaronLight: UIColor {
        switch self {
        case .sakura: return UIColor(hex: 0xF2B8C6)
        case .grapefruit: return UIColor(hex: 0xF2A79A)
        case .peach: return UIColor(hex: 0xF4C3A1)
        case .lemon: return UIColor(hex: 0xF0DE8A)
        case .pistachio: return UIColor(hex: 0xC3D99B)
        case .mint: return UIColor(hex: 0xA8DCC8)
        case .seaSalt: return UIColor(hex: 0xAFCDE8)
        case .periwinkle: return UIColor(hex: 0xB5BCE8)
        case .taro: return UIColor(hex: 0xD0BCE4)
        case .grape: return UIColor(hex: 0xC9A8D8)
        }
    }

    /// 浅色模式的控制色：比粉彩深一点，但仍保持玛卡龙的柔和。
    var lightTint: UIColor {
        macaronLight.darkened(0.10)
    }

    /// 浅色模式的文字/图标色：压深到白底可读，只用于小面积。
    var lightText: UIColor {
        macaronLight.darkened(0.45)
    }

    /// 浅色模式的浅底。
    var lightSoft: UIColor {
        macaronLight.blended(with: .white, amount: 0.72)
    }

    /// 浅色 Hero：粉彩渐变 + 深墨字。
    var lightHeroStart: UIColor {
        macaronLight.blended(with: .white, amount: 0.04)
    }

    var lightHeroEnd: UIColor {
        macaronLight.darkened(0.16)
    }

    /// 深色 Hero：深色渐变 + 白字。
    var darkHeroStart: UIColor {
        lightText.darkened(0.10)
    }

    var darkHeroEnd: UIColor {
        lightText.darkened(0.45)
    }

    var swatch: Color {
        Color(uiColor: macaronLight)
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    func blended(with other: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else {
            return self
        }
        let t = min(max(amount, 0), 1)
        return UIColor(
            red: r1 + (r2 - r1) * t,
            green: g1 + (g2 - g1) * t,
            blue: b1 + (b2 - b1) * t,
            alpha: a1 + (a2 - a1) * t
        )
    }

    func darkened(_ amount: CGFloat) -> UIColor {
        blended(with: .black, amount: amount)
    }

    func withAlpha(_ alpha: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        return UIColor(red: r, green: g, blue: b, alpha: alpha)
    }
}

/// iOS 26 Liquid Glass；iOS 18 回退到薄材质 + 细描边。
struct IOSGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    var interactive: Bool = false
    var tint: Color? = nil

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(glass(), in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background((tint ?? .clear).opacity(0.6), in: shape)
                .overlay {
                    shape.stroke(IOSTheme.stroke, lineWidth: 0.75)
                }
        }
    }

    @available(iOS 26.0, *)
    private func glass() -> Glass {
        var value = Glass.regular
        if let tint {
            value = value.tint(tint)
        }
        if interactive {
            value = value.interactive()
        }
        return value
    }
}

extension View {
    func iosGlass<S: Shape>(
        _ shape: S,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        modifier(IOSGlassModifier(shape: shape, interactive: interactive, tint: tint))
    }
}

struct IOSCard<Content: View>: View {
    var padding: CGFloat = 16
    var radius: CGFloat = IOSTheme.Radius.card
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IOSTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(IOSTheme.stroke, lineWidth: 0.75)
            }
    }
}
