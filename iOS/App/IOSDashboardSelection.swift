import Foundation

struct IOSModelAmount: Identifiable, Equatable {
    let model: String
    let amount: Double
    var id: String { model }
}

struct IOSChartRow: Identifiable {
    let date: Date
    let model: String
    let amount: Double
    var id: String { "\(date.timeIntervalSince1970)-\(model)" }
}

struct IOSFoldResult {
    let rows: [IOSChartRow]
    let legend: [IOSModelAmount]
}

enum IOSDashboardData {
    static func periodDaily(
        snapshot: WidgetSnapshot,
        selectedKeyID: String?,
        alignment: ChartAlignment
    ) -> [DailyCost] {
        let source = snapshot.filteredDaily(for: selectedKeyID)
        let keys = ChartWindow.dateKeys(
            dailyCosts: source,
            monthlyReset: snapshot.monthlyReset,
            alignment: alignment
        )
        return source
            .filter { keys.contains($0.date) }
            .sorted { $0.date < $1.date }
    }

    static func total(_ daily: [DailyCost]) -> Double {
        daily.reduce(0) { $0 + $1.total }
    }

    static func modelTotals(_ daily: [DailyCost]) -> [IOSModelAmount] {
        var totals: [String: Double] = [:]
        for day in daily {
            for (model, amount) in day.entries where amount > 0 && !model.hasPrefix("(") {
                totals[model, default: 0] += amount
            }
        }
        return totals
            .map { IOSModelAmount(model: $0.key, amount: $0.value) }
            .sorted {
                if abs($0.amount - $1.amount) > 0.000_001 {
                    return $0.amount > $1.amount
                }
                return $0.model < $1.model
            }
    }

    static func foldedModelTotals(
        _ daily: [DailyCost],
        topCount: Int = 5
    ) -> [IOSModelAmount] {
        let exact = modelTotals(daily)
        guard exact.count > topCount else { return exact }
        let top = Array(exact.prefix(max(1, topCount)))
        let other = exact.dropFirst(max(1, topCount)).reduce(0) { $0 + $1.amount }
        return top + [IOSModelAmount(model: ModelPalette.otherName, amount: other)]
    }

    static func foldedChart(
        _ daily: [DailyCost],
        topCount: Int = 5
    ) -> IOSFoldResult {
        let exact = modelTotals(daily)
        let topModels = Set(exact.prefix(max(1, topCount)).map(\.model))
        let formatter = ChartFormatters.day
        var folded: [String: [String: Double]] = [:]
        for day in daily {
            for (model, amount) in day.entries where amount > 0 && !model.hasPrefix("(") {
                let key = topModels.contains(model) ? model : ModelPalette.otherName
                folded[day.date, default: [:]][key, default: 0] += amount
            }
        }

        var rows: [IOSChartRow] = []
        for day in daily {
            guard let date = formatter.date(from: day.date) else { continue }
            for (model, amount) in folded[day.date] ?? [:] where amount > 0 {
                rows.append(IOSChartRow(date: date, model: model, amount: amount))
            }
        }

        return IOSFoldResult(
            rows: rows,
            legend: foldedModelTotals(daily, topCount: topCount)
        )
    }

    static func todayEntries(snapshot: WidgetSnapshot, selectedKeyID: String?) -> [IOSModelAmount] {
        let entries = snapshot.filteredCostEntries(for: selectedKeyID)
        return entries
            .filter { $0.value > 0 && !$0.key.hasPrefix("(") }
            .map { IOSModelAmount(model: $0.key, amount: $0.value) }
            .sorted {
                if abs($0.amount - $1.amount) > 0.000_001 {
                    return $0.amount > $1.amount
                }
                return $0.model < $1.model
            }
    }

    static func calendarTitle(for date: Date = Date()) -> String {
        let calendar = BillingCycle.calendar
        guard let interval = calendar.dateInterval(of: .month, for: date),
              let last = calendar.date(byAdding: .day, value: -1, to: interval.end) else {
            return "自然月"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = BillingCycle.tz
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: interval.start))–\(formatter.string(from: last))"
    }

    static func periodTitle(
        snapshot: WidgetSnapshot,
        alignment: ChartAlignment
    ) -> String {
        alignment == .billing
            ? BillingCycle.titleRange(monthlyReset: snapshot.monthlyReset)
            : calendarTitle()
    }

    static func channelLabel(_ model: String) -> String {
        let lower = model.lowercased()
        if lower == ModelPalette.otherName.lowercased() { return "汇总" }
        if lower.hasSuffix("-zen") || lower.hasSuffix("-free") || lower == "big-pickle" {
            return "Zen"
        }
        return "Go"
    }
}
