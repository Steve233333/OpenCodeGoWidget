import SwiftUI
import WidgetKit

struct IOSSettingsPage: View {
    @ObservedObject var account: ConsoleAccountModel
    @ObservedObject var usage: IOSUsageController
    let onRelogin: () -> Void

    @EnvironmentObject private var themeStore: IOSThemeStore

    @AppStorage(IOSPreferences.autoRefreshKey) private var autoRefresh = true
    @AppStorage(IOSPreferences.backgroundRefreshKey) private var backgroundRefresh = true
    @AppStorage(IOSPreferences.appearanceKey) private var appearance = IOSAppearance.system.rawValue

    @State private var confirmSignOut = false
    @State private var showDiagnostics = false
    @State private var showPrivacy = false

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.16"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "17"
        return "\(short) (\(build))"
    }

    private var selectedColorTheme: IOSColorTheme {
        themeStore.theme
    }

    private var syncText: String {
        usage.snapshot?.updatedAt.formatted(date: .omitted, time: .shortened) ?? "尚未同步"
    }

    private var snapshotStatus: String {
        usage.snapshot == nil ? "尚未写入" : "已共享 · \(syncText)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                IOSPageHeader(title: "设置", subtitle: "账号与同步")

                accountCard
                syncCard
                appearanceCard
                widgetCard
                aboutCard

                Button(role: .destructive) {
                    confirmSignOut = true
                } label: {
                    Text("退出登录")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .foregroundStyle(IOSTheme.danger)
                        .background(IOSTheme.danger.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: IOSTheme.Radius.control, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 96)
        }
        .background(IOSTheme.pageBackground)
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog(
            "退出登录？",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("退出登录", role: .destructive) {
                account.signOut()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清除本机 Keychain 中的登录信息；本地用量缓存会保留。")
        }
        .sheet(isPresented: $showDiagnostics) {
            IOSDiagnosticsSheet(account: account, usage: usage)
        }
        .sheet(isPresented: $showPrivacy) {
            IOSPrivacySheet()
        }
    }

    private var accountCard: some View {
        IOSCard {
            HStack(spacing: 12) {
                BrandIconView(size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("OpenCode 控制台")
                        .font(.subheadline.weight(.semibold))
                    Text(account.isLoggedIn ? "已登录 · \(syncText) 同步" : "未登录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Button("重新登录", action: onRelogin)
                    .buttonStyle(IOSActionButtonStyle())
            }
        }
    }

    private var syncCard: some View {
        IOSCard(padding: 0) {
            VStack(spacing: 0) {
                sectionLabel("同步")

                toggleRow(
                    "自动刷新",
                    detail: "回到 App 或下拉时按需同步",
                    isOn: $autoRefresh
                )

                divider

                toggleRow(
                    "后台刷新",
                    detail: "由 iOS 决定实际执行时间",
                    isOn: $backgroundRefresh
                )
                .onChange(of: backgroundRefresh) { _, enabled in
                    IOSBackgroundRefresh.setEnabled(enabled)
                }

                divider
                syncRow
            }
        }
    }

    private var syncRow: some View {
        Button {
            Task { await usage.refresh() }
        } label: {
            HStack(spacing: 10) {
                Text("立即同步")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if usage.loading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(syncText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(usage.loading)
    }

    private var appearanceCard: some View {
        IOSCard(padding: 0) {
            VStack(spacing: 0) {
                sectionLabel("外观")
                HStack(spacing: 12) {
                    Text("主题")
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    Picker("主题", selection: $appearance) {
                        ForEach(IOSAppearance.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 230)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                divider
                colorThemePicker
            }
        }
    }

    private var colorThemePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("色系")
                    .font(.subheadline)
                Spacer(minLength: 8)
                Text(selectedColorTheme.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                spacing: 10
            ) {
                ForEach(IOSColorTheme.allCases) { theme in
                    Button {
                        themeStore.select(theme)
                    } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                Circle()
                                    .fill(theme.swatch)
                                    .frame(width: 30, height: 30)
                                if theme == selectedColorTheme {
                                    Circle()
                                        .stroke(Color.primary, lineWidth: 2)
                                        .frame(width: 30, height: 30)
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Color.black.opacity(0.62))
                                }
                            }
                            Text(theme.name)
                                .font(.system(size: 10))
                                .foregroundStyle(
                                    theme == selectedColorTheme ? Color.primary : Color.secondary
                                )
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("色系 \(theme.name)")
                    .accessibilityAddTraits(theme == selectedColorTheme ? .isSelected : [])
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var widgetCard: some View {
        IOSCard(padding: 0) {
            VStack(spacing: 0) {
                sectionLabel("小组件")
                settingsRow("主屏与锁屏", value: snapshotStatus)
                divider
                Button {
                    usage.reloadWidget()
                } label: {
                    HStack(spacing: 10) {
                        Text("刷新小组件")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text("立即刷新")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(IOSTheme.brandText)
                    }
                    .frame(minHeight: 52)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var aboutCard: some View {
        IOSCard(padding: 0) {
            VStack(spacing: 0) {
                sectionLabel("关于")
                settingsRow("版本", value: version)
                divider
                actionRow("隐私与数据") { showPrivacy = true }
                divider
                actionRow("诊断") { showDiagnostics = true }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }

    private func toggleRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(IOSTheme.brand)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func settingsRow(_ title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 16)
    }

    private func actionRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 48)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(IOSTheme.stroke)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

private struct IOSDiagnosticsSheet: View {
    @ObservedObject var account: ConsoleAccountModel
    @ObservedObject var usage: IOSUsageController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.16"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "17"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    IOSCard(padding: 0) {
                        VStack(spacing: 0) {
                            row("版本", version)
                            divider
                            row("共享容器", WidgetDataStore.isAppGroupAvailable ? "正常" : "不可用")
                            divider
                            row("共享快照", usage.snapshot == nil ? "尚未写入" : "已写入")
                            divider
                            row("最后同步", usage.snapshot?.updatedAt.formatted(date: .abbreviated, time: .shortened) ?? "尚未同步")
                            divider
                            row("登录状态", account.isLoggedIn ? "已登录" : "未登录")
                        }
                    }

                    IOSCard(padding: 0) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("App Group")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(PlatformConfig.appGroupID)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                            if !account.workspaceID.isEmpty {
                                Text("Workspace")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                                Text(account.workspaceID)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                    }

                    Text("诊断信息只在设置里显示；主界面不暴露容器路径和工作区 ID。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Text("清除登录与本地数据")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .foregroundStyle(IOSTheme.danger)
                            .background(IOSTheme.danger.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: IOSTheme.Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .background(IOSTheme.pageBackground)
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .tint(IOSTheme.brand)
            .confirmationDialog(
                "清除全部本地数据？",
                isPresented: $confirmClear,
                titleVisibility: .visible
            ) {
                Button("全部清除", role: .destructive) {
                    account.clearAllLocalData()
                    usage.clearLocalData()
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会删除 Keychain 登录信息和本地用量缓存，无法恢复。")
            }
        }
        .presentationDetents([.large])
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minHeight: 48)
        .padding(.horizontal, 16)
    }

    private var divider: some View {
        Rectangle()
            .fill(IOSTheme.stroke)
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

private struct IOSPrivacySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("登录与会话")
                        .font(.headline)
                    Text("iOS 版只使用 OpenCode 控制台账号会话读取额度与用量，不保存或要求 Go API Key。会话保存在本机 Keychain。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("小组件")
                        .font(.headline)
                        .padding(.top, 4)
                    Text("主 App 负责同步，主屏和锁屏小组件只读取 App Group 中的用量快照；快照不包含登录凭据。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("本地数据")
                        .font(.headline)
                        .padding(.top, 4)
                    Text("用量缓存用于离线查看历史与图表。退出登录只清除 Keychain 会话；「诊断」里的「清除登录与本地数据」会同时删除缓存。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(IOSTheme.pageBackground)
            .navigationTitle("隐私与数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .tint(IOSTheme.brand)
        }
        .presentationDetents([.medium, .large])
    }
}
