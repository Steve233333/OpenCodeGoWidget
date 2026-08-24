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
            // X 轴刻度：与条轨道同尺（最大月配额 226600），横排等分，不再用 position
            HStack(spacing: 6) {
                Color.clear.frame(width: 130, height: 1)
                VStack(spacing: 4) {
                    Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
                    HStack(spacing: 0) {
                        ForEach(["1x", "10x", "25x", "50x", "100x", "250x"], id: \.self) { label in
                            VStack(spacing: 2) {
                                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 4)
                                Text(label).font(.system(size: 7)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
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

    var body: some View {
        // 对数缩放使小值可见，线性过小时截图 110 几乎不可见；用 log 压缩
        let ratio: CGFloat = {
            guard let v = value, v > 0, max > 0 else { return 0 }
            // log 缩放：log10(v+1)/log10(max+1)，再混入少量线性保证 110 与 45300 区分度约 8 倍如截图
            let logV = log10(Double(v) + 10)
            let logM = log10(Double(max) + 10)
            let logRatio = logV / logM
            // 与线性加权 0.7*log + 0.3*linear，使小值不至于过长
            let linear = CGFloat(v) / CGFloat(max)
            return CGFloat(0.72 * logRatio + 0.28 * Double(linear))
        }()
        // 每段占总宽 1/3 容器内按比例，实际三段并排总宽约 1.0*totalWidth
        // 为保持同行三色对比，每段独立按 ratio*totalWidth/3? 这里每段占 1/3 轨道各自缩放
        let w = value == nil ? 0 : Swift.max(3, totalWidth / 3 * ratio)
        Rectangle().fill(value == nil ? Color.clear : color)
            .frame(width: value == nil ? 0 : w, height: 6)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.3))
    }
}
