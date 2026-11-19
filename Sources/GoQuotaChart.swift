import Foundation
import SwiftUI

struct GoQuotaChart: View {
    let quotas: [GoQuota]
    var updatedAt: Date? = nil

    @AppStorage("goQuotaPlan") private var selectedPlanRaw = GoPlan.go.rawValue

    private let c5h = Color(red: 0.92, green: 0.32, blue: 0.32)
    private let cWeekly = Color(red: 0.98, green: 0.58, blue: 0.14)
    private let cMonthly = Color(red: 0.20, green: 0.78, blue: 0.45)
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

    private var requests: [Int] {
        paid.compactMap { $0.requests5h(for: selectedPlan) }.filter { $0 > 0 }
    }

    private var baselineRequests: Int {
        requests.min() ?? 1
    }

    private var maximumRequests: Int {
        requests.max() ?? baselineRequests
    }

    private var maxMultiplier: Double {
        max(1.000001, Double(maximumRequests) / Double(max(baselineRequests, 1)))
    }

    private var tickPairs: [(label: String, value: Double)] {
        let candidates: [(String, Double)] = [
            ("1×", 1), ("5×", 5), ("10×", 10),
            ("25×", 25), ("50×", 50), ("100×", 100),
            ("250×", 250), ("500×", 500),
        ]
        return candidates.filter { $0.1 <= maxMultiplier }
    }

    private func ratioForMultiplier(_ multiplier: Double, in totalWidth: CGFloat) -> CGFloat {
        QuotaScale.fraction(
            multiplier: multiplier,
            maxMultiplier: maxMultiplier,
            totalWidth: totalWidth
        )
    }

    private func relativeMultiplier(for value: Int) -> String {
        let multiplier = Double(value) / Double(max(baselineRequests, 1))
        if multiplier < 10 {
            let rounded = (multiplier * 10).rounded() / 10
            return rounded == rounded.rounded()
                ? "\(Int(rounded))×"
                : String(format: "%.1f×", rounded)
        }
        return "\(Int(multiplier.rounded()))×"
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
#if os(macOS)
                .controlSize(.small)
#endif
                .frame(width: 128)
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
                    .frame(width: 150, alignment: .leading)
                HStack(spacing: 8) {
                    Text("请求数（同一行三段）")
                    Spacer()
                    LegendDot(color: c5h, label: "5h")
                    LegendDot(color: cWeekly, label: "周")
                    LegendDot(color: cMonthly, label: "月")
                    if !free.isEmpty {
                        LegendDot(color: freeTop, label: "免费")
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("周 / 月 / 套餐额度")
                    .frame(width: 96, alignment: .trailing)
            }
            .font(.system(size: 8))
            .foregroundStyle(.secondary)

            VStack(spacing: 5) {
                ForEach(paid) { quota in
                    QuotaBarRow(
                        quota: quota,
                        plan: selectedPlan,
                        baselineRequests: baselineRequests,
                        maxMultiplier: maxMultiplier,
                        multiplierLabel: relativeMultiplier(
                            for: quota.requests5h(for: selectedPlan) ?? 0
                        ),
                        c5h: c5h,
                        cWeekly: cWeekly,
                        cMonthly: cMonthly
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

            QuotaScaleAxis(
                ticks: tickPairs,
                ratio: ratioForMultiplier
            )

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

private enum QuotaScale {
    static func fraction(
        multiplier: Double,
        maxMultiplier: Double,
        totalWidth: CGFloat
    ) -> CGFloat {
        guard totalWidth > 0, maxMultiplier > 1 else { return 0 }
        let logRatio = log10(max(multiplier, 1))
        let logMaximum = log10(maxMultiplier)
        guard logMaximum > 0 else { return 0 }
        let t = pow(logRatio / logMaximum, 2.2)
        // 旧版同款：1× 不是 0，而是从 24px 起步。
        let base: CGFloat = 24
        let plotWidth = max(0, totalWidth - base)
        let position = base + CGFloat(t) * plotWidth
        return min(max(position / max(totalWidth, 1), 0), 1)
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }
}

private struct QuotaBarRow: View {
    let quota: GoQuota
    let plan: GoPlan
    let baselineRequests: Int
    let maxMultiplier: Double
    let multiplierLabel: String
    let c5h: Color
    let cWeekly: Color
    let cMonthly: Color

    private var requests5h: Int {
        quota.requests5h(for: plan) ?? 0
    }

    private var weeklyRequests: Int {
        Int((Double(requests5h) * 2.5).rounded())
    }

    private var monthlyRequests: Int {
        requests5h * 5
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(GoQuota.fmt(requests5h))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
                Text(quota.displayName)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
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
            .frame(width: 150, alignment: .leading)

            GeometryReader { geo in
                let totalWidth = geo.size.width
                let multiplier = Double(requests5h) / Double(max(baselineRequests, 1))
                let xMonthly = totalWidth * QuotaScale.fraction(
                    multiplier: multiplier,
                    maxMultiplier: maxMultiplier,
                    totalWidth: totalWidth
                )
                let h5Width = xMonthly * 0.20
                let weeklyWidth = xMonthly * 0.30
                let monthlyWidth = xMonthly * 0.50
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    HStack(spacing: 0) {
                        Rectangle().fill(c5h).frame(width: h5Width)
                        Rectangle().fill(cWeekly).frame(width: weeklyWidth)
                        Rectangle().fill(cMonthly).frame(width: monthlyWidth)
                        Spacer(minLength: 0)
                    }
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.3))
                }
            }
            .frame(height: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(multiplierLabel) · 周\(GoQuota.fmt(weeklyRequests))")
                    .font(.system(size: 7, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("月\(GoQuota.fmt(monthlyRequests)) · \(quota.monthlyDisplay(for: plan))")
                    .font(.system(size: 7).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 96, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
        .frame(height: 19)
    }
}

private struct QuotaScaleAxis: View {
    let ticks: [(label: String, value: Double)]
    let ratio: (Double, CGFloat) -> CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 150, height: 1)
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let visibleTicks: [(offset: Int, element: (label: String, value: Double))] = {
                    var result: [(offset: Int, element: (label: String, value: Double))] = []
                    var lastX: CGFloat = -.infinity
                    for pair in ticks.enumerated() {
                        let x = totalWidth * ratio(pair.element.value, totalWidth)
                        if x - lastX >= 28 {
                            result.append(pair)
                            lastX = x
                        }
                    }
                    return result
                }()
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: 1)
                    ForEach(visibleTicks, id: \.offset) { pair in
                        let x = totalWidth * ratio(pair.element.value, totalWidth)
                        VStack(spacing: 2) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.16))
                                .frame(width: 1, height: 4)
                            Text(pair.element.label)
                                .font(.system(size: 7))
                                .foregroundStyle(.secondary)
                        }
                        .offset(x: min(max(0, x - 12), geo.size.width - 24))
                    }
                }
            }
            .frame(height: 17)
            Color.clear.frame(width: 96, height: 1)
        }
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
            .frame(width: 150, alignment: .leading)

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
            .frame(width: 96, alignment: .trailing)
        }
        .frame(height: 17)
    }
}
