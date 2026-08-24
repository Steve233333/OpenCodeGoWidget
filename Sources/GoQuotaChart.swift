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

    // 官网倍率基线：Kimi K3 110 ≈ 1x；轴优先：先定刻度轴，再按轴画条
    private let baseline: Int = 110
    private var axisMaxMultiplier: Int {
        let maxV = maxMonthly
        let need = max(1, Int(ceil(Double(maxV) / Double(baseline))))
        // 动态刻度：覆盖当前最大月配额，超出 250 则自动加 500/1000/2000
        let candidates = [1, 10, 25, 50, 100, 250, 500, 1000, 2000, 5000]
        // 轴最大取大于 need 的下一档，保证最大条不溢出
        for c in candidates where c >= need { return c }
        return candidates.last!
    }
    private var tickPairs: [(String, Int)] {
        let candidates: [(String, Int)] = [("1x",1),("10x",10),("25x",25),("50x",50),("100x",100),("250x",250),("500x",500),("1000x",1000),("2000x",2000)]
        return candidates.filter { $0.1 <= axisMaxMultiplier }.map { ($0.0, baseline * $0.1) }
    }
    // 轴优先的混合比例：分母用 axisMax（刻度最大值）而非 maxMonthly，保证条与刻度同尺
    private var axisMaxValue: Int { baseline * axisMaxMultiplier }
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
            // X 轴刻度：轴优先，横排等分（官网均匀感），与条同用 axisMax 混合比例
            HStack(spacing: 6) {
                Color.clear.frame(width: 130, height: 1)
                VStack(spacing: 4) {
                    Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                    HStack(spacing: 0) {
                        ForEach(tickPairs, id: \.0) { pair in
                            VStack(spacing: 2) {
                                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 4)
                                Text(pair.0).font(.system(size: 7)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
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
    // 轴最大用于条缩放（与刻度同尺）
    private var axisMax: Int {
        let baseline = 110
        let need = max(1, Int(ceil(Double(maxMonthly) / Double(baseline))))
        let candidates = [250, 500, 1000, 2000, 5000]
        for c in candidates where c >= need { return baseline * c }
        return baseline * 5000
    }

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

            // 右侧同行三段条：轴优先，按 axisMax 混合比例
            GeometryReader { geo in
                let totalW = geo.size.width
                HStack(spacing: 1) {
                    // 5h
                    BarSegment(value: quota.h5, max: axisMax, totalWidth: totalW, color: c5h)
                    // 周
                    BarSegment(value: quota.weekly, max: axisMax, totalWidth: totalW, color: cWeekly)
                    // 月
                    BarSegment(value: quota.monthly, max: axisMax, totalWidth: totalW, color: cMonthly)
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
