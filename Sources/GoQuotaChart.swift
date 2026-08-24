import SwiftUI
import Foundation

struct GoQuotaChart: View {
    let quotas: [GoQuota]
    var updatedAt: Date? = nil

    // 配额三段配色：与 QuotaRow 5h/周/月呼应
    private let c5h: Color = Color(red: 0.92, green: 0.32, blue: 0.32) // 红
    private let cWeekly: Color = Color(red: 0.98, green: 0.58, blue: 0.14) // 橙
    private let cMonthly: Color = Color(red: 0.20, green: 0.78, blue: 0.45) // 绿
    private let goldTop: Color = Color(red: 1.0, green: 0.84, blue: 0.0)
    private let goldBottom: Color = Color(red: 0.85, green: 0.65, blue: 0.13)

    private var monthlyBaseline: Int {
        quotas.compactMap { $0.monthly }.min() ?? 490
    }
    /// 适配官网图表的基准：月配额最低模型 = 1x；真实最大倍率不超过 500x
    private var maxMultiplier: Double {
        guard monthlyBaseline > 0 else { return 1.000001 }
        let raw = quotas.compactMap { $0.monthly }.map { Double($0) / Double(monthlyBaseline) }.max() ?? 1
        return min(max(raw, 1.000001), 500)
    }

    // 按 h5 升序
    private var sorted: [GoQuota] {
        quotas.sorted { ($0.h5 ?? Int.max) < ($1.h5 ?? Int.max) }
    }

    /// 官网同款刻度：1x/5x/10x/25x/50x/100x/250x/500x，只保留不超过真实最大倍率的项。
    /// 小屏下 5x 与 1x 过近时由绘制层自动隐藏，避免拥挤。
    private var tickPairs: [(String, Double)] {
        let candidates: [(String, Double)] = [("1x",1),("5x",5),("10x",10),("25x",25),("50x",50),("100x",100),("250x",250),("500x",500)]
        return candidates.filter { $0.1 <= maxMultiplier }
    }

    // 官网同款：base 24 + pow(log10(ratio)/log10(rmax), 2.2) * (plot-base)
    // 1x 不是 0，而是落在 base 处；Kimi 月条正好到 1x 刻度。
    private func ratioForMultiplier(_ mult: Double, in totalW: CGFloat) -> CGFloat {
        guard totalW > 0, maxMultiplier > 1 else { return 0 }
        let ratio = max(mult, 1)
        let logRatio = log10(ratio)
        let logMax = log10(maxMultiplier)
        guard logMax > 0 else { return 0 }
        let t = pow(logRatio / logMax, 2.2)
        let base: CGFloat = 24
        let plot = max(0, totalW - base)
        let pos = base + CGFloat(t) * plot
        return min(max(pos / totalW, 0), 1)
    }

    private func ratio(for value: Int, in totalW: CGFloat) -> CGFloat {
        guard monthlyBaseline > 0 else { return 0 }
        return ratioForMultiplier(Double(value) / Double(monthlyBaseline), in: totalW)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Go 配额（每 5h / 周 / 月）").font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    LegendDot(color: c5h, label: "5h")
                    LegendDot(color: cWeekly, label: "周")
                    LegendDot(color: cMonthly, label: "月")
                    LegendDot(color: goldTop, label: "免费")
                }
                if let d = updatedAt {
                    Text(d.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            // 列头
            HStack(spacing: 6) {
                Text("模型").font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                Text("请求数 (同行三段)").font(.system(size: 8)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 2)
                Color.clear.frame(width: 70, height: 8)
            }
            .padding(.horizontal, 0)

            VStack(spacing: 5) {
                ForEach(sorted) { q in
                    if q.monthly == nil || q.slug == "ox-alpha-free" {
                        GoldBarRow(displayName: q.displayName)
                    } else {
                        QuotaBarRowNested(quota: q, ratio: ratio, c5h: c5h, cWeekly: cWeekly, cMonthly: cMonthly)
                    }
                }
            }
            // X 轴刻度：轴优先，与条同尺（ratio），Kimi 1x 对齐其月条末端
            HStack(spacing: 6) {
                Color.clear.frame(width: 130, height: 1)
                GeometryReader { geo in
                    let totalW = geo.size.width
                    // 官网同款：相邻刻度太近时自动隐藏（5x 在小屏通常会被隐藏）
                    let visibleTicks: [(String, Double)] = {
                        var result: [(String, Double)] = []
                        var lastX: CGFloat = -.infinity
                        for pair in tickPairs {
                            let x = totalW * ratioForMultiplier(pair.1, in: totalW)
                            if x - lastX >= 30 {
                                result.append(pair)
                                lastX = x
                            }
                        }
                        return result
                    }()
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                        ForEach(visibleTicks, id: \.0) { pair in
                            let x = totalW * ratioForMultiplier(pair.1, in: totalW)
                            VStack(spacing: 2) {
                                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 4)
                                Text(pair.0).font(.system(size: 7)).foregroundStyle(.secondary)
                            }
                            .frame(width: 28)
                            .offset(x: min(max(0, x - 14), totalW - 28))
                        }
                    }
                }
                .frame(height: 16)
                Color.clear.frame(width: 70, height: 1)
            }
            .frame(height: 16)

