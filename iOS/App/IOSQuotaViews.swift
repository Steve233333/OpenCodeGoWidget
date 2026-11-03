import SwiftUI

struct IOSQuotaPage: View {
    @ObservedObject var usage: IOSUsageController

    private var sorted: [GoQuota] {
        usage.quotas.sorted { ($0.h5 ?? Int.max) < ($1.h5 ?? Int.max) }
    }

    private var monthlyBaseline: Int {
        sorted.compactMap(\.monthly).filter { $0 > 0 }.min() ?? 490
    }

    private var monthlyMaximum: Int {
        sorted.compactMap(\.monthly).filter { $0 > 0 }.max() ?? monthlyBaseline
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

                if sorted.isEmpty {
                    IOSEmptyState(
                        icon: "list.bullet.rectangle",
                        title: "还没有配额数据",
                        detail: "下拉刷新后会从 OpenCode 官方文档同步。"
                    )
                } else {
                    IOSCard(padding: 12) {
                        VStack(alignment: .leading, spacing: 0) {
                            IOSMacQuotaHeader(
                                containsFreeModels: sorted.contains { $0.monthly == nil }
                            )
                            divider

                            ForEach(Array(sorted.enumerated()), id: \.element.id) { index, quota in
                                IOSMacQuotaRow(
                                    quota: quota,
                                    monthlyBaseline: monthlyBaseline,
                                    monthlyMaximum: monthlyMaximum
                                )
                                if index < sorted.count - 1 {
                                    divider
                                }
                            }
                        }
                    }
                }

                Text("数据实时同步自 opencode.ai/docs/zh-cn/go/ 配额表；免费模型和促销倍率以官网为准。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)

                Color.clear.frame(height: 80)
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

    private var divider: some View {
        Rectangle()
            .fill(IOSTheme.stroke)
            .frame(height: 0.5)
    }
}

private struct IOSMacQuotaHeader: View {
    let containsFreeModels: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Go 配额（每 5h / 周 / 月）")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                legend("5h", color: quotaRed)
                legend("周", color: quotaOrange)
                legend("月", color: quotaGreen)
                if containsFreeModels {
                    legend("免费", color: quotaGold)
                }
            }

            HStack(spacing: 7) {
                Text("模型")
                    .frame(width: 138, alignment: .leading)
                Text("请求数（嵌套三段）")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("周 / 月")
                    .frame(width: 74, alignment: .leading)
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .padding(.bottom, 8)
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }
}

private struct IOSMacQuotaRow: View {
    let quota: GoQuota
    let monthlyBaseline: Int
    let monthlyMaximum: Int

    var body: some View {
        if quota.monthly == nil {
            freeRow.frame(height: 31)
        } else {
            paidRow.frame(height: 31)
        }
    }

    private var paidRow: some View {
        HStack(spacing: 7) {
            HStack(spacing: 5) {
                Text(GoQuota.fmt(quota.h5 ?? 0))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
                    .lineLimit(1)
                Text(quota.displayName)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let badge = quota.badge {
                    Text(badge)
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(IOSTheme.warning)
                        .lineLimit(1)
                }
            }
            .frame(width: 138, alignment: .leading)

            IOSMacNestedBar(
                quota: quota,
                monthlyBaseline: monthlyBaseline,
                monthlyMaximum: monthlyMaximum
            )
            .frame(height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text("周 \(GoQuota.fmt(quota.weekly ?? 0))")
                Text("月 \(GoQuota.fmt(quota.monthly ?? 0))")
            }
            .font(.system(size: 8).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .frame(width: 74, alignment: .leading)
        }
    }

    private var freeRow: some View {
        HStack(spacing: 7) {
            HStack(spacing: 5) {
                Text("∞")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(quotaGold)
                    .frame(width: 38, alignment: .trailing)
                Text(quota.displayName)
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 138, alignment: .leading)

            Text("免费拉满")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 6)
                .frame(height: 8)
                .background(
                    LinearGradient(
                        colors: [Color(red: 1, green: 0.82, blue: 0.06), quotaGold],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .clipShape(Capsule())

            VStack(alignment: .leading, spacing: 1) {
                Text("限时免费")
                Text("∞")
            }
            .font(.system(size: 8))
            .foregroundStyle(quotaGold)
            .frame(width: 74, alignment: .leading)
        }
    }
}

private struct IOSMacNestedBar: View {
    let quota: GoQuota
    let monthlyBaseline: Int
    let monthlyMaximum: Int

    private var monthlyLength: CGFloat {
        guard let monthly = quota.monthly, monthly > 0 else { return 0 }
        guard monthlyMaximum > monthlyBaseline else { return 1 }
        let value = log10(1 + Double(monthly) / Double(max(1, monthlyBaseline)))
        let maximum = log10(1 + Double(monthlyMaximum) / Double(max(1, monthlyBaseline)))
        guard maximum > 0 else { return 1 }
        return CGFloat(max(0.12, min(1, value / maximum)))
    }

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width * monthlyLength
            let monthly = max(1, quota.monthly ?? 1)
            let h5Width = totalWidth * CGFloat(quota.h5 ?? 0) / CGFloat(monthly)
            let weeklyOnlyWidth = totalWidth
                * CGFloat(max(0, (quota.weekly ?? 0) - (quota.h5 ?? 0)))
                / CGFloat(monthly)
            let monthlyOnlyWidth = max(0, totalWidth - h5Width - weeklyOnlyWidth)

            ZStack(alignment: .leading) {
                Capsule().fill(IOSTheme.track)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(quotaRed)
                        .frame(width: h5Width)
                    Rectangle()
                        .fill(quotaOrange)
                        .frame(width: weeklyOnlyWidth)
                    Rectangle()
                        .fill(quotaGreen)
                        .frame(width: monthlyOnlyWidth)
                }
                .frame(width: totalWidth, alignment: .leading)
                .clipShape(Capsule())
            }
        }
    }
}

private let quotaRed = Color(red: 0.86, green: 0.30, blue: 0.30)
private let quotaOrange = Color(red: 0.94, green: 0.55, blue: 0.14)
private let quotaGreen = Color(red: 0.18, green: 0.70, blue: 0.43)
private let quotaGold = Color(red: 0.82, green: 0.62, blue: 0.12)
