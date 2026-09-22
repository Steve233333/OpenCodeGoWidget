import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WidgetKit
import Charts

// 自检/大体检的行视图。2026-09-23 Phase 2 从 App.swift 拆出。

struct HealthCheckRow: View {
    @State private var items: [HealthItem]?
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("环境自检").font(.system(size: 9)).foregroundStyle(.secondary)
                if running { ProgressView().scaleEffect(0.5).frame(width: 12, height: 12) }
                Spacer()
                Button("复制报告") { copyReport() }
                    .controlSize(.mini)
                    .disabled(items == nil)
                Button(items == nil ? "开始自检" : "收起") {
                    if let _ = items {
                        items = nil
                    } else {
                        Task {
                            running = true
                            items = await HealthCheck.run()
                            running = false
                        }
                    }
                }
                .controlSize(.mini)
            }
            if let items {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(items) { item in
                            Text("\(item.symbol) \(item.title)：\(item.detail)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(item.level == .fail ? Color.red
                                                 : (item.level == .warn ? Color.orange : Color.primary))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 150)
                .padding(6)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func copyReport() {
        guard let items else { return }
        let text = items.map { "\($0.symbol) \($0.title)：\($0.detail)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 小组件自检：一键看清共享通道卡在哪（App Group 容器 / 备用通道 / 偏好域），
/// 顺便提供「重写快照」把三条通道重新灌一遍。坏机器上用户点一下就能把结论贴出来。
struct WidgetSelfCheckRow: View {
    @State private var report: String?
    @State private var actionNote: String?
    @State private var confirmWipe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("小组件自检").font(.system(size: 9)).foregroundStyle(.secondary)
                if let note = actionNote {
                    Text(note).font(.system(size: 9)).foregroundStyle(note.contains("失败") ? .red : .green)
                }
                Spacer()
                Button("重写快照") {
                    guard let snap = WidgetDataStore.load() else {
                        actionNote = "没有快照可写，请先点主界面刷新"
                        return
                    }
                    actionNote = WidgetDataStore.save(snap) ? "三条通道已重写 ✅" : "写盘失败 ❌"
                    if report != nil { report = WidgetDataStore.diagnose() }
                }
                .controlSize(.mini)
                Button(report == nil ? "自检" : "收起") {
                    report = report == nil ? WidgetDataStore.diagnose() : nil
                }
                .controlSize(.mini)
                // 2026-09-20：换账号后本机这份用量数据必须先清掉，否则旧账号的历史会被"保留旧天"
                // 的增量逻辑留在图上（两个账号的数据串在一起）。这里给个手动入口。
                Button("清除用量缓存") { confirmWipe = true }
                    .controlSize(.mini)
                    .alert("清除本机用量缓存？", isPresented: $confirmWipe) {
                        Button("清除", role: .destructive) {
                            let removed = WidgetDataStore.wipeUsageCache()
                            actionNote = removed ? "已清空，回主界面点「刷新」重建 ✅" : "本来就没有缓存"
                            NotificationCenter.default.post(name: .openCodeGoCredentialsChanged, object: nil)
                            if report != nil { report = WidgetDataStore.diagnose() }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("会删掉本机存的历史用量/费用/密钥列表（cookies 和 Key 保留）。换账号后建议清一次，避免显示上一个账号的数字。")
                    }
            }
            if let report {
                ScrollView {
                    Text(report)
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 130)
                .padding(6)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
