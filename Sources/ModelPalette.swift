import SwiftUI

enum ModelPalette {
    // Go 套餐模型顺序：实时同步 https://opencode.ai/zen/go/v1/models
    // 首屏直接读 App Group 缓存（ModelRegistry），无网回退到硬编码全量 30 项
    static var ordered: [String] {
        ModelRegistry.cachedOrderedSync()
    }
    // 硬编码回退（与 ModelRegistry.fallbackOrdered 同源，保留兼容）
    static let fallbackOrdered: [String] = ModelRegistry.fallbackOrdered

    // 为每个模型分配与截图相近的淡色系，确保相邻色可区分
    static let mapping: [String: Color] = [
        "deepseek-v4-flash": Color(red: 0.90, green: 0.90, blue: 0.68), // 淡黄
        "deepseek-v4-flash-vision-exp": Color(red: 0.92, green: 0.82, blue: 0.68), // 桃
        "deepseek-v4-pro": Color(red: 0.72, green: 0.68, blue: 0.88), // 薰衣草
        "glm-5": Color(red: 0.98, green: 0.68, blue: 0.68), // 浅粉
        "glm-5.1": Color(red: 0.95, green: 0.65, blue: 0.65),
        "glm-5.2": Color(red: 0.92, green: 0.62, blue: 0.62),
        "glm-5.3": Color(red: 0.88, green: 0.60, blue: 0.58),
        "gpt-5.6-luna": Color(red: 0.68, green: 0.80, blue: 0.92), // 淡蓝
        "grok-4.5": Color(red: 0.85, green: 0.78, blue: 0.62), // 米褐
        "hy3": Color(red: 0.88, green: 0.88, blue: 0.62),
        "hy3-preview": Color(red: 0.92, green: 0.88, blue: 0.50), // Hy 预览 黄
        "kimi-k2.5": Color(red: 0.70, green: 0.90, blue: 0.75),
        "kimi-k2.6": Color(red: 0.68, green: 0.92, blue: 0.80), // 薄荷
        "kimi-k2.7-code": Color(red: 0.72, green: 0.68, blue: 0.92), // 紫
        "kimi-k3": Color(red: 0.60, green: 0.72, blue: 0.95), // K3 深蓝
        "mimo-v2.5": Color(red: 0.62, green: 0.88, blue: 0.82), // 青绿
        "mimo-v2.5-pro": Color(red: 0.72, green: 0.78, blue: 0.92),
        "mimo-v2-pro": Color(red: 0.58, green: 0.80, blue: 0.88),
        "mimo-v2-omni": Color(red: 0.66, green: 0.84, blue: 0.90),
        "minimax-m2.5": Color(red: 0.80, green: 0.70, blue: 0.90),
        "minimax-m2.7": Color(red: 0.78, green: 0.72, blue: 0.92),
        "minimax-m3": Color(red: 0.92, green: 0.72, blue: 0.82),
        "muse-spark-1.2-contributor": Color(red: 0.72, green: 0.92, blue: 0.72), // 截图中最高的淡绿
        "muse-spark-1.3-contributor": Color(red: 0.62, green: 0.88, blue: 0.70), // 1.3 略深一档，与 1.2 区分
        "qwen3.5-plus": Color(red: 0.75, green: 0.80, blue: 0.95),
        "qwen3.6-plus": Color(red: 0.70, green: 0.78, blue: 0.94),
        "qwen3.7-plus": Color(red: 0.65, green: 0.76, blue: 0.92),
        "qwen3.7-max": Color(red: 0.60, green: 0.70, blue: 0.90),
        "qwen3.8-max": Color(red: 0.55, green: 0.68, blue: 0.88),
        "ox-alpha-free": Color(red: 0.45, green: 0.85, blue: 0.45), // 限时免费 亮绿
        // 兼容旧模型名别名
        "muse-spark": Color(red: 0.72, green: 0.92, blue: 0.72),
        "deepseek": Color(red: 0.90, green: 0.90, blue: 0.68),
        "mimo": Color(red: 0.62, green: 0.88, blue: 0.82),
        "glm": Color(red: 0.92, green: 0.62, blue: 0.62),
        "kimi": Color(red: 0.68, green: 0.92, blue: 0.80),
        "minimax": Color(red: 0.78, green: 0.72, blue: 0.92),
        "qwen": Color(red: 0.65, green: 0.76, blue: 0.92),
        "hy": Color(red: 0.88, green: 0.88, blue: 0.62),
        "ox": Color(red: 0.45, green: 0.85, blue: 0.45),
    ]

    static func color(for model: String) -> Color {
        let key = model.lowercased()
        // 精确匹配优先
        if let c = mapping[key] { return c }
        // 子串匹配（处理带 -go 后缀或版本差异）
        for (k, c) in mapping where key.contains(k) {
            return c
        }
        // 兜底：按 hash 生成柔和色，避免撞色
        let h = Double(abs(model.hashValue) % 360) / 360.0
        return Color(hue: h, saturation: 0.55, brightness: 0.88)
    }

    static func shortName(_ model: String) -> String {
        model.replacingOccurrences(of: " (go)", with: "").replacingOccurrences(of: "-go", with: "")
    }
}

struct DayModelCost: Identifiable {
    let id = UUID()
    let date: Date
    let model: String
    let cost: Double
}

enum ChartFormatters {
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()
    static let monthLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月 dd"
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()
    static let billingLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()
    static let weekLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/dd"
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()
}

// 品牌方环图标（深浅色自适应，用户提供的两张 PNG）
struct BrandIconView: View {
    @Environment(\.colorScheme) var colorScheme
    var size: CGFloat = 14
    private var imageName: String {
        // 用在浅色模式.png 为白外框（浅色），用在深色模式.png 为黑外框（深色）
        // Bundle.main 在 App 与 Widget appex 中指向各自 bundle，需确保图片已拷贝到两处 Resources
        colorScheme == .dark ? "BrandDark" : "BrandLight"
    }
    var body: some View {
        Group {
            if let path = Bundle.main.path(forResource: imageName, ofType: "png"),
               let nsImg = NSImage(contentsOfFile: path) {
                Image(nsImage: nsImg)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                // 回退：若资源缺失，显示之前的自绘方环，避免空白
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
                        .fill(colorScheme == .dark ? Color.black : Color.white)
                    RoundedRectangle(cornerRadius: size * 0.05, style: .continuous)
                        .fill(Color(red: 0.32, green: 0.45, blue: 0.49))
                        .frame(width: size * 0.46, height: size * 0.62)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12, style: .continuous))
    }
}

// 图例换行视图，主 App 用（一次性全画，避免 ScrollView 里 LazyVGrid 可视区误算留白）
struct WrappingLegendView: View {
    let models: [String]
    var body: some View {
        // 注意：主 App 纵向 ScrollView 里 LazyVGrid 会在窗口恢复滚动位置时误算可视区，
        // 导致图例只画出前几格、上下拉一下才补全；SwiftUI 没有非 Lazy 的 VGrid，
        // 故用 HStack 手动按 4 列分页一次全画（30 多项内存可忽略），禁用懒加载。
        let cols = 4
        let rows = (models.count + cols - 1) / cols
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(0..<cols, id: \.self) { c in
                        let idx = r * cols + c
                        if idx < models.count {
                            let m = models[idx]
                            HStack(spacing: 4) {
                                Rectangle()
                                    .fill(ModelPalette.color(for: m))
                                    .frame(width: 12, height: 8)
                                    .clipShape(RoundedRectangle(cornerRadius: 2))
                                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                                Text(ModelPalette.shortName(m) + " (go)")
                                    .font(.system(size: 9))
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}
