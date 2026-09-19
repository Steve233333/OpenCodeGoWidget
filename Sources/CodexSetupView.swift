import SwiftUI
import AppKit

// MARK: - Codex 一键配置（极简：3 栏 + 单按钮，安装/更新已合并）

struct CodexSetupView: View {
    var onOpenLogin: (() -> Void)? = nil
    @StateObject private var installer = CodexInstaller()
    @State private var goKey: String = ""
    @State private var dsKey: String = ""
    @State private var pass: String = ""
    @State private var showGo = false
    @State private var showDS = false
    @State private var showPass = false
    @State private var errorText: String?
    @State private var existingGo: String = ""
    @State private var existingDS: String = ""
    @State private var existingPass: String = ""
    @State private var clearTarget: ClearTarget? = nil

    /// 可清除的密钥（签名密码是本地钥匙串口令，删除会破坏副本签名，不做清除）
    enum ClearTarget: String, Identifiable {
        case go, ds
        var id: String { rawValue }
        var title: String { self == .go ? "OpenCode Go Key" : "DeepSeek Key" }
        var message: String {
            switch self {
            case .go:
                return "将删除已保存的 Go Key（安装目录 env 配置 + Keychain/App Group）。删除后需重新填写并「配置」才能使用 Go 模型，确定？"
            case .ds:
                return "将删除 config.toml 里已保存的 DeepSeek Key。删除后官方 DeepSeek 模型将不可用，确定？"
            }
        }
    }
    // S2(2026-09-04)：运行计时 + 全量日志（之前只看最后2行，长静默阶段像卡死）
    @State private var runStart: Date? = nil
    @State private var elapsedSeconds = 0
    @State private var showFullLog = true
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var canRun: Bool { !installer.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Codex 一键配置")
                    .font(.headline)
                Spacer()
                // 按钮去重（2026-09-19）：这里原来也有一个「浏览器登录自动获取」，
                // 跟上面「Go 额度设置」那一栏的完全重复（调的是同一个登录弹窗）。
                // 统一保留「Go 额度设置」里的那个；这里只留一行提示，避免用户看到两个一样的按钮。
                Text("Go Key 用上方「Go 额度设置」里的「浏览器登录自动获取」")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text("填写后点击「配置」即可完成安装或更新（有旧 Key 时留空自动复用；输入新值即替换）")
                .font(.caption2).foregroundStyle(.secondary)
            // 副本/官方版本对照（只读展示，不触发任何写入）
            HStack(spacing: 4) {
                let ov = installer.status.officialVersion
                let pv = installer.status.patchedVersion
                let state: String = (ov == "-" || pv == "-") ? "未知" : (ov == pv ? "已一致" : "有新版可升")
                Text("官方版 \(ov) / 副本版 \(pv)（\(state)）")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                keyRow(title: "OpenCode Go Key", required: true,
                       placeholder: "sk-...（必填，没有则无法使用 Go 模型）",
                       text: $goKey, show: $showGo, existing: existingGo,
                       onClear: { clearTarget = .go })
                keyRow(title: "DeepSeek Key", required: false,
                       placeholder: "sk-...（可选，官方 deepseek 模型）",
                       text: $dsKey, show: $showDS, existing: existingDS,
                       onClear: { clearTarget = .ds },
                       onPasteFromClipboard: { pasteClipboard(into: $dsKey) })
                keyRow(title: "签名密码", required: true,
                       placeholder: "任意密码（必填，简单密码也可）",
                       text: $pass, show: $showPass, existing: existingPass, isPassword: true,
                       onRandom: randomizePass)
            }

            if let e = errorText {
                Text(e).font(.caption2).foregroundStyle(.red)
            }
            if let code = installer.lastExitCode {
                Text(code == 0 ? "上次配置成功 ✅" : "上次配置失败（\(code)），请查看日志")
                    .font(.caption2).foregroundStyle(code == 0 ? .green : .red)
            }
            if installer.isRunning {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("配置中…已用时 \(formattedElapsed(elapsedSeconds))（重建约需 1~2 分钟，请勿重复点击）")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button(showFullLog ? "收起" : "展开") { showFullLog.toggle() }
                        .controlSize(.mini).buttonStyle(.plain).font(.caption2)
                }
                if showFullLog && !installer.logText.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(installer.logText)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                            Color.clear.frame(height: 1).id("logEnd")
                        }
                        .frame(maxHeight: 170)
                        .onChange(of: installer.logText) { _ in
                            proxy.scrollTo("logEnd", anchor: .bottom)
                        }
                    }
                }
            } else if !installer.logText.isEmpty {
                HStack {
                    Spacer()
                    Button(showFullLog ? "收起日志" : "查看完整日志") { showFullLog.toggle() }
                        .controlSize(.mini).buttonStyle(.plain).font(.caption2)
                }
                if showFullLog {
                    ScrollView {
                        Text(installer.logText)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 170)
                } else {
                    Text(installer.logText.split(separator: "\n").suffix(2).joined(separator: "\n"))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack {
                Spacer()
                Button {
                    configure()
                } label: {
                    if installer.isRunning {
                        HStack(spacing: 6) { ProgressView().scaleEffect(0.6); Text("配置中…") }
                    } else {
                        Text("配置").frame(minWidth: 80)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canRun)
                Spacer()
            }
            .padding(.top, 4)

            if installer.isRunning {
                Button("取消") { installer.cancel() }.controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .onAppear {
            installer.refreshStatus()
            // 缓存已存值，避免 body 每次重算时同步读文件
            reReadExisting()
        }
        .onReceive(installer.$status) { _ in
            // 状态刷新后同步更新已存提示
            reReadExisting()
        }
        // 浏览器登录自动获取后回填 Go Key 输入框（点「配置」才会真正生效）
        .onReceive(NotificationCenter.default.publisher(for: .openCodeGoKeyFetched)) { note in
            if let key = note.object as? String, !key.isEmpty {
                goKey = key
                showGo = false
                errorText = nil
                reReadExisting()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCodeGoStoredKeyCleared)) { _ in
            reReadExisting()
        }
        .alert(item: $clearTarget) { target in
            Alert(
                title: Text("清除 \(target.title)？"),
                message: Text(target.message),
                primaryButton: .destructive(Text("清除")) { performClear(target) },
                secondaryButton: .cancel(Text("取消"))
            )
        }
        .onReceive(tick) { _ in
            if installer.isRunning, let s = runStart {
                elapsedSeconds = Int(Date().timeIntervalSince(s))
            }
        }
        // S3(2026-09-04)：配置成功后自动打开副本（runStart 非空才算本次发起，避免重进页面误触）
        .onReceive(installer.$lastExitCode) { code in
            if code == 0, runStart != nil {
                runStart = nil
                installer.openPatchedApp()
            }
        }
    }

    private func keyRow(title: String, required: Bool, placeholder: String, text: Binding<String>, show: Binding<Bool>, existing: String, isPassword: Bool = false, onClear: (() -> Void)? = nil, onPasteFromClipboard: (() -> Void)? = nil, onRandom: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                if required { Text("*").foregroundStyle(.red).font(.caption2.weight(.bold)) }
                if !existing.isEmpty {
                    Text(isPassword ? "已设 \(existing.count) 位" : "已存 \(masked(existing))")
                        .font(.system(size: 9)).foregroundStyle(.green)
                } else if required {
                    Text("未设置").font(.system(size: 9)).foregroundStyle(.orange)
                } else {
                    Text("未设置").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                if !existing.isEmpty, let onClear {
                    Button("清除") { onClear() }
                        .controlSize(.mini).buttonStyle(.plain).font(.caption2)
                        .foregroundStyle(.red)
                        .help("删除已保存的密钥，之后需重新填写")
                }
                if let onPasteFromClipboard {
                    Button("剪贴板填入") { onPasteFromClipboard() }
                        .controlSize(.mini).buttonStyle(.plain).font(.caption2)
                        .help("把剪贴板内容填入输入框（适合官网只能看一次的新 Key）")
                }
                if let onRandom {
                    Button("随机生成") { onRandom() }
                        .controlSize(.mini).buttonStyle(.plain).font(.caption2)
                        .help("生成一个随机本地签名密码")
                }
                if !text.wrappedValue.isEmpty {
                    Button(show.wrappedValue ? "隐藏" : "显示") { show.wrappedValue.toggle() }
                        .controlSize(.mini).buttonStyle(.plain).font(.caption2)
                }
            }
            HStack(spacing: 6) {
                Group {
                    if show.wrappedValue {
                        TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.system(size: 12))
                    } else {
                        SecureField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.system(size: 12))
                    }
                }
                if !text.wrappedValue.isEmpty {
                    Button { text.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            if text.wrappedValue.isEmpty && !existing.isEmpty {
                Text("留空将沿用已存（\(isPassword ? "\(existing.count)位" : masked(existing))）；输入新值可替换；点右上「清除」删除")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            } else if !text.wrappedValue.isEmpty && !existing.isEmpty {
                Text("点「配置」后将替换已存密钥")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private func masked(_ s: String) -> String {
        guard s.count > 8 else { return "****" }
        return String(s.prefix(4)) + "****" + String(s.suffix(4))
    }

    private func pasteClipboard(into binding: Binding<String>) {
        let s = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { errorText = "剪贴板里没有文本"; return }
        binding.wrappedValue = s
        errorText = nil
    }

    private func randomizePass() {
        let chars = Array("abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789")
        pass = String((0..<12).map { _ in chars.randomElement()! })
        showPass = true
    }

    private func reReadExisting() {
        existingGo = CodexInstaller.existingGoKey()
        existingDS = CodexInstaller.existingDSKey() ?? ""
        existingPass = CodexInstaller.existingPass()
    }

    private func performClear(_ target: ClearTarget) {
        switch target {
        case .go:
            _ = CodexInstaller.clearGoKey()
            goKey = ""
            NotificationCenter.default.post(name: .openCodeGoStoredKeyCleared, object: "go")
        case .ds:
            _ = CodexInstaller.clearDSKey()
            dsKey = ""
        }
        installer.refreshStatus()
        reReadExisting()
    }

    private func formattedElapsed(_ s: Int) -> String {
        String(format: "%d:%02d", s / 60, s % 60)
    }

    private func configure() {
        errorText = nil
        let go = goKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let ds = dsKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let pwd = pass.trimmingCharacters(in: .whitespacesAndNewlines)

        // 优先用缓存的已存值，避免重复读盘
        let eGo = existingGo.isEmpty ? CodexInstaller.existingGoKey() : existingGo
        let eDS = existingDS.isEmpty ? (CodexInstaller.existingDSKey() ?? "") : existingDS
        let ePass = existingPass.isEmpty ? CodexInstaller.existingPass() : existingPass
        let existingGo = eGo
        let existingDS = eDS
        let existingPass = ePass

        let effectiveGo = go.isEmpty ? existingGo : go
        let effectiveDS = ds.isEmpty ? existingDS : ds
        let effectivePass = pwd.isEmpty ? existingPass : pwd

        // 必填：Go（DeepSeek 可选，仅 Go 为主入口，留空需有旧 Go）
        if effectiveGo.isEmpty {
            errorText = "OpenCode Go Key 为必填项，请填写"
            return
        }
        if effectivePass.isEmpty {
            errorText = "签名密码为必填项，请填写"
            return
        }
        // 非必填的可选 Key 不校验
        _ = effectiveDS

        // 有 Key 时安装/更新已合并：统一走安装逻辑（留空复用旧 Key）
        // 若已安装则 installer 内部会备份旧配置并复用
        runStart = Date()
        elapsedSeconds = 0
        showFullLog = true
        installer.configure(goKey: go, dsKey: ds, pass: pwd)
    }
}
