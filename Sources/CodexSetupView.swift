import SwiftUI
import AppKit

// MARK: - Codex 一键配置 设置页

struct CodexSetupView: View {
    @StateObject private var installer = CodexInstaller()
    @State private var mode: CodexInstallMode = .install
    @State private var goKey: String = ""
    @State private var dsKey: String = ""
    @State private var glmKey: String = ""
    @State private var pass: String = ""
    @State private var skipPatch = false
    @State private var skipProxyStart = false
    @State private var showGo = false
    @State private var showDS = false
    @State private var showGLM = false
    @State private var showPass = false
    @State private var hasLoadedExisting = false
    @State private var showHelp = false

    // 从 Status 派生的提示
    private var canRun: Bool { !installer.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusCard
            Divider()
            form
            options
            actionRow
            logView
            footer
        }
        .padding(16)
        .frame(width: 560, height: 640)
        .onAppear {
            installer.refreshStatus()
            if !hasLoadedExisting {
                preloadExisting()
                // 根据是否已安装自动选模式
                if installer.status.isInstalled { mode = .update }
                hasLoadedExisting = true
            }
        }
        .onChange(of: installer.status.isInstalled) { _, v in
            if v && goKey.isEmpty && dsKey.isEmpty { mode = .update }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex 一键配置").font(.headline)
                Text("在小组件设置内完成 Go / DeepSeek / GLM 三 Key 配置、视觉代理与双开副本安装")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                installer.refreshStatus()
            } label: {
                Label("刷新状态", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            Button {
                showHelp.toggle()
            } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.plain)
            .help("查看说明")
            .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                helpPopover
                    .padding(12)
                    .frame(width: 380)
            }
        }
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("填写说明").font(.caption.weight(.semibold))
            Text("• Go 与 DeepSeek 至少填一个；留空则沿用已安装的旧 Key（与原安装器一致）\n• GLM 为智谱视觉 Key，缺它时文本正常、发图失败，可稍后补填\n• 签名密码 ≥4 位且≠0000，存于 ~/.codex/picker-patch/.keychain-pass，副本升级复用\n• 更新模式无需重填 Key，一键同步最新模板/视觉代理/补丁脚本")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            Text("安装后产物").font(.caption2.weight(.semibold))
            Text("~/.codex-deepseek/ 副本配置 · ~/Applications/ChatGPT-Patched.app 双开 · ~/.local/share/agent-vision-toolkit/ 视觉代理 (19100) · ~/.codex/picker-patch/ 补丁工程")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    // MARK: - 状态卡

    private var statusCard: some View {
        let s = installer.status
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(s.isInstalled ? "已安装" : "未安装", systemImage: s.isInstalled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(s.isInstalled ? .green : .orange)
                Spacer()
                Text("模型 \(s.modelCount) · 默认 \(s.defaultModel)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if s.proxyRunning {
                    Text("代理 ●").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                } else {
                    Text("代理 ○").font(.caption2).foregroundStyle(.secondary)
                }
            }
            // 三行细节
            HStack(spacing: 10) {
                statusChip("配置", s.configExists)
                statusChip("env", s.envExists)
                statusChip("副本", s.patchedExists)
                statusChip("GLM", s.hasGLM)
                statusChip("Go", s.hasGo)
                statusChip("DeepSeek", s.hasDS)
                Spacer()
                if s.patchedExists {
                    Text("副本版本 \(s.patchedVersion)").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            if s.isInstalled {
                HStack(spacing: 12) {
                    Button("打开配置目录") { installer.openConfigFolder() }.controlSize(.mini)
                    Button("打开双开副本") { installer.openPatchedApp() }.controlSize(.mini)
                    Button("打开日志") { installer.openLogFile() }.controlSize(.mini)
                    Spacer()
                    Text(s.logPath).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            } else {
                Text("未检测到 ~/.codex-deepseek/config.toml 与 ~/.config/agent-vision-toolkit/env，建议走 安装 模式")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func statusChip(_ label: String, _ ok: Bool) -> some View {
        HStack(spacing: 3) {
            Circle().fill(ok ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9))
        }
    }

    // MARK: - 表单

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("模式").font(.caption.weight(.semibold))
                Picker("", selection: $mode) {
                    ForEach(CodexInstallMode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Spacer()
                if mode == .update {
                    Text("复用旧 Key，无需重填").font(.caption2).foregroundStyle(.green)
                } else {
                    Text("留空沿用旧 Key").font(.caption2).foregroundStyle(.secondary)
                }
            }

            keyRow(title: "① OpenCode Go / Zen Key",
                   placeholder: "sk-...（缺它则 *-go 模型不安装）",
                   text: $goKey, show: $showGo, existing: CodexInstaller.existingGoKey())

            keyRow(title: "② DeepSeek 官方 Key",
                   placeholder: "sk-...（缺它则官方 deepseek-v4 不显示）",
                   text: $dsKey, show: $showDS, existing: CodexInstaller.existingDSKey() ?? "")

            keyRow(title: "③ 智谱 GLM 视觉 Key",
                   placeholder: "1234.xxxx（缺它发图失败，文本不受影响）",
                   text: $glmKey, show: $showGLM, existing: CodexInstaller.existingGLMKey())

            keyRow(title: "签名钥匙串密码",
                   placeholder: "自定义 ≥4位 ≠0000，存于 .keychain-pass (600)",
                   text: $pass, show: $showPass, existing: CodexInstaller.existingPass(),
                   isPassword: true)
        }
    }

    private func keyRow(title: String, placeholder: String, text: Binding<String>, show: Binding<Bool>, existing: String, isPassword: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.caption2.weight(.semibold))
                if !existing.isEmpty {
                    Text(isPassword ? "已设 \(existing.count) 位" : "已存 \(masked(existing))")
                        .font(.system(size: 9)).foregroundStyle(.green)
                    Button("清空") { text.wrappedValue = "" }.controlSize(.mini).buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    Text("未设置").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(show.wrappedValue ? "隐藏" : "显示") { show.wrappedValue.toggle() }
                    .controlSize(.mini).buttonStyle(.plain).font(.caption2)
            }
            HStack(spacing: 6) {
                Group {
                    if show.wrappedValue {
                        TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.caption2)
                    } else {
                        SecureField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.caption2)
                    }
                }
                if !text.wrappedValue.isEmpty {
                    Button {
                        text.wrappedValue = ""
                    } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                }
            }
            if text.wrappedValue.isEmpty && !existing.isEmpty {
                Text("留空将沿用旧值（\(isPassword ? "\(existing.count)位" : masked(existing))）")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func masked(_ s: String) -> String {
        guard s.count > 8 else { return "****" }
        return String(s.prefix(4)) + "****" + String(s.suffix(4)) + " (\(s.count)位)"
    }

    // MARK: - 选项

    private var options: some View {
        HStack(spacing: 16) {
            Toggle("跳过重建副本 (--skip-patch)", isOn: $skipPatch).font(.caption2).toggleStyle(.checkbox)
            Toggle("仅生成配置不启动代理 (--skip-proxy-start)", isOn: $skipProxyStart).font(.caption2).toggleStyle(.checkbox)
            Spacer()
        }
    }

    // MARK: - 操作

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                run()
            } label: {
                if installer.isRunning {
                    HStack(spacing: 6) { ProgressView().scaleEffect(0.5); Text("执行中…") }
                } else {
                    Label(mode == .update ? "一键更新" : "开始安装", systemImage: mode == .update ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canRun)

            Button("取消") { installer.cancel() }
                .controlSize(.small)
                .disabled(!installer.isRunning)

            Button("清空日志") { installer.logText = "" }
                .controlSize(.small)

            Button("复制日志") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(installer.logText, forType: .string)
            }
            .controlSize(.small)

            Spacer()

            if let code = installer.lastExitCode {
                Text(code == 0 ? "上次成功" : "上次失败 \(code)")
                    .font(.caption2).foregroundStyle(code == 0 ? .green : .red)
            }
        }
    }

    private func run() {
        installer.run(mode: mode, goKey: goKey, dsKey: dsKey, glmKey: glmKey, pass: pass, skipPatch: skipPatch, skipProxyStart: skipProxyStart)
    }

    // MARK: - 日志

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("执行日志").font(.caption2.weight(.semibold))
                Spacer()
                Text(CodexInstaller.bundledInstallerPath() ?? "未找到安装器")
                    .font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    Text(installer.logText.isEmpty ? "就绪。点击 开始安装 / 一键更新 后，此处将流式显示安装器输出（同 ~/Library/Logs/codex-oneclick-setup.log）" : installer.logText)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .id("logEnd")
                }
                .frame(height: 170)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                .onChange(of: installer.logText) { _, _ in
                    withAnimation { proxy.scrollTo("logEnd", anchor: .bottom) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("提示：证书为本机自签，更新时自动复用；全部 Key 仅写本机 600 权限文件，不上传")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer()
            Button("在终端打开安装器") {
                if let p = CodexInstaller.bundledInstallerPath() {
                    NSWorkspace.shared.open(URL(fileURLWithPath: p))
                }
            }.controlSize(.mini).buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    private func preloadExisting() {
        // 预填时不直接填入 SecureField（留空即复用），仅用于已存提示
        // 但若用户是从 Widget 的 Go Key 改过，需同步显示
        // 保持空，让用户按需填写；密码同理
    }
}
