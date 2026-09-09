import SwiftUI
import BridgeCore
import BridgeRuntime

public struct MenuView: View {
    @ObservedObject var controller: BridgeController
    @State private var tab = 0
    @State private var showAllTime = false

    public init(controller: BridgeController, initialTab: Int = 0) {
        self.controller = controller
        self._tab = State(initialValue: initialTab)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 24, weight: .semibold)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Copilot Bridge").font(.headline)
                    Text("本地模型桥接 · Apple Silicon").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(controller.state == .running ? .green : controller.state == .failed ? .red : .secondary)
                    .frame(width: 7, height: 7)
                Text(controller.state.rawValue).font(.caption)
            }.padding(16)
            Picker("页面", selection: $tab) {
                Text("概览").tag(0); Text("设置").tag(1); Text("日志").tag(2)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let login = controller.login { loginCard(login) }
                    if !controller.message.isEmpty {
                        Label(controller.message, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    switch tab {
                    case 1: settings
                    case 2: diagnostics
                    default: overview
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text(Bundle.main.bundleIdentifier == "com.hyspace.copilot-bridge-menubar"
                     ? "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                     : "Development preview")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("退出 App 并停止其服务") { controller.quit() }.buttonStyle(.borderless).font(.caption)
            }.padding(12)
        }.frame(width: 420, height: 620)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(controller.endpoint).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        if controller.isActive {
                            Button("停止") { controller.stop() }
                            Button("重启") { controller.stop(restart: true) }
                                .disabled(controller.state == .stopping)
                        } else {
                            Button("启动服务") { controller.start() }.buttonStyle(.borderedProminent)
                        }
                        Spacer()
                        Button("复制参考配置") { controller.copyReference() }.controlSize(.small)
                        if let pid = controller.servicePID { Text("PID \(pid)").font(.caption).foregroundStyle(.secondary) }
                    }
                    if controller.hasUnsavedChanges {
                        Text("运行中的配置与编辑值不同；保存后重启才会应用。").font(.caption).foregroundStyle(.orange)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } label: { Label("后台服务", systemImage: "server.rack") }

            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("查看累计（保留最近 730 天）", isOn: $showAllTime).toggleStyle(.switch).controlSize(.small)
                    let usage = showAllTime ? controller.total : controller.today
                    HStack(spacing: 18) {
                        metric("输入 tokens", usage.input)
                        metric("输出 tokens", usage.output)
                        metric("缓存命中", usage.cached)
                    }
                    Divider()
                    Text("\(usage.requests) 次上游请求 · \(usage.errors) 次错误 · \(usage.unknown) 次无 usage")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("仅统计经本 App 发出的请求。缓存包含在输入中，不重复相加；未知用量不当作零。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } label: { Label(showAllTime ? "累计 token 用量" : "今日 token 用量", systemImage: "chart.bar") }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    if let quota = controller.quota {
                        HStack {
                            Text(quota.title).font(.subheadline)
                            Spacer()
                            Text(quota.unlimited ? "无限" : quota.remaining.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "未知")
                                .font(.system(.title2, design: .rounded).weight(.semibold))
                        }
                        if let percent = quota.percentRemaining, !quota.unlimited {
                            ProgressView(value: min(max(percent, 0), 100), total: 100)
                            Text("剩余 \(percent.formatted(.number.precision(.fractionLength(0...1))))% · 总额 \(quota.entitlement.map { $0.formatted() } ?? "未知")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let used = quota.creditsUsed { Text("API 报告已用 credits：\(used.formatted())").font(.caption) }
                        if let reset = quota.reset { Text("重置时间：\(reset)").font(.caption2).foregroundStyle(.secondary) }
                    } else {
                        Text("启动服务后从 GitHub 查询。").font(.caption).foregroundStyle(.secondary)
                    }
                    if !controller.quotaError.isEmpty {
                        Text(controller.quotaError).font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        if let time = controller.quotaDate { Text("查询于 \(time.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Button(controller.isFetchingQuota ? "查询中…" : "刷新额度") { controller.refreshQuota() }
                            .disabled(controller.isFetchingQuota || controller.state != .running).controlSize(.small)
                    }
                    Text("单位按 GitHub API 返回；不把 credits 换算成美元。").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } label: { Label("GitHub 剩余额度", systemImage: "gauge.with.dots.needle.50percent") }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(controller.loginStatus).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("GitHub 登录 / 重新授权") { controller.signIn() }.disabled(controller.isActive)
                        Spacer()
                    }
                    Text("复用 CLI 的设备授权及 token 自动刷新，不要求安装 Bun。").font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } label: { Label("授权", systemImage: "person.badge.key") }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("监听范围") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("访问", selection: $controller.settings.scope) {
                        Text("仅本机").tag(NetworkScope.local)
                        Text("局域网").tag(NetworkScope.lan)
                    }.pickerStyle(.segmented)
                    HStack {
                        Text("端口")
                        TextField("4142", value: $controller.settings.port, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 100)
                        Spacer()
                    }
                    if controller.settings.scope == .lan {
                        Label("局域网模式要求 X-Bridge-Key。密钥保存在钥匙串中，复制参考配置会包含它。HTTP 未加密，仅用于可信网络，不要做公网端口映射。",
                              systemImage: "exclamationmark.shield")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            GroupBox("CLI 运行选项") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("模型覆盖（留空则使用客户端选择）", text: $controller.settings.model).textFieldStyle(.roundedBorder)
                    Toggle("Auto 模式（仅支持上游 Auto 可用模型）", isOn: $controller.settings.autoMode)
                    Toggle("调试日志 --debug", isOn: $controller.settings.debug)
                    HStack {
                        Text("请求间隔（秒，0 为不限制）").font(.caption)
                        Spacer()
                        TextField("0", value: $controller.settings.rateLimitSeconds, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 70)
                    }
                    Toggle("达到间隔限制时等待，而不是返回 429", isOn: $controller.settings.waitForRateLimit)
                    Text("固定启用 --no-codex-setup、--no-claude-setup、--no-prompt。模型选择由此处或 Codex 完成；不启用会打印密钥的 --show-token。")
                        .font(.caption2).foregroundStyle(.secondary)
                }.toggleStyle(.switch).controlSize(.small)
            }
            GroupBox("账户与网络") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("账号类型", selection: $controller.settings.accountType) {
                        ForEach(AccountType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    TextField("自定义 Copilot HTTPS 上游（可选）", text: $controller.settings.upstreamURL).textFieldStyle(.roundedBorder)
                    TextField("HTTP(S) 代理（可选）", text: $controller.settings.proxyURL).textFieldStyle(.roundedBorder)
                    TextField("NO_PROXY", text: $controller.settings.noProxy).textFieldStyle(.roundedBorder)
                    TextField("VS Code 兼容版本（可选）", text: $controller.settings.vsCodeVersion).textFieldStyle(.roundedBorder)
                    Text("默认清除 COPILOT_TOKEN 和 COPILOT_BASE_URL。GUI 不会自动读取 .zshrc；需要代理时请在这里配置。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            GroupBox("生命周期") {
                VStack(alignment: .leading) {
                    Toggle("打开 App 时启动服务", isOn: $controller.settings.startOnLaunch)
                    Toggle("崩溃后自动重试（限速，10 分钟最多 5 次）", isOn: $controller.settings.automaticRestart)
                    Toggle("登录 macOS 时打开 App", isOn: Binding(
                        get: { controller.loginItemEnabled }, set: { controller.setLoginItem($0) }))
                }.toggleStyle(.switch).controlSize(.small)
            }
            GroupBox("Codex 参考配置") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("保留 OpenAI 登录认证", isOn: $controller.settings.referenceRequiresOpenAIAuth)
                    Toggle("请求推理摘要", isOn: $controller.settings.referenceReasoningSummaries)
                    Button("复制参考配置（不写入文件）") { controller.copyReference() }
                    Text("使用 supports_websockets = false；不会写入无效的 prefer_websockets 字段。")
                        .font(.caption2).foregroundStyle(.secondary)
                }.toggleStyle(.switch).controlSize(.small)
            }
            HStack {
                Button("保存") { _ = controller.save() }
                if controller.isActive {
                    Button("保存并重启 App 自己的服务") {
                        if controller.save() { controller.stop(restart: true) }
                    }.disabled(controller.state == .stopping)
                }
            }
        }
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近 200 行").font(.headline)
                Spacer()
                Button("打开日志目录") { controller.openLogs() }
            }
            Text("日志轮转：每份最多约 2 MB，保留 3 份历史。访问密钥、Bearer 和 GitHub token 会脱敏；不保存模型对话正文或完整请求。")
                .font(.caption).foregroundStyle(.secondary)
            Text(controller.logs.isEmpty ? "尚无 App 管理的服务日志。" : controller.logs.joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func metric(_ title: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted(.number.notation(.compactName))).font(.system(.title3, design: .rounded).weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func loginCard(_ prompt: LoginPrompt) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("GitHub 设备授权").font(.headline)
                Text(prompt.code).font(.system(.title, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                HStack {
                    Button("复制代码") { controller.copyDeviceCode() }
                    Button("打开 GitHub 授权页") { controller.openLogin() }.buttonStyle(.borderedProminent)
                }
                Text("请在 GitHub 确认授权。代码有效至 \(prompt.expires.formatted(date: .omitted, time: .shortened))。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("取消授权并停止") { controller.stop() }.controlSize(.small)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.tint(.orange)
    }
}
