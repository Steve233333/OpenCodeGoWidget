import SwiftUI
import WidgetKit

struct IOSSettingsPage: View {
    @ObservedObject var account: ConsoleAccountModel
    @ObservedObject var usage: IOSUsageController
    let onRelogin: () -> Void
    @State private var confirmClear = false

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.3"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "4"
        return "\(short) (\(build))"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                IOSPageHeader(title: "设置", subtitle: "账号、数据与小组件状态")

                IOSCard {
                    VStack(spacing: 0) {
                        settingsRow("账号", value: account.isLoggedIn ? "已登录" : "未登录")
                        divider
                        settingsRow(
                            "Workspace",
                            value: account.workspaceID.isEmpty
                                ? "未获取"
                                : "\(account.workspaceID.prefix(12))…\(account.workspaceID.suffix(5))"
                        )
                        divider
                        actionRow("重新登录", icon: "person.crop.circle.badge.checkmark", action: onRelogin)
                        divider
                        actionRow(
                            "退出登录",
                            icon: "rectangle.portrait.and.arrow.right",
                            role: .destructive
                        ) {
                            account.signOut()
                        }
                    }
                }

                IOSCard {
                    VStack(spacing: 0) {
                        settingsRow(
                            "最后同步",
                            value: usage.snapshot?.updatedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            ) ?? "尚未同步"
                        )
                        if usage.backfillRunning {
                            divider
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在补齐历史明细")
                                    .font(.subheadline)
                                Spacer()
                            }
                            .padding(.vertical, 11)
                        }
                        divider
                        actionRow(
                            "清除登录与本地数据",
                            icon: "trash",
                            role: .destructive
                        ) {
                            confirmClear = true
                        }
                    }
                }

                IOSCard {
                    VStack(spacing: 0) {
                        settingsRow(
                            "小组件共享",
                            value: WidgetDataStore.isAppGroupAvailable ? "正常" : "不可用"
                        )
                        divider
                        settingsRow(
                            "共享快照",
                            value: usage.snapshot == nil ? "尚未写入" : "已写入"
                        )
                        divider
                        actionRow("立即刷新小组件", icon: "arrow.clockwise") {
                            usage.reloadWidget()
                        }
                    }
                }

                IOSCard {
                    VStack(alignment: .leading, spacing: 10) {
                        IOSSectionTitle(title: "关于", detail: version)
                        Text("iOS 版只使用 OpenCode 账号会话读取额度和用量，不保存 Go API Key。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("主 App 负责同步；主屏和锁屏小组件读取共享快照。后台刷新时间由 iOS 系统决定。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(PlatformConfig.appGroupID)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 80)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .background(IOSTheme.pageBackground)
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog(
            "清除全部本地数据？",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("全部清除", role: .destructive) {
                account.clearAllLocalData()
                usage.clearLocalData()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除 Keychain 登录信息和本地用量缓存，无法恢复。")
        }
    }

    private var divider: some View {
        Divider()
            .overlay(IOSTheme.stroke)
    }

    private func settingsRow(_ title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 11)
    }

    private func actionRow(
        _ title: String,
        icon: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .foregroundStyle(role == .destructive ? IOSTheme.danger : Color.primary)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
