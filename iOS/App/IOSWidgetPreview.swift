#if DEBUG
import SwiftUI
import WidgetKit

struct IOSWidgetPreviewScreen: View {
    private let entry = IOSWidgetPreviewData.entry()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    IOSPageHeader(title: "组件预览", subtitle: "Debug · 按真实 family 尺寸渲染")

                    section("Small", "158 × 158") {
                        preview(.systemSmall, 158, 158)
                    }
                    .id("small")

                    section("Medium", "338 × 158") {
                        preview(.systemMedium, 338, 158)
                    }
                    .id("medium")

                    section("Large", "338 × 354") {
                        preview(.systemLarge, 338, 354)
                    }
                    .id("large")

                    VStack(alignment: .leading, spacing: 18) {
                        section("Lock Screen · Rectangular", "320 × 76") {
                            preview(.accessoryRectangular, 320, 76)
                        }
                        section("Lock Screen · Circular", "76 × 76") {
                            preview(.accessoryCircular, 76, 76)
                        }
                        section("Lock Screen · Inline", "320 × 28") {
                            preview(.accessoryInline, 320, 28)
                        }
                    }
                    .id("lock")

                    Text("锁屏 family 在真机上由系统做单色/vibrant 渲染；这里是布局预览。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .padding(.bottom, 40)
            }
            .background(IOSTheme.pageBackground)
            .scrollIndicators(.hidden)
            .task {
                guard let target = previewScrollTarget else { return }
                try? await Task.sleep(nanoseconds: 350_000_000)
                proxy.scrollTo(target, anchor: .top)
            }
        }
    }

    private var previewScrollTarget: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-preview-scroll"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private func section<Content: View>(
        _ title: String,
        _ size: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(size)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func preview(_ family: WidgetFamily, _ width: CGFloat, _ height: CGFloat) -> some View {
        OpenCodeGoIOSWidgetView(entry: entry, previewFamily: family)
            .frame(width: width, height: height)
            .background(Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(IOSTheme.stroke, lineWidth: 0.75)
            }
    }
}

private enum IOSWidgetPreviewData {
    static func entry() -> IOSWidgetEntry {
        let calendar = BillingCycle.calendar
        let formatter = ChartFormatters.day
        let today = calendar.startOfDay(for: Date())
        let weights: [(String, Double)] = [
            ("deepseek-v4.1-flash", 0.52),
            ("glm-5.3", 0.21),
            ("kimi-k3", 0.14),
            ("qwen3.8-max", 0.08),
            ("minimax-m3", 0.05),
        ]

        var daily: [DailyCost] = []
        for index in 0..<30 {
            guard let date = calendar.date(byAdding: .day, value: index - 29, to: today) else {
                continue
            }
            let dayTotal = 0.7 + 1.1 * abs(sin(Double(index) * 0.7)) + Double(index % 7) * 0.12
            var entries: [String: Double] = [:]
            for (model, weight) in weights {
                entries[model] = dayTotal * weight
            }
            daily.append(DailyCost(date: formatter.string(from: date), entries: entries))
        }

        let last = daily.last
        let keys = [
            ApiKeyInfo(id: "key_primary", displayName: "个人 - 主 Key"),
            ApiKeyInfo(id: "key_ci", displayName: "个人 - CI"),
        ]

        return IOSWidgetEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                rolling: 8,
                weekly: 13,
                monthly: 74,
                rollingReset: Date().addingTimeInterval(2 * 3_600 + 24 * 60),
                weeklyReset: Date().addingTimeInterval(5 * 86_400),
                monthlyReset: Date().addingTimeInterval(15 * 86_400),
                costTotal: last?.total ?? 0,
                costEntries: last?.entries ?? [:],
                dailyCosts: daily,
                availableKeys: keys,
                updatedAt: Date()
            ),
            state: KeyDirectoryState(
                status: .live,
                keys: keys,
                checkedAt: Date(),
                sessionFingerprint: "preview",
                detail: nil
            )
        )
    }
}
#endif
