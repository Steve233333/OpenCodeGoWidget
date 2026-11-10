import SwiftUI

struct IOSQuotaPage: View {
    @ObservedObject var usage: IOSUsageController

    private var sorted: [GoQuota] {
        usage.quotas.sorted { lhs, rhs in
            let l = lhs.h5 ?? Int.max
            let r = rhs.h5 ?? Int.max
            if l != r { return l < r }
            return lhs.displayName < rhs.displayName
        }
    }

    private var paid: [GoQuota] {
        sorted.filter { $0.monthly != nil }
    }

    private var free: [GoQuota] {
        sorted.filter { $0.monthly == nil }
    }

    /// 与 Mac 版一致：以最低档为基线，用 log10 拉开低档模型的差异。
    private var monthlyBaseline: Int {
        paid.compactMap(\.monthly).filter { $0 > 0 }.min() ?? 490
    }

    private var monthlyMaximum: Int {
        paid.compactMap(\.monthly).filter { $0 > 0 }.max() ?? monthlyBaseline
    }

    private var subtitle: String {
        if let updated = usage.quotaUpdatedAt {
            return "官方 Go 模型配额 · 更新于 \(updated.formatted(date: .omitted, time: .shortened))"
        }
        return "官方 Go 模型配额"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                IOSPageHeader(title: "配额", subtitle: subtitle)

                if let snapshot = usage.snapshot {
                    IOSQuotaFocusTile(
                        label: "5 小时",
                        percent: snapshot.rolling,
                        reset: snapshot.rollingReset
                    )
                    HStack(spacing: 10) {
                        IOSQuotaMiniTile(
                            label: "周",
                            percent: snapshot.weekly,
                            reset: snapshot.weeklyReset
                        )
                        IOSQuotaMiniTile(
                            label: "月",
                            percent: snapshot.monthly,
                            reset: snapshot.monthlyReset
                        )
                    }
                } else {
                    IOSEmptyState(
                        icon: "gauge.with.dots.needle.50percent",
                        title: "同步后显示已用比例",
                        detail: "配额表已缓存；登录并同步后显示 5 小时、周、月三档已用。"
                    )
                }

                IOSSectionHeader(title: "模型配额") {
                    HStack(spacing: 9) {
                        legend("5h", IOSTheme.brand)
                        legend("周", IOSTheme.lime)
                        legend("月", IOSTheme.sand)
                        if !free.isEmpty {
                            legend("免费", IOSTheme.free)
                        }
                    }
                }

                Text("三段条 = 5h / 周 / 月请求数上限；长度为对数刻度。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if sorted.isEmpty {
                    IOSEmptyState(
                        icon: "list.bullet.rectangle",
                        title: "还没有配额数据",
                        detail: "下拉刷新后会从 OpenCode 官方文档同步。"
                    )
                } else {
                    IOSCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(paid.enumerated()), id: \.offset) { pair in
                                IOSQuotaModelRow(quota: pair.element, monthlyBaseline: monthlyBaseline, monthlyMaximum: monthlyMaximum)
                                    .padding(.horizontal, 16)
                                if pair.offset < paid.count - 1 || !free.isEmpty {
                                    divider
                                }
                            }

                            ForEach(Array(free.enumerated()), id: \.offset) { pair in
                                IOSQuotaFreeRow(quota: pair.element)
                                    .padding(.horizontal, 16)
                                if pair.offset < free.count - 1 {
                                    divider
                                }
                            }
                        }
                    }
                }

                Text("数据同步自 opencode.ai/docs/zh-cn/go/ 配额表；免费模型和促销倍率以官网为准。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 96)
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
            .padding(.leading, 16)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

struct IOSQuotaModelRow: View {
    let quota: GoQuota
    let monthlyBaseline: Int
    let monthlyMaximum: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(quota.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let badge = quota.badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(IOSTheme.warning)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(IOSTheme.warning.opacity(0.12))
                        .clipShape(Capsule())
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("月 \(GoQuota.fmt(quota.monthly ?? 0))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            IOSQuotaBar(quota: quota, monthlyBaseline: monthlyBaseline, monthlyMaximum: monthlyMaximum)
                .frame(height: 6)

            HStack(spacing: 0) {
                Text("5h \(GoQuota.fmt(quota.h5 ?? 0))")
                Text(" · 周 \(GoQuota.fmt(quota.weekly ?? 0))")
                Text(" · 月 \(GoQuota.fmt(quota.monthly ?? 0))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(quota.displayName)，5 小时 \(GoQuota.fmt(quota.h5 ?? 0))，周 \(GoQuota.fmt(quota.weekly ?? 0))，月 \(GoQuota.fmt(quota.monthly ?? 0))"
        )
    }
}

struct IOSQuotaBar: View {
    let quota: GoQuota
    let monthlyBaseline: Int
    let monthlyMaximum: Int

    /// Mac 版同款：以最低月配额为基线做 log10，最低保留 12% 可见长度。
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
                Capsule()
                    .fill(IOSTheme.track)
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(IOSTheme.brand)
                        .frame(width: h5Width)
                    Rectangle()
                        .fill(IOSTheme.lime)
                        .frame(width: weeklyOnlyWidth)
                    Rectangle()
                        .fill(IOSTheme.sand)
                        .frame(width: monthlyOnlyWidth)
                }
                .frame(width: totalWidth, alignment: .leading)
                .clipShape(Capsule())
            }
        }
    }
}

struct IOSQuotaFreeRow: View {
    let quota: GoQuota

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(quota.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("限时免费")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(IOSTheme.free)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(IOSTheme.free.opacity(0.12))
                    .clipShape(Capsule())
            }
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [IOSTheme.free.opacity(0.55), IOSTheme.free],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 6)
            Text("不限量 · 以官网为准")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(quota.displayName)，限时免费，不限量")
    }
}
