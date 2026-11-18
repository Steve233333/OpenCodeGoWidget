import Foundation

/// 2026-11-18 官方 Console 快照。联网后会整体替换，离线时至少不会退回旧请求表。
enum GoQuotaFallback {
    private static func quota(
        _ slug: String,
        _ name: String,
        goRequests: Int,
        plusRequests: Int,
        goUSD: Double,
        plusUSD: Double,
        note: String? = nil
    ) -> GoQuota {
        GoQuota(
            slug: slug,
            displayName: name,
            requests5hByPlan: [
                GoPlan.go.rawValue: goRequests,
                GoPlan.goPlus.rawValue: plusRequests,
            ],
            monthlyUSDByPlan: [
                GoPlan.go.rawValue: goUSD,
                GoPlan.goPlus.rawValue: plusUSD,
            ],
            note: note
        )
    }

    private static func free(_ slug: String, _ name: String, note: String? = nil) -> GoQuota {
        GoQuota(
            slug: slug,
            displayName: name,
            requests5hByPlan: [:],
            monthlyUSDByPlan: [:],
            note: note
        )
    }

    static let all: [GoQuota] = [
        quota("kimi-k3", "Kimi K3", goRequests: 98, plusRequests: 392, goUSD: 15, plusUSD: 60),
        quota("kimi-k3.1-pro", "Kimi K3.1 Pro", goRequests: 147, plusRequests: 588, goUSD: 15, plusUSD: 60),
        quota("qwen3.8-max", "Qwen3.8 Max", goRequests: 162, plusRequests: 647, goUSD: 15, plusUSD: 60),
        quota("grok-4.7", "Grok 4.7", goRequests: 169, plusRequests: 676, goUSD: 15, plusUSD: 60),
        quota("step-5-preview", "Step 5 Preview", goRequests: 426, plusRequests: 1_700, goUSD: 15, plusUSD: 60),
        quota("qwen4-max", "Qwen4 Max", goRequests: 463, plusRequests: 1_850, goUSD: 15, plusUSD: 60),
        quota("gemini-4-argon", "Gemini 4 Argon", goRequests: 566, plusRequests: 2_260, goUSD: 30, plusUSD: 120),
        quota("glm-5.2", "GLM-5.2", goRequests: 792, plusRequests: 2_370, goUSD: 60, plusUSD: 180),
        quota("kimi-k2.7-code", "Kimi K2.7 Code", goRequests: 994, plusRequests: 2_980, goUSD: 60, plusUSD: 180),
        quota("deepseek-v4-pro", "DeepSeek V4 Pro", goRequests: 1_040, plusRequests: 4_180, goUSD: 15, plusUSD: 60),
        quota("hy4-preview", "Hy4 preview", goRequests: 1_350, plusRequests: 5_410, goUSD: 30, plusUSD: 120),
        quota("gpt-5.6-luna", "GPT-5.6 Luna", goRequests: 2_050, plusRequests: 8_200, goUSD: 15, plusUSD: 60),
        quota("hy4", "Hy4", goRequests: 2_710, plusRequests: 10_800, goUSD: 60, plusUSD: 240),
        quota("minimax-m3", "MiniMax-M3", goRequests: 3_210, plusRequests: 9_620, goUSD: 60, plusUSD: 180),
        quota("mimo-v2.6-pro", "MiMo-V2.6-Pro", goRequests: 3_260, plusRequests: 13_000, goUSD: 15, plusUSD: 60),
        quota("claude-haiku-5-5", "Claude Haiku 5.5", goRequests: 3_850, plusRequests: 15_400, goUSD: 15, plusUSD: 60),
        quota("minimax-m3.1-flash", "MiniMax M3.1 Flash", goRequests: 3_880, plusRequests: 15_500, goUSD: 20, plusUSD: 80),
        quota("gpt-6-luna", "GPT-6 Luna", goRequests: 4_230, plusRequests: 16_900, goUSD: 15, plusUSD: 60),
        quota("hy3", "Hy3", goRequests: 4_300, plusRequests: 17_200, goUSD: 60, plusUSD: 240),
        quota("qwen3.7-plus", "Qwen3.7 Plus", goRequests: 4_310, plusRequests: 12_900, goUSD: 60, plusUSD: 180),
        quota("qwen3.8-flash", "Qwen3.8 Flash", goRequests: 5_400, plusRequests: 16_200, goUSD: 30, plusUSD: 90),
        quota("glm-5.3-flash", "GLM-5.3-Flash", goRequests: 6_320, plusRequests: 18_900, goUSD: 60, plusUSD: 180),
        quota("glm-5.3", "GLM-5.3", goRequests: 6_600, plusRequests: 13_200, goUSD: 500, plusUSD: 1_000),
        quota("longcat-2.0", "LongCat-2.0", goRequests: 11_400, plusRequests: 45_700, goUSD: 60, plusUSD: 240),
        quota("mimo-v2.6-flash", "MiMo-V2.6-Flash", goRequests: 30_100, plusRequests: 60_200, goUSD: 60, plusUSD: 120),
        quota("deepseek-v4.1-flash", "DeepSeek V4.1 Flash 1017", goRequests: 43_300, plusRequests: 86_700, goUSD: 100, plusUSD: 200),
        quota("muse-spark-1.2-contributor", "Muse Spark 1.2 Contributor", goRequests: 45_300, plusRequests: 90_600, goUSD: 60, plusUSD: 120, note: "Limited regions"),
        quota("muse-spark-1.3-contributor", "Muse Spark 1.3 Contributor", goRequests: 45_300, plusRequests: 90_600, goUSD: 60, plusUSD: 120, note: "Limited regions"),
        free("beam-free", "Beam Free", note: "Limited regions · Limited time"),
        free("hy4-flash-free", "Hy4 flash Free", note: "Limited time"),
        free("iceman-contributor-free", "Iceman Contributor Free", note: "Limited time"),
        free("longcat-2.5-free", "LongCat 2.5 Free", note: "Limited time"),
    ]
}
