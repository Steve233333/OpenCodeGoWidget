import Foundation

struct UsageItem: Codable, Equatable {
    let status: String
    let percent: Int
    let resetsAt: Date
}

struct UsageStats: Codable, Equatable {
    let rolling: UsageItem
    let weekly: UsageItem
    let monthly: UsageItem
}

struct UsageResponse: Codable {
    let usage: UsageStats
}

struct CostEntry: Identifiable {
    let id = UUID()
    let model: String
    let cost: Double
    let percent: Double
}

enum UsageLevel {
    case safe, elevated, critical
    init(percent: Int) {
        switch percent {
        case ..<51: self = .safe
        case ..<81: self = .elevated
        default: self = .critical
        }
    }
}
