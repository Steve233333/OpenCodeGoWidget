import SwiftUI

enum ModelPalette {
    // 截图图例顺序 17 模型（与 opencode.ai usage 页一致）
    static let ordered: [String] = [
        "deepseek-v4-flash",
        "deepseek-v4-flash-vision-exp",
        "deepseek-v4-pro",
        "glm-5",
        "glm-5.1",
        "glm-5.2",
        "glm-5.3",
        "gpt-5.6-luna",
        "grok-4.5",
        "hy3",
        "kimi-k2.6",
        "kimi-k2.7-code",
        "mimo-v2.5",
        "mimo-v2.5-pro",
        "minimax-m2.7",
        "minimax-m3",
        "muse-spark-1.2-contributor"
    ]

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
        "kimi-k2.6": Color(red: 0.68, green: 0.92, blue: 0.80), // 薄荷
        "kimi-k2.7-code": Color(red: 0.72, green: 0.68, blue: 0.92), // 紫
        "mimo-v2.5": Color(red: 0.62, green: 0.88, blue: 0.82), // 青绿
        "mimo-v2.5-pro": Color(red: 0.72, green: 0.78, blue: 0.92),
        "minimax-m2.7": Color(red: 0.78, green: 0.72, blue: 0.92),
        "minimax-m3": Color(red: 0.92, green: 0.72, blue: 0.82),
        "muse-spark-1.2-contributor": Color(red: 0.72, green: 0.92, blue: 0.72), // 截图中最高的淡绿
        // 兼容旧模型名别名
        "muse-spark": Color(red: 0.72, green: 0.92, blue: 0.72),
        "deepseek": Color(red: 0.90, green: 0.90, blue: 0.68),
        "mimo": Color(red: 0.62, green: 0.88, blue: 0.82),
        "glm": Color(red: 0.92, green: 0.62, blue: 0.62),
        "kimi": Color(red: 0.68, green: 0.92, blue: 0.80),
        "minimax": Color(red: 0.78, green: 0.72, blue: 0.92),
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

// 图例换行视图，供 App 与 Widget 共用
struct WrappingLegendView: View {
    let models: [String]
    var body: some View {
        // 使用 LazyVGrid 近似流式布局，兼容 Widget 的有限宽度
        let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(models, id: \.self) { m in
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
            }
        }
    }
}
