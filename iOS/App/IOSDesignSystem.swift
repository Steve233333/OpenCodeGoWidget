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
                HStack(spacing: 8) {
                    BrandIconView(size: 24)
                    Text(title)
                        .font(.system(size: 23, weight: .bold, design: .rounded))
                        .lineLimit(1)
                }
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

struct IOSPeriodPicker: View {
    @Binding var selection: ChartAlignment

    var body: some View {
        HStack(spacing: 3) {
            option("账期", .billing)
            option("自然月", .calendar)
        }
        .padding(3)
        .background(IOSTheme.insetBackground)
        .clipShape(Capsule())
    }

    private func option(_ title: String, _ value: ChartAlignment) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.24)) {
                selection = value
            }
        } label: {
            Text(title)
                .font(.caption.weight(selection == value ? .semibold : .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(selection == value ? Color.white : Color.primary)
                .background(selection == value ? IOSTheme.brand : Color.clear)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }
}

struct IOSChannelTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(IOSTheme.brand)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(IOSTheme.brandSoft)
            .clipShape(Capsule())
    }
}

struct IOSSectionTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct IOSModelShareRow: View {
    let item: IOSModelAmount
    let total: Double

    private var share: Double {
        guard total > 0 else { return 0 }
        return min(max(item.amount / total, 0), 1)
    }

    private var tint: Color {
        item.model == ModelPalette.otherName
            ? Color.secondary.opacity(0.55)
            : ModelPalette.color(for: item.model)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(ModelPalette.displayName(item.model))
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                IOSChannelTag(text: IOSDashboardData.channelLabel(item.model))
                Spacer(minLength: 6)
                Text(String(format: "$%.3f", item.amount))
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text(String(format: "%.1f%%", share * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(IOSTheme.track)
                    Capsule()
                        .fill(tint.opacity(0.9))
                        .frame(width: max(4, geometry.size.width * share))
                }
            }
            .frame(height: 4)
        }
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
                .foregroundStyle(IOSTheme.brand)
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
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct IOSActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(IOSTheme.brand)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(IOSTheme.brandSoft)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
