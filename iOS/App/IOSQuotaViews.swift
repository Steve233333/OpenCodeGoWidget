import SwiftUI

struct IOSQuotaPage: View {
    @ObservedObject var usage: IOSUsageController
    @AppStorage("goQuotaPlan") private var selectedPlanRaw = GoPlan.go.rawValue

    private var selectedPlan: GoPlan {
        GoPlan(rawValue: selectedPlanRaw) ?? .go
    }

    private var planBinding: Binding<GoPlan> {
        Binding(
            get: { selectedPlan },
            set: { selectedPlanRaw = $0.rawValue }
        )
    }

    private var paid: [GoQuota] {
        usage.quotas
            .filter { !$0.isUnlimited && $0.requests5h(for: selectedPlan) != nil }
            .sorted {
                let l = $0.requests5h(for: selectedPlan) ?? Int.max
                let r = $1.requests5h(for: selectedPlan) ?? Int.max
                return l == r ? $0.displayName < $1.displayName : l < r
            }
    }

    private var free: [GoQuota] {
        usage.quotas.filter(\.isUnlimited)
    }

    private var maximumRequests: Int {
        paid.compactMap { $0.requests5h(for: selectedPlan) }.max() ?? 1
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

                IOSSectionHeader(title: "模型配额")

                Picker("套餐", selection: planBinding) {
                    ForEach(GoPlan.allCases) { plan in
                        Text(plan.displayName).tag(plan)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text("5 小时请求来自官方 Console 的估算；月额度是当前套餐的美元 usage 上限。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                if paid.isEmpty && free.isEmpty {
                    IOSEmptyState(
                        icon: "list.bullet.rectangle",
                        title: "还没有配额数据",
                        detail: "下拉刷新后会从 OpenCode 官方 Console 同步。"
                    )
                } else {
                    IOSCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(paid.enumerated()), id: \.offset) { pair in
                                IOSQuotaModelRow(
                                    quota: pair.element,
                                    plan: selectedPlan,
                                    maximumRequests: maximumRequests
                                )
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

                Text("数据同步自 opencode.ai/console/go；Go 与 Go Plus 使用各自额度。")
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

}

struct IOSQuotaModelRow: View {
    let quota: GoQuota
    let plan: GoPlan
    let maximumRequests: Int

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
                Text("\(quota.monthlyDisplay(for: plan)) / 月")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            IOSQuotaBar(
                value: quota.requests5h(for: plan) ?? 0,
                maximum: maximumRequests,
                tint: plan == .go ? IOSTheme.brand : IOSTheme.warning
            )
                .frame(height: 6)

            HStack(spacing: 0) {
                Text("\(quota.requests5hDisplay(for: plan)) 次 / 5h")
                Text(" · \(quota.monthlyDisplay(for: plan)) / 月")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(quota.displayName)，\(plan.displayName)，5 小时估算 \(quota.requests5hDisplay(for: plan)) 次，月额度 \(quota.monthlyDisplay(for: plan))"
        )
    }
}

struct IOSQuotaBar: View {
    let value: Int
    let maximum: Int
    let tint: Color

    private var barLength: CGFloat {
        guard value > 0, maximum > 0 else { return 0 }
        let valueLog = log10(1 + Double(value))
        let maximumLog = log10(1 + Double(maximum))
        guard maximumLog > 0 else { return 1 }
        return CGFloat(max(0.04, min(1, valueLog / maximumLog)))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(IOSTheme.track)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.65), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(4, geometry.size.width * barLength))
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
