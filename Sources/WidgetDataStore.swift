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
        }
    }

    static func load() -> WidgetSnapshot? {
        guard let d = defaults, let data = d.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
