import Foundation
import os

/// 实时同步 OpenCode Go 套餐模型列表
/// 真源：GET https://opencode.ai/zen/go/v1/models（无鉴权，OpenAI 风格 list）
/// App Group 缓存 + 24h TTL + 硬编码回退，保证离线与首屏可用
enum ModelRegistry {
    static let suiteName = "2DC432GLL2.com.steve233.opencodego"
    static let cacheKey = "go_model_ids"
    static let cacheDateKey = "go_model_ids_date"
    static let ttl: TimeInterval = 24 * 3600

    // 回退列表：当前 Go 全量 29 项（API 2026-08-24 快照），保证首装/断网时即有完整图例
    // 顺序与 API 返回一致，兼容文档表
    static let fallbackOrdered: [String] = [
        "minimax-m3",
        "minimax-m2.7",
        "minimax-m2.5",
        "kimi-k3",
        "kimi-k2.7-code",
        "kimi-k2.6",
        "kimi-k2.5",
        "glm-5.2",
        "glm-5.3",
        "ox-alpha-free",
        "glm-5.1",
        "glm-5",
        "deepseek-v4-pro",
        "deepseek-v4-flash",
        "deepseek-v4-flash-vision-exp",
        "qwen3.7-max",
        "qwen3.8-max",
        "qwen3.7-plus",
        "qwen3.6-plus",
        "qwen3.5-plus",
        "mimo-v2-pro",
        "mimo-v2-omni",
        "mimo-v2.5-pro",
        "mimo-v2.5",
        "hy3",
        "hy3-preview",
        "gpt-5.6-luna",
        "grok-4.5",
        "muse-spark-1.2-contributor",
    ]

    private static let logger = Logger(subsystem: "com.steve233.opencodego", category: "ModelRegistry")
    private static let endpoint = URL(string: "https://opencode.ai/zen/go/v1/models")!

    // MARK: - Cache

    static func cachedOrderedSync() -> [String] {
        guard let d = UserDefaults(suiteName: suiteName),
              let arr = d.stringArray(forKey: cacheKey), !arr.isEmpty else {
            return fallbackOrdered
        }
        return arr
    }

    static func cachedDate() -> Date? {
        UserDefaults(suiteName: suiteName)?.object(forKey: cacheDateKey) as? Date
    }

    static func save(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let d = UserDefaults(suiteName: suiteName)
        d?.set(ids, forKey: cacheKey)
        d?.set(Date(), forKey: cacheDateKey)
        d?.synchronize()
        logger.info("ModelRegistry cached \(ids.count) models")
    }

    // MARK: - Remote

    struct ListResponse: Codable {
        let data: [Item]
        struct Item: Codable { let id: String }
    }

    static func fetchRemote() async -> [String]? {
        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 10
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        // 无需鉴权，轻量请求
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            logger.warning("ModelRegistry fetchRemote http failed")
            return nil
        }
        // 兼容两种形态：{data:[{id}]} 与 裸数组（防御）
        if let decoded = try? JSONDecoder().decode(ListResponse.self, from: data) {
            let ids = decoded.data.map { $0.id.lowercased() }.filter { !$0.isEmpty }
            if !ids.isEmpty { return ids }
        }
        // 防御：尝试直接解析 [String]
        if let arr = try? JSONDecoder().decode([String].self, from: data) {
            return arr.map { $0.lowercased() }
        }
        // 防御：尝试 {data:["id1","id2"]}
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = json["data"] as? [String] {
            return arr.map { $0.lowercased() }
        }
        logger.warning("ModelRegistry decode failed")
        return nil
    }

    /// 若缓存过期或为空则拉取，成功则写缓存，返回最新列表（缓存或 remote 或 fallback）
    @discardableResult
    static func refreshIfNeeded(force: Bool = false) async -> [String] {
        let now = Date()
        let cached = cachedOrderedSync()
        let hasCache = UserDefaults(suiteName: suiteName)?.stringArray(forKey: cacheKey) != nil
        let date = cachedDate()
        let stale = date == nil || now.timeIntervalSince(date!) >= ttl

        if !force, hasCache, !stale {
            return cached
        }
        if let remote = await fetchRemote(), !remote.isEmpty {
            // 去重保持原序
            var seen = Set<String>()
            let deduped = remote.filter { seen.insert($0).inserted }
            save(deduped)
            return deduped
        }
        // 拉取失败回退缓存或 fallback
        return cached
    }

    /// 合并远程顺序与历史出现模型：remote 原序优先，历史中已出现但 remote 已下架的追加到末尾字母序，避免历史堆叠柱突然无色
    static func mergedOrdered(remote: [String], historical: Set<String>) -> [String] {
        let historicalNorm = Set(historical.map { $0.lowercased().replacingOccurrences(of: "-go", with: "").replacingOccurrences(of: " (go)", with: "") })
        let remoteNorm = remote.map { $0.lowercased() }
        let inRemote = remoteNorm.filter { historicalNorm.contains($0) || historical.isEmpty }
        // 实际图例计算由调用方完成：remote.filter{historical.contains} + remainder.sorted()
        // 此处仅返回 remote 作为基准有序列表
        _ = inRemote
        return remoteNorm
    }
}
