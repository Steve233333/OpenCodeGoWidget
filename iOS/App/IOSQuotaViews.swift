import SwiftUI

struct IOSQuotaPage: View {
    @ObservedObject var usage: IOSUsageController

    private var sorted: [GoQuota] {
        usage.quotas.sorted { ($0.h5 ?? Int.max) < ($1.h5 ?? Int.max) }
    }

    private var ranges: [String: ClosedRange<Int>] {
        [
            "5h": range(for: \.h5),
            "week": range(for: \.weekly),
            "month": range(for: \.monthly),
        ]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                IOSPageHeader(
                    title: "配额",
                    subtitle: usage.quotaUpdatedAt.map {
                        "官方 Go 模型额度 · 更新于 \($0.formatted(date: .omitted, time: .shortened))"
                    } ?? "官方 Go 模型额度"
                )

                IOSCard(padding: 13) {
                    HStack(spacing: 14) {
                        legend("5 小时", color: quotaRed)
                        legend("周", color: quotaOrange)
                        legend("月", color: quotaGreen)
                        Spacer()
                        Text("按模型独立比较")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if sorted.isEmpty {
                    IOSEmptyState(
                        icon: "list.bullet.rectangle",
                        title: "还没有配额数据",
                        detail: "下拉刷新后会从 OpenCode 官方文档同步。"
                    )
                } else {
                    ForEach(sorted) { quota in
                        if quota.monthly == nil {
                            IOSFreeQuotaCard(quota: quota)
                        } else {
                            IOSQuotaModelCard(
                                quota: quota,
                                ranges: ranges
                            )
                        }
                    }
                }

                Text("数据同步自 opencode.ai 官方 Go 配额表；免费额度和促销倍率可能随时变化。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 80)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .background(IOSTheme.pageBackground)
        .scrollIndicators(.hidden)
        .refreshable {
            _ = await GoQuotaRegistry.refreshIfNeeded(force: true)
            usage.reloadFromStorage()
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func range(for keyPath: KeyPath<GoQuota, Int?>) -> ClosedRange<Int> {
        let values = usage.quotas.compactMap { $0[keyPath: keyPath] }.filter { $0 > 0 }
        let low = values.min() ?? 1
        let high = values.max() ?? low
        return low...max(low, high)
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct IOSQuotaModelCard: View {
    let quota: GoQuota
    let ranges: [String: ClosedRange<Int>]

    var body: some View {
        IOSCard(padding: 15) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(quota.displayName)
                            .font(.headline)
                            .lineLimit(2)
                        if let note = quota.note, !note.isEmpty {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    if let badge = quota.badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(IOSTheme.warning)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(IOSTheme.warning.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                HStack(alignment: .top, spacing: 9) {
                    IOSQuotaMetric(
                        title: "5 小时",
                        value: quota.h5,
                        color: quotaRed,
                        range: ranges["5h"]
                    )
                    IOSQuotaMetric(
                        title: "周",
                        value: quota.weekly,
                        color: quotaOrange,
                        range: ranges["week"]
                    )
                    IOSQuotaMetric(
                        title: "月",
                        value: quota.monthly,
                        color: quotaGreen,
                        range: ranges["month"]
                    )
                }
            }
        }
    }
}

private struct IOSQuotaMetric: View {
    let title: String
    let value: Int?
    let color: Color
    let range: ClosedRange<Int>?

    private var fraction: CGFloat {
        guard let value, value > 0, let range else { return 0.04 }
        guard range.upperBound > range.lowerBound else { return 0.55 }
        let low = log10(1 + Double(range.lowerBound))
        let high = log10(1 + Double(range.upperBound))
        let current = log10(1 + Double(value))
        guard high > low else { return 0.55 }
        return CGFloat(max(0.07, min(1, (current - low) / (high - low))))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(GoQuota.fmt(value ?? 0))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(IOSTheme.track)
                    Capsule()
                        .fill(color)
                        .frame(width: max(5, geometry.size.width * fraction))
                }
            }
            .frame(height: 5)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct IOSFreeQuotaCard: View {
    let quota: GoQuota

    var body: some View {
        IOSCard(padding: 15) {
            HStack(spacing: 12) {
                Text("∞")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .foregroundStyle(quotaGold)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(quota.displayName)
                        .font(.headline)
                    Text(quota.note ?? "限时免费，不计入普通配额")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("不限量")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(quotaGold)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(quotaGold.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }
}

private let quotaRed = Color(red: 0.86, green: 0.30, blue: 0.30)
private let quotaOrange = Color(red: 0.94, green: 0.55, blue: 0.14)
private let quotaGreen = Color(red: 0.18, green: 0.70, blue: 0.43)
private let quotaGold = Color(red: 0.82, green: 0.62, blue: 0.12)
