import SwiftUI
import BridgeCore
import BridgeRuntime

public struct MenuView: View {
    @ObservedObject var controller: BridgeController
    @State private var tab = 0
    @State private var allTime = false
    @State private var advanced = false
    @State private var codexOptions = false

    public init(controller: BridgeController, initialTab: Int = 0) {
        self.controller = controller
        _tab = State(initialValue: initialTab)
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            tabs
                .padding(.horizontal, PanelLayout.inset)
                .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let prompt = controller.login { authorization(prompt) }
                    if !controller.message.isEmpty { InlineNote(text: controller.message) }
                    switch tab {
                    case 1: preferences
                    case 2: diagnostics
                    default: overview
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(PanelLayout.inset)
            }
            Divider()
            footer
        }
        .frame(width: PanelLayout.width, height: PanelLayout.height)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Copilot Bridge").font(.system(size: 13, weight: .semibold))
                Text("本地模型服务").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 5, height: 5)
                Text(controller.state.rawValue).font(.system(size: 10, weight: .medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Capsule().fill(statusColor.opacity(0.08)))
        }.padding(.horizontal, PanelLayout.inset).padding(.top, 14).padding(.bottom, 12)
    }
    private var statusColor: Color {
        switch controller.state {
        case .running: return .green
        case .failed: return .red
        case .starting, .login, .backoff: return .orange
        default: return .secondary
        }
    }
    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(Array(["概览", "设置", "日志"].enumerated()), id: \.offset) { index, title in
                Button { tab = index } label: {
                    Text(title).font(.system(size: 11, weight: tab == index ? .semibold : .regular))
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(tab == index ? Color(nsColor: .controlBackgroundColor) : .clear))
                }.buttonStyle(.plain)
            }
        }.padding(3).background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.045)))
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(controller.endpoint).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    if let pid = controller.servicePID {
                        Text("PID \(pid)").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 8) {
                    Button {
                        controller.isActive ? controller.stop() : controller.start()
                    } label: {
                        Label(controller.isActive ? "停止服务" : "启动服务", systemImage: controller.isActive ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(PanelButtonStyle(accent: !controller.isActive))
                        .disabled(controller.state == .stopping)
                    if controller.isActive {
                        Button { controller.stop(restart: true) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(PanelButtonStyle()).help("重启此 App 管理的服务")
                            .disabled(controller.state == .stopping)
                    }
                    Button { controller.copyReference() } label: { Label("Codex 配置", systemImage: "doc.on.doc") }
                        .buttonStyle(PanelButtonStyle()).help("复制参考配置，不改写文件")
                }
                if controller.hasUnsavedChanges { InlineNote(text: "设置已修改，保存并重启后生效。", warning: true) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading("Token 用量") {
                    HStack(spacing: 2) {
                        periodButton("今日", selected: !allTime) { allTime = false }
                        periodButton("累计", selected: allTime) { allTime = true }
                    }.padding(2).background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.035)))
                }
                let usage = allTime ? controller.total : controller.today
                HStack(spacing: 0) {
                    metric("输入", usage.input)
                    metric("输出", usage.output)
                    metric("已报告缓存", usage.cached)
                }
                HStack(spacing: 5) {
                    Text("\(usage.requests) 次请求  ·  \(usage.errors) 次错误  ·  \(usage.unknown) 次无用量数据")
                    Spacer(minLength: 0)
                    Image(systemName: "info.circle").help("只统计本 App 的上游请求。缓存包含在输入内；缺少 usage 不会伪装成已测量的零。累计保留 730 天。")
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Divider()
            quota
            Divider()
            HStack(spacing: 9) {
                Image(systemName: "person.crop.circle").font(.system(size: 19)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("GitHub 授权").font(.system(size: 11, weight: .medium))
                    Text("凭据由 Bridge CLI 管理").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("登录 / 授权") { controller.signIn() }
                    .buttonStyle(PanelButtonStyle()).disabled(controller.isActive)
                    .help(controller.isActive ? "先停止服务，再重新授权" : controller.loginStatus)
            }
        }
    }

    private var quota: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(controller.quota?.title ?? "GitHub credits") {
                Button { controller.refreshQuota() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                        .frame(width: 22, height: 20)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(controller.isFetchingQuota || controller.state != .running)
                    .help(controller.isFetchingQuota ? "查询中" : "刷新 GitHub 剩余额度")
            }
            if let value = controller.quota {
                HStack(alignment: .firstTextBaseline) {
                    Text(value.unlimited ? "不限" : value.remaining.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "—")
                        .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("剩余").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if let percent = value.percentRemaining, !value.unlimited {
                        Text(percent.formatted(.number.precision(.fractionLength(0...1))) + "%")
                            .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let percent = value.percentRemaining, !value.unlimited {
                    ProgressView(value: min(max(percent, 0), 100), total: 100).controlSize(.small)
                }
                HStack {
                    Text(value.entitlement.map { "总额 " + $0.formatted() } ?? "总额未知")
                    Spacer()
                    if let date = controller.quotaDate { Text("更新于 " + date.formatted(date: .omitted, time: .shortened)) }
                }.font(.system(size: 9)).foregroundStyle(.secondary)
                if let reset = value.reset {
                    Text("重置：" + reset).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1).help(reset)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("—").font(.system(size: 22, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                    Text("启动服务后读取剩余额度").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if !controller.quotaError.isEmpty { InlineNote(text: controller.quotaError, warning: true) }
        }.help("按 GitHub API 的原始单位显示，不换算成美元。")
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading("连接") { EmptyView() }
                HStack {
                    Text("访问范围").font(.system(size: 11))
                    Spacer()
                    Picker("访问范围", selection: $controller.settings.scope) {
                        Text("仅本机").tag(NetworkScope.local)
                        Text("局域网").tag(NetworkScope.lan)
                    }.labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 154)
                }.frame(height: 28)
                numericRow("端口", value: $controller.settings.port)
                if controller.settings.scope == .lan { InlineNote(text: "内网访问无需密钥；仅用于可信网络，不要暴露到公网。", warning: true) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading("模型与请求") { EmptyView() }
                TextSetting(title: "模型覆盖", placeholder: "留空，跟随 Codex 选择", value: $controller.settings.model)
                SettingToggle(title: "Auto 模式", value: $controller.settings.autoMode,
                              hint: "仅支持 Copilot Auto 会话可用的模型")
                numericRow("请求间隔", value: $controller.settings.rateLimitSeconds, suffix: "秒")
                    .help("0 为不限制；对应 --rate-limit")
                SettingToggle(title: "限流时等待", value: $controller.settings.waitForRateLimit,
                              hint: "等待间隔结束，而不是立即返回 429")
                    .disabled(controller.settings.rateLimitSeconds == 0)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                SectionHeading("启动与恢复") { EmptyView() }
                SettingToggle(title: "打开 App 时启动服务", value: $controller.settings.startOnLaunch)
                SettingToggle(title: "异常退出后自动重试", value: $controller.settings.automaticRestart,
                              hint: "指数退避；10 分钟最多重试 5 次")
                SettingToggle(title: "登录 macOS 时打开", value: Binding(
                    get: { controller.loginItemEnabled }, set: { controller.setLoginItem($0) }))
            }
            Divider()
            DisclosureGroup(isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("账号类型").font(.system(size: 11)); Spacer()
                        Picker("账号类型", selection: $controller.settings.accountType) {
                            ForEach(AccountType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().controlSize(.small).frame(width: 148)
                    }
                    TextSetting(title: "HTTP(S) 代理", placeholder: "可选，例如 http://127.0.0.1:7890", value: $controller.settings.proxyURL)
                    TextSetting(title: "不走代理的地址", placeholder: "NO_PROXY", value: $controller.settings.noProxy)
                    TextSetting(title: "自定义 HTTPS 上游", placeholder: "留空使用 Copilot 默认地址", value: $controller.settings.upstreamURL)
                    TextSetting(title: "VS Code 兼容版本", placeholder: "使用 CLI 默认版本", value: $controller.settings.vsCodeVersion)
                    SettingToggle(title: "调试日志", value: $controller.settings.debug)
                    InlineNote(text: "默认清除预设 Copilot token 与上游地址；不读取 shell 配置，不输出明文 token。")
                }.padding(.top, 10)
            } label: { Text("高级选项").font(.system(size: 11, weight: .medium)) }
            DisclosureGroup(isExpanded: $codexOptions) {
                VStack(alignment: .leading, spacing: 3) {
                    SettingToggle(title: "保留 OpenAI 登录认证", value: $controller.settings.referenceRequiresOpenAIAuth)
                    SettingToggle(title: "请求推理摘要", value: $controller.settings.referenceReasoningSummaries)
                    Button("复制参考配置") { controller.copyReference() }.buttonStyle(PanelButtonStyle())
                    InlineNote(text: "仅生成参考，不改写 Codex 或 Claude 配置。交互式选模改由 App 或 Codex 完成。")
                        .padding(.top, 6)
                }.padding(.top, 8)
            } label: { Text("Codex 参考配置").font(.system(size: 11, weight: .medium)) }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("运行日志") {
                Button("打开目录") { controller.openLogs() }.buttonStyle(PanelButtonStyle())
            }
            HStack { Text("最近 200 行"); Spacer(); Text("2 MB × 4 份") }
                .font(.system(size: 9)).foregroundStyle(.secondary)
            if controller.logs.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "text.alignleft").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("还没有运行日志").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("启动服务后，诊断信息会显示在这里。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity).padding(.vertical, 42)
            } else {
                Text(controller.logs.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            InlineNote(text: "凭据会脱敏，不保存对话正文；分享调试日志前仍请检查。")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if tab == 1 {
                Button("保存") { _ = controller.save() }.buttonStyle(PanelButtonStyle(accent: true))
                if controller.isActive {
                    Button("保存并重启") { if controller.save() { controller.stop(restart: true) } }
                        .buttonStyle(PanelButtonStyle()).disabled(controller.state == .stopping)
                }
            } else {
                Text(Bundle.main.bundleIdentifier == "com.hyspace.copilot-bridge-menubar"
                     ? "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") : "开发预览")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Spacer()
            Button { controller.quit() } label: {
                Label("退出", systemImage: "power").font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("退出 App 并停止它管理的服务")
        }.padding(.horizontal, PanelLayout.inset).frame(height: 40)
    }

    private func periodButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 9, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 8).frame(height: 19)
                .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color(nsColor: .controlBackgroundColor) : .clear))
        }.buttonStyle(.plain)
    }
    private func metric(_ title: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted(.number.notation(.compactName)))
                .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func numericRow(_ title: String, value: Binding<Int>, suffix: String = "") -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11)); Spacer()
            TextField(title, value: value, format: .number.grouping(.never))
                .font(.system(size: 11, design: .monospaced)).multilineTextAlignment(.trailing)
                .textFieldStyle(.plain).padding(.horizontal, 8).frame(width: 72, height: 27)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.65)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.10)))
            if !suffix.isEmpty { Text(suffix).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 12) }
        }.frame(height: 30)
    }
    private func authorization(_ prompt: LoginPrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("GitHub 设备授权") {
                Button("取消") { controller.stop() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack {
                Text(prompt.code).font(.system(size: 22, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button { controller.copyDeviceCode() } label: { Image(systemName: "doc.on.doc") }.buttonStyle(PanelButtonStyle())
            }
            Button("打开 GitHub 授权页") { controller.openLogin() }.buttonStyle(PanelButtonStyle(accent: true))
            Text("有效至 " + prompt.expires.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.055)))
    }
}