            Text("数据实时同步自 opencode.ai/docs/zh-cn/go/ 配额表，刷新自动更新；Ox Alpha Free 为限时免费不计配额。")
                .font(.system(size: 8)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(10)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
    }
}

private struct LegendDot: View {
    let color: Color; let label: String
    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }
}

private struct GoldBarRow: View {
    let displayName: String
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Text("∞").font(.system(size: 9, weight: .bold)).frame(width: 36, alignment: .trailing).foregroundStyle(Color(red: 0.85, green: 0.65, blue: 0.13))
                Text(displayName).font(.system(size: 9)).lineLimit(1).foregroundStyle(.primary)
            }
            .frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    LinearGradient(colors: [Color(red: 1.0, green: 0.84, blue: 0.0), Color(red: 0.85, green: 0.65, blue: 0.13)], startPoint: .leading, endPoint: .trailing)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.3))
                    HStack {
                        Text("∞ 免费拉满").font(.system(size: 7, weight: .bold)).foregroundColor(.white)
                            .padding(.leading, 6)
                        Spacer()
                    }
                }
            }
            .frame(height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text("限时免费").font(.system(size: 7)).foregroundStyle(Color(red: 0.85, green: 0.65, blue: 0.13)).lineLimit(1)
                Text("∞").font(.system(size: 7)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 70, alignment: .leading)
        }
        .frame(height: 14)
    }
}

private struct QuotaBarRowNested: View {
    let quota: GoQuota
    let ratio: (Int, CGFloat) -> CGFloat
    let c5h: Color
    let cWeekly: Color
    let cMonthly: Color

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                if let v = quota.h5 {
                    Text(GoQuota.fmt(v)).font(.system(size: 9, weight: .semibold).monospacedDigit()).lineLimit(1)
                        .frame(width: 36, alignment: .trailing)
                } else {
                    Text("-").font(.system(size: 9)).frame(width: 36, alignment: .trailing).foregroundStyle(.secondary)
                }
                Text(quota.displayName).font(.system(size: 9)).lineLimit(1).foregroundStyle(.primary)
            }
            .frame(width: 130, alignment: .leading)

            // 嵌套月内：总长 = monthly 在轴上的位置，内部按线性比例（22.45%/51.02%）避免对数膨胀
            GeometryReader { geo in
                let totalW = geo.size.width
                let monthlyVal = quota.monthly ?? 0
                let xMonthly = totalW * ratio(monthlyVal, totalW)
                if let m = quota.monthly, m > 0 {
                    let h5 = quota.h5 ?? 0
                    let w = quota.weekly ?? 0
                    let wH5 = xMonthly * CGFloat(h5) / CGFloat(m)
                    let wWeekly = xMonthly * CGFloat(max(0, w - h5)) / CGFloat(m)
                    let wRemain = max(0, xMonthly - wH5 - wWeekly)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        HStack(spacing: 0) {
                            if wH5 > 0 { Rectangle().fill(c5h).frame(width: wH5) }
                            if wWeekly > 0 { Rectangle().fill(cWeekly).frame(width: wWeekly) }
                            if wRemain > 0 { Rectangle().fill(cMonthly).frame(width: wRemain) }
                            Spacer(minLength: 0)
                        }
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.3))
                    }
                } else {
                    ZStack(alignment: .leading) { Capsule().fill(Color.primary.opacity(0.06)) }
                }
            }
            .frame(height: 8)

            VStack(alignment: .leading, spacing: 1) {
                if let w = quota.weekly { Text("周\(GoQuota.fmt(w))").font(.system(size: 7)).foregroundStyle(.secondary).lineLimit(1) }
                if let m = quota.monthly { Text("月\(GoQuota.fmt(m))").font(.system(size: 7)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(width: 70, alignment: .leading)
        }
        .frame(height: 14)
    }
}
