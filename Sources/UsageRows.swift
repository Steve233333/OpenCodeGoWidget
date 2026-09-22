import Foundation

/// 官方 `usage/rows` 的**行级解析（唯一真源）**——2026-09-23 Phase 1 从 ConsoleUsageAPI 抽出。
///
/// 「一条记录算哪一天、算哪个模型、算哪个 Key」这件事只在这里定义一次：
///   * 金额字段是**微美分**字符串（100,000,000 微美分 = 1 美元）；
///   * `createdAt`（ISO8601 带毫秒）→ 归日**必须**走 `ChartFormatters.day`（北京时间 0 点）；
///   * 一行同时算进「按模型」和「按 Key」两份拆分，两者天然相加相等。
///
/// 这里不许 import SwiftUI / 不许碰网络：离线回归测试（Tests/UsagePipelineTests.swift）只编译
/// 数据层这几个文件，所以任何"顺手引个 UI/网络类型"都会让护栏失效。
enum UsageRows {
    static func microCents(_ value: Any?) -> Double {
        if let s = value as? String { return Double(s) ?? 0 }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return 0
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// `createdAt` → 本地日（北京时间）的 `yyyy-MM-dd`；解析不了返回 nil（调用方再兜底取前 10 位）
    static func dayString(createdAt: String) -> String? {
        let d = isoFractional.date(from: createdAt) ?? isoPlain.date(from: createdAt)
        return d.map { ChartFormatters.day.string(from: $0) }
    }

    /// 明细行 → (date→model→美元, keyId→date→model→美元)
    static func aggregate(_ rows: [[String: Any]]) -> ([String: [String: Double]], [String: [String: [String: Double]]]) {
        var daily: [String: [String: Double]] = [:]
        var byKey: [String: [String: [String: Double]]] = [:]
        for row in rows {
            guard let model = row["model"] as? String else { continue }
            let usd = microCents(row["costMicroCents"]) / 100_000_000.0
            guard usd > 0 else { continue }
            guard let created = row["createdAt"] as? String else { continue }
            let date = dayString(createdAt: created) ?? String(created.prefix(10))
            daily[date, default: [:]][model, default: 0] += usd
            if let key = row["serviceApiKeyId"] as? String, !key.isEmpty {
                byKey[key, default: [:]][date, default: [:]][model, default: 0] += usd
            }
        }
        return (daily, byKey)
    }
}
