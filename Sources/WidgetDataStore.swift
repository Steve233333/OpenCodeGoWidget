import Foundation

struct WidgetSnapshot: Codable {
    var rolling: Int
    var weekly: Int
    var monthly: Int
    var rollingReset: Date
    var weeklyReset: Date
    var monthlyReset: Date
    var costTotal: Double
    var costEntries: [String: Double] // model -> cost (today)
    var dailyCosts: [DailyCost] = []
    var updatedAt: Date
    var error: String?
}

enum WidgetDataStore {
    static let suiteName = "2DC432GLL2.com.steve233.opencodego"
    static let snapshotKey = "widget_snapshot"

    static var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    static func save(_ snap: WidgetSnapshot) {
        guard let d = defaults else { return }
        if let data = try? JSONEncoder().encode(snap) {
            d.set(data, forKey: snapshotKey)
            // The App and the widget are separate processes. Force this write
            // through before asking WidgetKit for a new timeline, otherwise an
            // intent can be rendered once more with the previous snapshot.
            d.synchronize()
        }
    }

    static func load() -> WidgetSnapshot? {
        guard let d = defaults, let data = d.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

enum WidgetConstants {
    static let kind = "OpenCodeGoWidget"
}

enum WidgetSnapshotRefresher {
    static func fetch() async throws -> WidgetSnapshot {
        let manager = NetworkManager()
        let usage = try await manager.fetchUsage()
        let cost = await manager.fetchCostToday()
        var entries: [String: Double] = [:]
        for entry in cost.entries {
            entries[entry.model] = entry.cost
        }

        return WidgetSnapshot(
            rolling: usage.rolling.percent,
            weekly: usage.weekly.percent,
            monthly: usage.monthly.percent,
            rollingReset: usage.rolling.resetsAt,
            weeklyReset: usage.weekly.resetsAt,
            monthlyReset: usage.monthly.resetsAt,
            costTotal: cost.total,
            costEntries: entries,
            dailyCosts: cost.daily,
            updatedAt: Date(),
            error: nil
        )
    }
}
