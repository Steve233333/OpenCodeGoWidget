import Foundation
import SwiftUI

struct GoQuotaChart: View {
    let quotas: [GoQuota]
    var updatedAt: Date? = nil

    @AppStorage("goQuotaPlan") private var selectedPlanRaw = GoPlan.go.rawValue

    private let planBlue = Color(red: 0.33, green: 0.56, blue: 0.92)
    private let planGold = Color(red: 0.78, green: 0.61, blue: 0.28)
    private let freeTop = Color(red: 1.0, green: 0.84, blue: 0.0)
    private let freeBottom = Color(red: 0.85, green: 0.65, blue: 0.13)

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
        quotas
            .filter { !$0.isUnlimited && $0.requests5h(for: selectedPlan) != nil }
            .sorted {
                let l = $0.requests5h(for: selectedPlan) ?? Int.max
                let r = $1.requests5h(for: selectedPlan) ?? Int.max
                return l == r ? $0.displayName < $1.displayName : l < r
            }
    }

    private var free: [GoQuota] {
        quotas.filter(\.isUnlimited)
    }

    private var maxRequests: Int {
        paid.compactMap { $0.requests5h(for: selectedPlan) }.max() ?? 1
    }

    private var barTint: Color {
        selectedPlan == .go ? planBlue : planGold
    }

    private func barRatio(for value: Int) -> CGFloat {
        guard value > 0, maxRequests > 0 else { return 0 }
        let valueLog = log10(1 + Double(value))
        let maximumLog = log10(1 + Double(maxRequests))
        return maximumLog > 0 ? CGFloat(max(0.04, valueLog / maximumLog)) : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                Text("Go 模型额度")
                    .font(.caption.weight(.semibold))
                Picker("套餐", selection: planBinding) {
                    ForEach(GoPlan.allCases) { plan in
                        Text(plan.displayName).tag(plan)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                Spacer()
                if let d = updatedAt {
                    Text(d.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }

            Text("5 小时估算请求来自官方 Console；月额度是当前 \(selectedPlan.displayName) 套餐的美元 usage 上限。")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Text("模型")
                    .frame(width: 168, alignment: .leading)
                Text("估算请求 / 5h（对数刻度）")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("月额度")
                    .frame(width: 82, alignment: .trailing)
            }
            .font(.system(size: 8))
            .foregroundStyle(.secondary)

            VStack(spacing: 5) {
                ForEach(paid) { quota in
                    QuotaBarRow(
                        quota: quota,
                        plan: selectedPlan,
                        ratio: barRatio(
                            for: quota.requests5h(for: selectedPlan) ?? 0
                        ),
                        tint: barTint
                    )
                }
                ForEach(free) { quota in
                    FreeQuotaRow(
                        quota: quota,
                        top: freeTop,
                        bottom: freeBottom
                    )
                }
            }

            Text("数据实时同步自 opencode.ai/console/go；切换套餐不会改变当前账号已用比例。\(freeNote)")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var freeNote: String {
        let names = free.map(\.displayName)
        guard !names.isEmpty else { return "" }
        return "；\(names.joined(separator: "、")) 为限时免费。"
    }
}

private struct QuotaBarRow: View {
    let quota: GoQuota
    let plan: GoPlan
    let ratio: CGFloat
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(quota.displayName)
                    .font(.system(size: 9))
                    .lineLimit(1)
                if let badge = quota.badge {
                    Text(badge)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .lineLimit(1)
#if os(macOS)
                        .help(quota.note ?? badge)
#endif
                }
            }
            .frame(width: 168, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.65), tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geo.size.width * ratio))
                }
            }
            .frame(height: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(quota.requests5hDisplay(for: plan)) / 5h")
                    .font(.system(size: 8, weight: .semibold).monospacedDigit())
                Text("\(quota.monthlyDisplay(for: plan)) / 月")
                    .font(.system(size: 7).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 82, alignment: .trailing)
        }
        .frame(height: 17)
    }
}

private struct FreeQuotaRow: View {
    let quota: GoQuota
    let top: Color
    let bottom: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(quota.displayName)
                .font(.system(size: 9))
                .lineLimit(1)
                .frame(width: 168, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    LinearGradient(
                        colors: [top, bottom],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .clipShape(Capsule())
                }
            }
            .frame(height: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text("∞ / 5h")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(bottom)
                Text("限时免费")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 82, alignment: .trailing)
        }
        .frame(height: 17)
    }
}
