import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WidgetKit
import Charts

// 费用图相关视图。2026-09-23 Phase 2 从 App.swift 拆出。

struct CostBar: View {
    let entries: [String: Double]
    let total: Double
    var sorted: [(String, Double)] {
        entries.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) } + (entries.count > 3 ? [("其他", entries.values.reduce(0,+)-entries.sorted{$0.value>$1.value}.prefix(3).map{$0.value}.reduce(0,+))] : [])
    }
    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(sorted, id: \.0) { (k,v) in
                        // 2026-09-26：百分比钳到 0…100 —— 合计与明细万一打架（上游换口径时出现过
                        // 305%），宁可画满也不能画出界。源头已改成"合计 = 明细之和"。
                        let frac = total > 0 ? min(1, max(0, v/total)) : 0
                        let w = CGFloat(frac) * geo.size.width
                        Rectangle().fill(colorFor(k)).frame(width: max(0,w))
                    }
                }.clipShape(Capsule())
            }.frame(height: 8)
            HStack {
                ForEach(sorted.prefix(3), id: \.0) { (k,v) in
                    HStack(spacing: 4) {
                        Circle().fill(colorFor(k)).frame(width: 6, height: 6)
                        Text("\(short(k)) \(total > 0 ? Int(min(1, max(0, v / total)) * 100) : 0)%").font(.caption2).lineLimit(1)
                    }
                }
                Spacer()
            }
        }
    }
    func colorFor(_ k: String) -> Color {
        if k == "其他" { return Color.gray.opacity(0.6) }
        return ModelPalette.color(for: k)
    }
    // 2026-09-22：今日模型条也改用官方显示名（「GPT 5.6 Luna」而不是 slug）
    func short(_ s: String) -> String { ModelPalette.displayName(s) }
}

struct MonthChartView: View {
    let dailyCosts: [DailyCost]
    let monthlyReset: Date?
    let alignment: ChartAlignment

    init(dailyCosts: [DailyCost], monthlyReset: Date? = nil, alignment: ChartAlignment = .billing) {
        self.dailyCosts = dailyCosts
        self.monthlyReset = monthlyReset
        self.alignment = alignment
    }

    private var effectiveDates: [Date] {
        ChartWindow.dates(dailyCosts: dailyCosts, monthlyReset: monthlyReset, alignment: alignment)
    }

    private var flat: [DayModelCost] {
        let map: [String: DailyCost] = Dictionary(uniqueKeysWithValues: dailyCosts.map { ($0.date, $0) })
        var result: [DayModelCost] = []
        for date in effectiveDates {
            let key = ChartFormatters.day.string(from: date)
            if let dc = map[key] {
                        for (model, cost) in ModelPalette.foldedEntries(dc.entries) where cost > 0 {
                            result.append(DayModelCost(date: date, model: model, cost: cost))
                        }
            }
        }
        return result
    }

    private var yDomain: ClosedRange<Double> {
        let maxDaily = dailyCosts.map { $0.total }.max() ?? 0
        let top = max(2.5, ceil(maxDaily * 1.2 * 10) / 10)
        let capped = min(max(top, 2.5), 6.0)
        return 0...capped
    }

    private var allXStrings: [String] {
        if alignment == .billing {
            return effectiveDates.map { ChartFormatters.billingLabel.string(from: $0) }
        }
        return effectiveDates.map { ChartFormatters.monthLabel.string(from: $0) }
    }

    private func xString(for date: Date) -> String {
        if alignment == .billing { return ChartFormatters.billingLabel.string(from: date) }
        return ChartFormatters.monthLabel.string(from: date)
    }

    var body: some View {
        Chart(flat) { item in
            BarMark(
                x: .value("Date", xString(for: item.date)),
                y: .value("Cost", item.cost),
                stacking: .standard
            )
            .foregroundStyle(by: .value("Model", item.model))
            .cornerRadius(1)
        }
        .chartForegroundStyleScale { (model: String) in
            if model == "__empty__" { return Color.clear }
            return ModelPalette.color(for: model)
        }
        .chartXScale(domain: allXStrings)
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { val in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2,2])).foregroundStyle(Color.primary.opacity(0.12))
                AxisValueLabel {
                    if let v = val.as(Double.self) {
                        Text(String(format: "$%.0f", v)).font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            // billing: ~31 ticks, subsample every ~5d; calendar: every 3d
            let stride = alignment == .billing ? 5 : 3
            let ticks = allXStrings.enumerated().filter { $0.offset % stride == 0 }.map { $0.element }
            AxisMarks(values: ticks) { val in
                AxisGridLine().foregroundStyle(Color.clear)
                AxisValueLabel(centered: true) {
                    if let s = val.as(String.self) {
                        Text(s).font(.system(size: 7)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot
                .background(Color.primary.opacity(0.03))
                .border(Color.primary.opacity(0.08), width: 0.5)
        }
        .chartLegend(.hidden)
        .padding(.top, 4)
    }
}


/// 环境自检：一次问清楚「新机器上到底哪一步没配上」。
/// 覆盖 Go/DeepSeek Key 存在性 + **真实有效性**（各发一次最小请求）、本地代理进程与端口、
/// 自动发现任务、模型目录、双开副本、小组件共享通道；每项都带证据，可一键复制报告。
