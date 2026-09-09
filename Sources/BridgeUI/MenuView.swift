import SwiftUI
import BridgeCore
import BridgeRuntime

public struct MenuView: View {
    @ObservedObject var controller: BridgeController
    @State private var tab = 0
    @State private var advanced = false

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
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    private var header: some View {
        HStack(spacing: 9) {
            if let image = StatusItemIcon.make() {
                Image(nsImage: image).renderingMode(.template).resizable()
                    .frame(width: 18, height: 18)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.08)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Copilot Bridge").font(.system(size: 13, weight: .semibold))
                Text("GitHub Copilot for Codex App").font(.system(size: 10)).foregroundStyle(.secondary)
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
            ForEach(Array(["Overview", "Settings", "Logs"].enumerated()), id: \.offset) { index, title in
                Button { tab = index } label: {
                    Text(title)
                }
                .buttonStyle(PanelTabButtonStyle(selected: tab == index))
                .accessibilityIdentifier("tab-\(index)")
                .accessibilityAddTraits(tab == index ? .isSelected : [])
            }
        }.padding(3).background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.045)))
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        Label(controller.isActive ? "Stop service" : "Start service", systemImage: controller.isActive ? "stop.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(PanelButtonStyle(accent: !controller.isActive))
                        .disabled(controller.state == .stopping)
                    if controller.isActive {
                        Button { controller.stop(restart: true) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(PanelButtonStyle()).help("Restart only this app’s service")
                            .disabled(controller.state == .stopping)
                    }
                    if controller.codexSwitch.known && controller.codexSwitch.canChange
                        && (!controller.codexSwitch.enabled || controller.codexSwitch.managed) {
                        SettingToggle(title: "Use in Codex", value: Binding(
                            get: { controller.codexToggleValue }, set: { controller.setCodexEnabled($0) }),
                            hint: "Use Copilot Bridge in Codex App. Restart Codex App after switching.")
                            .frame(width: 145).disabled(controller.isUpdatingCodex)
                    } else {
                        Button { tab = 1 } label: { Label("Codex routing", systemImage: "slider.horizontal.3") }
                            .buttonStyle(PanelButtonStyle()).help("Review Codex App routing and configuration backups")
                    }
                }
                if controller.hasUnsavedChanges { InlineNote(text: "Settings changed. Save and restart to apply.", warning: true) }
            }
            Divider()
            quota
            Divider()
            ActivityHeatmap(days: controller.activity)
        }
    }

    private var codexRouting: some View {
        VStack(alignment: .leading, spacing: 4) {
            if controller.codexSwitch.known {
                SettingToggle(title: "Use Copilot Bridge in Codex", value: Binding(
                    get: { controller.codexToggleValue }, set: { controller.setCodexEnabled($0) }),
                    hint: controller.codexConfigPath)
                    .disabled(controller.isUpdatingCodex || !controller.codexSwitch.canChange)
            } else {
                HStack {
                    Text(controller.isUpdatingCodex ? "Checking Codex routing…" : "Codex routing needs attention")
                        .font(.system(size: 11))
                    Spacer()
                    Button("Recheck") { controller.refreshCodexConfiguration() }
                        .buttonStyle(PanelButtonStyle()).disabled(controller.isUpdatingCodex)
                }.frame(minHeight: 30)
            }
            Text(controller.codexSwitch.message).font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Restart Codex App after switching. OpenAI sign-in stays enabled.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private var quota: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(controller.quota?.title ?? "GitHub credits") {
                Button { controller.refreshQuota() } label: {
                    Label(controller.isFetchingQuota ? "Refreshing…" : "Refresh usage", systemImage: "arrow.clockwise")
                }.buttonStyle(PanelButtonStyle())
                    .disabled(controller.isFetchingQuota || controller.state != .running)
                    .help(controller.state != .running ? "Start this app’s service to refresh account usage"
                          : "Fetch account usage from GitHub. This does not change your authorization.")
            }
            if let value = controller.quota {
                QuotaAmounts(snapshot: value)
                HStack {
                    Text(value.entitlement.map { "Limit " + ActivityText.number($0) } ?? "Limit unknown")
                    Spacer()
                    if let date = controller.quotaDate {
                        Text("As of " + (Calendar.current.isDateInToday(date)
                            ? ActivityText.time(date) : ActivityText.date(date) + " " + ActivityText.time(date)))
                    }
                }.font(.system(size: 9)).foregroundStyle(.secondary)
                if let reset = value.reset {
                    Text("Resets: " + reset).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1).help(reset)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("—").font(.system(size: 22, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                    Text("Start the service to check your balance").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if !controller.quotaError.isEmpty { InlineNote(text: controller.quotaError, warning: true) }
        }.help("GitHub account-wide quota in its original units; no dollar conversion.")
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading("Codex App") {
                    Button("Open backups") { controller.openCodexBackups() }.buttonStyle(PanelButtonStyle())
                }
                codexRouting
                Text(controller.codexConfigPath).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled)
                InlineNote(text: "Routing persists when Bridge quits. Only Codex App is supported. Explicit launch or profile overrides may take precedence.")
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading("GitHub account") {
                    Button("Authorize GitHub…") { controller.signIn() }
                        .buttonStyle(PanelButtonStyle())
                        .disabled(controller.isActive)
                        .help("Start a new GitHub device authorization. This is not sign out.")
                }
                Text(controller.loginStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                InlineNote(text: "Authorize again or choose another account on GitHub. Approval replaces saved Bridge credentials; it does not sign out.")
                if controller.isActive {
                    InlineNote(text: "Stop this app’s service before changing authorization.")
                } else {
                    InlineNote(text: "Stop any other Bridge service before changing the shared GitHub authorization.")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading("Connection") { EmptyView() }
                HStack {
                    Text("Access").font(.system(size: 11))
                    Spacer()
                    Picker("Access", selection: $controller.settings.scope) {
                        Text("Local only").tag(NetworkScope.local)
                        Text("LAN").tag(NetworkScope.lan)
                    }.labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 154)
                }.frame(height: 28)
                numericRow("Port", value: $controller.settings.port)
                    .disabled(controller.codexSwitch.enabled || controller.isUpdatingCodex)
                    .help("Switch Codex routing off before changing the port, then turn it on again.")
                if controller.settings.scope == .lan { InlineNote(text: "LAN access has no key. Use trusted networks only; never expose it to the internet.", warning: true) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading("Model & requests") { EmptyView() }
                TextSetting(title: "Bridge model override", placeholder: "Use Codex App’s selected model", value: $controller.settings.model)
                SettingToggle(title: "Auto mode", value: $controller.settings.autoMode,
                              hint: "Only models available in Copilot Auto sessions are supported")
                numericRow("Request interval", value: $controller.settings.rateLimitSeconds, suffix: "s")
                    .help("0 means no interval limit; maps to --rate-limit")
                SettingToggle(title: "Wait when rate-limited", value: $controller.settings.waitForRateLimit,
                              hint: "Wait for the interval instead of returning HTTP 429")
                    .disabled(controller.settings.rateLimitSeconds == 0)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                SectionHeading("Startup & recovery") { EmptyView() }
                SettingToggle(title: "Start service when app opens", value: $controller.settings.startOnLaunch)
                SettingToggle(title: "Retry after an unexpected exit", value: $controller.settings.automaticRestart,
                              hint: "Exponential backoff; up to 5 retries in 10 minutes")
                SettingToggle(title: "Open at login", value: Binding(
                    get: { controller.loginItemEnabled }, set: { controller.setLoginItem($0) }))
            }
            Divider()
            PanelDisclosure(title: "Advanced", expanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Account type").font(.system(size: 11)); Spacer()
                        Picker("Account type", selection: $controller.settings.accountType) {
                            ForEach(AccountType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().controlSize(.small).frame(width: 148)
                    }
                    TextSetting(title: "HTTP(S) proxy", placeholder: "Optional, e.g. http://127.0.0.1:7890", value: $controller.settings.proxyURL)
                    TextSetting(title: "Proxy exclusions", placeholder: "NO_PROXY", value: $controller.settings.noProxy)
                    TextSetting(title: "Custom HTTPS upstream", placeholder: "Leave blank to use the default Copilot endpoint", value: $controller.settings.upstreamURL)
                    TextSetting(title: "VS Code compatibility version", placeholder: "Use the CLI default", value: $controller.settings.vsCodeVersion)
                    SettingToggle(title: "Debug logging", value: $controller.settings.debug)
                    InlineNote(text: "Inherited Copilot tokens and upstream overrides are cleared. No shell configuration is loaded and no credentials are printed.")
                }.padding(.top, 10)
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Service logs") {
                Button("Open folder") { controller.openLogs() }.buttonStyle(PanelButtonStyle())
            }
            HStack { Text("Latest 200 lines"); Spacer(); Text("4 files × 2 MB") }
                .font(.system(size: 9)).foregroundStyle(.secondary)
            if controller.logs.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "text.alignleft").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("No logs yet").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Diagnostics appear here after you start the service.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity).padding(.vertical, 42)
            } else {
                Text(controller.logs.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            InlineNote(text: "Credentials are redacted and conversation content is not stored. Review debug logs before sharing.")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if tab == 1 {
                Button("Save") { _ = controller.save() }.buttonStyle(PanelButtonStyle(accent: true))
                if controller.isActive {
                    Button("Save & restart") { if controller.save() { controller.stop(restart: true) } }
                        .buttonStyle(PanelButtonStyle()).disabled(controller.state == .stopping)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Bundle.main.bundleIdentifier == "com.hyspace.copilot-bridge-menubar"
                         ? "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") : "Development preview")
                        .foregroundStyle(.tertiary)
                    Text("Restart Codex App after switching").foregroundStyle(.secondary)
                }.font(.system(size: 9))
            }
            Spacer()
            Button { controller.quit() } label: {
                Label("Quit", systemImage: "power").font(.system(size: 10))
            }.buttonStyle(PanelButtonStyle(destructive: true)).help("Quit Bridge and stop only its service. Saved Codex routing is not changed.")
        }.padding(.horizontal, PanelLayout.inset).frame(height: 40)
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
            SectionHeading("GitHub device authorization") {
                Button("Cancel") { controller.stop() }.buttonStyle(PanelButtonStyle())
            }
            HStack {
                Text(prompt.code).font(.system(size: 22, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button { controller.copyDeviceCode() } label: { Label("Copy code", systemImage: "doc.on.doc") }.buttonStyle(PanelButtonStyle())
            }
            Button("Open GitHub sign-in") { controller.openLogin() }.buttonStyle(PanelButtonStyle(accent: true))
            Text("Expires at " + ActivityText.time(prompt.expires))
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.055)))
    }
}
