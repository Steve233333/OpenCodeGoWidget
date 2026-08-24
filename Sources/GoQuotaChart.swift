import SwiftUI

struct GoQuotaChart: View {
    let quotas: [GoQuota]
    var updatedAt: Date? = nil

    // 配额三段配色：与 QuotaRow 5h/周/月呼应，区分度高
    private let c5h: Color = Color(red: 0.92, green: 0.32, blue: 0.32) // 红
    private let cWeekly: Color = Color(red: 0.98, green: 0.58, blue: 0.14) // 橙
    private let cMonthly: Color = Color(red: 0.20, green: 0.78, blue: 0.45) // 绿

    private var maxMonthly: Int {
        quotas.compactMap { $0.monthly }.max() ?? 1
    }
    private var maxH5: Int { quotas.compactMap { $0.h5 }.max() ?? 1 }

    // 按 h5 升序，与截图一致
    private var sorted: [GoQuota] {
        quotas.sorted { ($0.h5 ?? Int.max) < ($1.h5 ?? Int.max) }
    }

    // 官网黄图倍率基线：Kimi K3 每5小时 110 请求 ≈ 1x，250x ≈ 27500，与官方条长度一致（已上网核实）
    private let baseline: Int = 110
    private var tickPairs: [(String, Int)] {
        [( "1x", baseline*1), ("10x", baseline*10), ("25x", baseline*25), ("50x", baseline*50), ("100x", baseline*100), ("250x", baseline*250)]
    }
    // 与 BarSegment 同尺的混合对数比例（0.72 log + 0.28 linear），用于刻度与条同把尺子
    private func ratio(for value: Int) -> CGFloat {
        guard value > 0, maxMonthly > 0 else { return 0 }
        let logV = log10(Double(value) + 10)
        let logM = log10(Double(maxMonthly) + 10)
        let logRatio = logV / logM
        let linear = CGFloat(value) / CGFloat(maxMonthly)
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
                }
                if let d = updatedAt {
                    Text(d.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            // 列头（130 与条轨道左对齐，70 与右侧数值列对齐，避免刻度歪斜）
            HStack(spacing: 6) {
                Text("模型").font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                Text("请求数 (同行三段)").font(.system(size: 8)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 2)
                Color.clear.frame(width: 70, height: 8)
            }
            .padding(.horizontal, 0)

            VStack(spacing: 5) {
                ForEach(sorted) { q in
                    QuotaBarRow(quota: q, maxMonthly: maxMonthly)
                }
            }
            // X 轴刻度：与条同尺（基线 110，log 混合），横排按比例而非等分，彻底消除 position 歪斜
            HStack(spacing: 6) {
                Color.clear.frame(width: 130, height: 1)
                GeometryReader { geo in
                    let totalW = geo.size.width
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                        ForEach(Array(tickPairs.enumerated()), id: \.offset) { _, pair in
                            let r = ratio(for: pair.1)
                            // 1x 贴零点，避免最左越界；其余按比例
                            let x = max(0, totalW * r)
                            VStack(spacing: 2) {
                                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 4)
                                Text(pair.0).font(.system(size: 7)).foregroundStyle(.secondary)
                            }
                            .frame(width: 22)
                            .offset(x: min(x - 11, totalW - 22))
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

private struct QuotaBarRow: View {
    let quota: GoQuota
    let maxMonthly: Int
    private let c5h: Color = Color(red: 0.92, green: 0.32, blue: 0.32)
    private let cWeekly: Color = Color(red: 0.98, green: 0.58, blue: 0.14)
    private let cMonthly: Color = Color(red: 0.20, green: 0.78, blue: 0.45)

    var body: some View {
        HStack(spacing: 6) {
            // 左侧模型名 + 数值（截图风格：数值加粗在前）
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

            // 右侧同行三段条
            GeometryReader { geo in
                let totalW = geo.size.width
                HStack(spacing: 1) {
                    // 5h
                    BarSegment(value: quota.h5, max: maxMonthly, totalWidth: totalW, color: c5h)
                    // 周
                    BarSegment(value: quota.weekly, max: maxMonthly, totalWidth: totalW, color: cWeekly)
                    // 月
                    BarSegment(value: quota.monthly, max: maxMonthly, totalWidth: totalW, color: cMonthly)
                }
                .frame(height: 8)
                .clipShape(Capsule())
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .frame(height: 8)

            // 右侧数值补充（可选周/月悬浮）
            VStack(alignment: .leading, spacing: 1) {
                if let w = quota.weekly { Text("周\(GoQuota.fmt(w))").font(.system(size: 7)).foregroundStyle(.secondary).lineLimit(1) }
                if let m = quota.monthly { Text("月\(GoQuota.fmt(m))").font(.system(size: 7)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(width: 70, alignment: .leading)
        }
        .frame(height: 14)
    }
}

private struct BarSegment: View {
    let value: Int?
    let max: Int
    let totalWidth: CGFloat
    let color: Color

    private func segRatio(for v: Int) -> CGFloat {
        let logV = log10(Double(v) + 10)
        let logM = log10(Double(max) + 10)
        let logRatio = logV / logM
        let linear = CGFloat(v) / CGFloat(max)
        return CGFloat(0.72 * logRatio + 0.28 * Double(linear))
    }

    var body: some View {
        let r: CGFloat = {
            guard let v = value, v > 0, max > 0 else { return 0 }
            return segRatio(for: v)
        }()
        // 每段占总宽 1/3 容器内按比例，实际三段并排总宽约 1.0*totalWidth
        let w = value == nil ? 0 : Swift.max(3, totalWidth / 3 * r)
        Rectangle().fill(value == nil ? Color.clear : color)
            .frame(width: value == nil ? 0 : w, height: 6)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.3))
    }
}
