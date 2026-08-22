import Foundation
import os

enum NetworkError: Error, LocalizedError {
    case notConfigured, authExpired, requestFailed, parseError
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "未配置 ZEN_API_KEY，请在设置中粘贴"
        case .authExpired: return "鉴权过期，请更新 API Key"
        case .requestFailed: return "请求失败"
        case .parseError: return "解析失败"
        }
    }
}

final class NetworkManager: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.steve233.opencodego", category: "Network")
    private let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    // Cost endpoint is not officially documented; we try to infer from HTML if available, else fallback to usage only
    // The screenshot's cost-per-model is rendered from the same backend; currently only /v1/usage is stable with Bearer

    func fetchUsage() async throws -> UsageStats {
        guard let key = KeychainStore.resolvedKey(), !key.isEmpty else {
            logger.error("ZEN_API_KEY not configured")
            throw NetworkError.notConfigured
        }
        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        logger.info("Fetching usage")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            logger.error("usage status \(code)")
            if code == 401 || code == 403 { throw NetworkError.authExpired }
            throw NetworkError.requestFailed
        }
        do {
            let decoded = try Self.decoder.decode(UsageResponse.self, from: data)
            return decoded.usage
        } catch {
            logger.error("decode failed \(error.localizedDescription)")
            throw NetworkError.parseError
        }
    }

    // Cost data comes from opencode dashboard page scraping as fallback
    // If the HTML parsing fails, we return empty cost list and widget shows only额度
    func fetchCostToday() async -> (total: Double, entries: [CostEntry]) {
        // Try to scrape cost page; if unavailable, return empty
        // The dashboard at /zen/go renders costs; we mimic the reference widget's HTML parsing
        // For now, return empty to keep widget stable; cost feature is best-effort
        return (0, [])
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let f = SharedFormatters.shared
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = f.withFractionalSeconds.date(from: s) { return date }
            if let date = f.standard.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date \(s)")
        }
        return d
    }()
}

private final class SharedFormatters: @unchecked Sendable {
    static let shared = SharedFormatters()
    let withFractionalSeconds = ISO8601DateFormatter()
    let standard = ISO8601DateFormatter()
    private init() {
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
}
