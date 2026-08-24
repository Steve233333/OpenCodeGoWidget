import SwiftUI

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
    private var maxMonthly: Int {
        quotas.compactMap { $0.monthly }.max() ?? 1
    }
    // 轴最大：现有最大月配额 +10%，不做无意义大刻度
    private var axisMaxValue: Int {
        let raw = Int(ceil(Double(maxMonthly) * 1.10))
        // 取整到 100，美观
        return max(raw, 1)
    }
    private var axisMaxMultiplier: Double {
        guard monthlyBaseline > 0 else { return 1 }
        return Double(axisMaxValue) / Double(monthlyBaseline)
    }

    // 按 h5 升序
    private var sorted: [GoQuota] {
        quotas.sorted { ($0.h5 ?? Int.max) < ($1.h5 ?? Int.max) }
    }

    // 动态刻度：以 monthlyBaseline 为 1x，按 +10% 轴最大生成 1x/10x/25x/50x/100x/250x/500x 等，过滤超出轴最大
    private var tickPairs: [(String, Int)] {
        let candidates: [(String, Int)] = [("1x",1),("5x",5),("10x",10),("25x",25),("50x",50),("100x",100),("250x",250),("500x",500),("1000x",1000)]
        var result: [(String, Int)] = []
        for (label, mult) in candidates {
            let v = monthlyBaseline * mult
            if v <= axisMaxValue + 1 { // 包含略超的 43.88x 等
                result.append((label, v))
            } else if result.isEmpty {
                result.append((label, v))
            }
        }
        // 保证至少包含 1x 与最接近轴最大的刻度
        if let last = result.last, last.1 < axisMaxValue {
            let maxLabel = String(format: "%.1fx", axisMaxMultiplier)
            // 避免重复，例如已含 500x 再加 510x 无意义，改用轴最大对应的倍率
            if !result.contains(where: { $0.0 == maxLabel }) {
                result.append((String(format: "%.0fx", ceil(axisMaxMultiplier)), axisMaxValue))
            }
        }
        // 去重并限制数量，避免过密
        if result.count > 7 {
            // 保留首尾，中间稀疏
            return [result[0], result[2], result[4], result[result.count-1]]
        }
        return result
    }

    // 轴优先的混合比例（0.72 log +0.28 linear），分母用 axisMaxValue
    private func ratio(for value: Int) -> CGFloat {
        guard value > 0, axisMaxValue > 0 else { return 0 }
        let logV = log10(Double(value) + 10)
        let logM = log10(Double(axisMaxValue) + 10)
        let logRatio = logV / logM
        let linear = CGFloat(value) / CGFloat(axisMaxValue)
        return CGFloat(0.72 * logRatio + 0.28 * Double(linear))
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
                        QuotaBarRowNested(quota: q, axisMaxValue: axisMaxValue, ratio: ratio, c5h: c5h, cWeekly: cWeekly, cMonthly: cMonthly)
                    }
                }
            }
            // X 轴刻度：轴优先，与条同尺（ratio），Kimi 1x 对齐其月条末端
            HStack(spacing: 6) {
                Color.clear.frame(width: 130, height: 1)
                GeometryReader { geo in
                    let totalW = geo.size.width
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                        ForEach(tickPairs, id: \.0) { pair in
                            let x = totalW * ratio(for: pair.1)
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
    let axisMaxValue: Int
    let ratio: (Int) -> CGFloat
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
                let xMonthly = totalW * ratio(monthlyVal)
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
