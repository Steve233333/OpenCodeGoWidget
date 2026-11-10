import SwiftUI

struct IOSPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(IOSTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

/// 2 选 1 的胶囊分段；选中态用 `brandOn`，深色模式下不会出现白字压浅绿。
struct IOSPeriodPicker: View {
    @Binding var selection: ChartAlignment

    var body: some View {
        HStack(spacing: 2) {
            option("账期", .billing)
            option("自然月", .calendar)
        }
        .padding(3)
        .frame(minHeight: 44)
        .iosGlass(Capsule(), tint: IOSTheme.brand.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    private func option(_ title: String, _ value: ChartAlignment) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                selection = value
            }
        } label: {
            Text(title)
                .font(.system(size: 13, weight: selection == value ? .semibold : .medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .foregroundStyle(selection == value ? IOSTheme.brandOn : Color.primary)
                .background(selection == value ? IOSTheme.brand : Color.clear)
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}

struct IOSChannelTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(IOSTheme.brandText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(IOSTheme.brandSoft)
            .clipShape(Capsule())
            .lineLimit(1)
    }
}

struct IOSSectionTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 一屏里真正的分区标题（比卡片内标题大一级）。
struct IOSSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Spacer(minLength: 6)
            trailing()
        }
    }
}

struct IOSModelShareRow: View {
    let item: IOSModelAmount
    let total: Double
    let tint: Color

    private var share: Double {
        guard total > 0 else { return 0 }
        return min(max(item.amount / total, 0), 1)
    }

    private var channel: String {
        IOSDashboardData.channelLabel(item.model)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(ModelPalette.displayName(item.model))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                if channel != "Go" {
                    IOSChannelTag(text: channel)
                }
                Spacer(minLength: 6)
                Text(String(format: "$%.2f", item.amount))
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text(String(format: "%.0f%%", share * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            IOSProgressBar(percent: Int((share * 100).rounded()), tint: tint.opacity(0.9), height: 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(ModelPalette.displayName(item.model))，\(String(format: "%.2f", item.amount)) 美元，占 \(Int((share * 100).rounded()))%"
        )
    }
}

struct IOSProgressBar: View {
    let percent: Int
    var tint: Color = IOSTheme.brand
    var height: CGFloat = 4

    private var clamped: Double {
        Double(min(max(percent, 0), 100)) / 100
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(IOSTheme.track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(3, geometry.size.width * clamped))
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("已用 \(min(max(percent, 0), 100))%")
    }
}

enum IOSResetText {
    static func relative(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days) 天后重置" }
        if hours > 0 { return "\(hours) 小时 \(minutes) 分后重置" }
        if minutes > 0 { return "\(minutes) 分后重置" }
        return "即将重置"
    }

    static func short(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days) 天" }
        if hours > 0 { return "\(hours) 小时" }
        return "\(minutes) 分"
    }
}

struct IOSEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(IOSTheme.brandText)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(IOSTheme.insetBackground)
        .clipShape(RoundedRectangle(cornerRadius: IOSTheme.Radius.tile, style: .continuous))
    }
}

struct IOSActionButtonStyle: ButtonStyle {
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        content(configuration)
    }

    @ViewBuilder
    private func content(_ configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(filled ? IOSTheme.brandOn : IOSTheme.brandText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minWidth: 44, minHeight: 44)
            .opacity(configuration.isPressed ? 0.7 : 1)

        if filled {
            label
                .background(IOSTheme.brand)
                .clipShape(Capsule())
        } else {
            label.iosGlass(Capsule(), interactive: true, tint: IOSTheme.brand.opacity(0.16))
        }
    }
}
