import SwiftUI
import BridgeCore
import BridgeRuntime

/// Three compact rows. Account-wide quota details are intentionally separate
/// from the heatmap's gateway-recorded token activity.
struct SourcesSummary: View {
    @ObservedObject var controller: BridgeController
    @State private var expanded: UsageProvider?
    @State private var callback = ""

    private func status(_ provider: UsageProvider) -> SourceStatus? {
        controller.gateway.providers.first { $0.id == provider }
    }
    private func summary(_ provider: UsageProvider) -> String {
        if let s = status(provider), !s.enabled { return "Disabled" }
        if controller.state != .running {
            if provider == .copilot, controller.quota != nil { return "Service stopped · last quota saved" }
            return "Service stopped"
        }
        if status(provider)?.state == "offline" { return "Offline · last known data" }
        switch provider {
        case .codex:
            if controller.gateway.codexLogin?.state == "signing-in" { return "Signing in…" }
            guard controller.gateway.codexLogin?.state == "connected" else { return "Not connected" }
            if let quota = controller.codexQuota {
                let windows = quota.windows.prefix(2).compactMap { window -> String? in
                    guard let remaining = window.remainingPercent else { return nil }
                    return "\(window.title) \(Int(remaining))% left"
                }
                if !windows.isEmpty { return windows.joined(separator: " · ") }
            }
            return "Connected · quota pending"
        case .copilot:
            if let s = status(provider), s.state == "disconnected" { return "Not connected" }
            if let quota = controller.quota {
                let presentation = QuotaPresentation(snapshot: quota)
                if quota.unlimited { return "Unlimited" }
                if quota.kind == .credits, let remaining = presentation.remaining {
                    return ActivityText.number(remaining) + " credits left"
                }
                return presentation.remainingText + " left"
            }
            return status(provider)?.state == "ready" ? "Connected · quota pending" : "Not connected"
        case .local:
            guard let s = status(provider) else { return controller.settings.localEnabled ? "Waiting for service" : "Not configured" }
            if s.state == "offline" { return "Offline" }
            guard let model = s.models.first else { return "No loaded chat model" }
            return model.name.replacingOccurrences(of: " · Local", with: "")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeading("Sources") {
                Button {
                    controller.refreshSources(force: true)
                    controller.refreshQuota()
                    if controller.gateway.codexLogin?.state == "connected" { controller.refreshCodexQuota() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(PanelButtonStyle())
                    .disabled(controller.state != .running || controller.isUpdatingProvider)
                    .help("Refresh provider state and account-wide quotas. This does not change authentication.")
            }
            ForEach(UsageProvider.allCases) { provider in
                VStack(alignment: .leading, spacing: 7) {
                    Button {
                        expanded = expanded == provider ? nil : provider
                    } label: {
                        HStack(spacing: 7) {
                            Circle().fill(controller.state == .running && status(provider)?.state == "ready"
                                          ? Color.green : Color.secondary.opacity(0.45))
                                .frame(width: 5, height: 5)
                            Text(provider.title).fontWeight(.medium).frame(width: 48, alignment: .leading)
                            Text(summary(provider)).font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                            if status(provider)?.stale == true || controller.state != .running {
                                Image(systemName: "clock").foregroundStyle(.orange).help("Last known data; the source is currently unavailable.")
                            }
                            Image(systemName: expanded == provider ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8)).foregroundStyle(.tertiary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(PanelButtonStyle())
                    .accessibilityIdentifier("source-\(provider.rawValue)")
                    if expanded == provider {
                        details(provider)
                            .padding(.horizontal, 7).padding(.bottom, 5)
                    }
                }
            }
            if !controller.gatewayError.isEmpty {
                Text(controller.gatewayError).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private func details(_ provider: UsageProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = status(provider)?.message {
                Text(message).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            switch provider {
            case .codex:
                if let account = controller.gateway.codexLogin?.accountLabel {
                    Text(account).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if let quota = controller.codexQuota {
                    ForEach(quota.windows) { window in
                        if let fraction = window.remainingPercent {
                            HStack { Text(window.title); Spacer(); Text("\(Int(fraction))% remaining").monospacedDigit() }
                                .font(.system(size: 10))
                            QuotaBar(remainingFraction: fraction / 100).frame(height: 5)
                            if let reset = window.resetsAt, reset.isFinite {
                                Text("Resets " + ActivityText.date(Date(timeIntervalSince1970: reset)) + " " + ActivityText.time(Date(timeIntervalSince1970: reset)))
                                    .font(.system(size: 8)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let balance = quota.credits?.balance {
                        Text("Additional credits: " + balance).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Text("Account-wide usage · " + quota.observedAt).font(.system(size: 8)).foregroundStyle(.tertiary)
                }
                if !controller.codexQuotaError.isEmpty { InlineNote(text: controller.codexQuotaError, warning: true) }
                if let message = controller.gateway.codexLogin?.message {
                    Text(message).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                if controller.gateway.codexLogin?.state == "signing-in" && controller.state == .running {
                    if let code = controller.gateway.codexLogin?.code {
                        HStack {
                            Text(code).monospaced().textSelection(.enabled)
                            Button("Copy code") { controller.copyCodexDeviceCode() }.buttonStyle(PanelButtonStyle())
                        }
                    }
                    if controller.gateway.codexLogin?.awaitingCode == true {
                        SecureField("Paste callback URL only if automatic login fails", text: $callback)
                            .textFieldStyle(.roundedBorder).font(.system(size: 10))
                        Button("Complete sign-in") { controller.submitCodexCallback(callback); callback = "" }
                            .buttonStyle(PanelButtonStyle()).disabled(callback.isEmpty || controller.isUpdatingProvider)
                    }
                    Button("Cancel sign-in") { controller.cancelCodexLogin(); callback = "" }
                        .buttonStyle(PanelButtonStyle()).disabled(controller.isUpdatingProvider)
                } else {
                    HStack {
                        Button(controller.gateway.codexLogin?.state == "connected" ? "Reconnect…" : "Connect…") {
                            controller.connectCodex()
                        }.buttonStyle(PanelButtonStyle())
                        Button("Device code…") { controller.connectCodex(device: true) }.buttonStyle(PanelButtonStyle())
                        if controller.gateway.codexLogin?.state == "connected" {
                            Button("Disconnect") { controller.disconnectCodex() }.buttonStyle(PanelButtonStyle())
                        }
                    }.disabled(controller.state != .running || controller.isUpdatingProvider
                               || status(provider)?.enabled == false)
                }
                Text("Independent account. Codex App's existing sign-in is not changed.")
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            case .copilot:
                if let quota = controller.quota {
                    QuotaAmounts(snapshot: quota)
                    if let reset = quota.reset { Text("Resets: " + reset).font(.system(size: 9)).foregroundStyle(.secondary) }
                    if let date = controller.quotaDate {
                        Text("Last checked " + ActivityText.date(date) + " " + ActivityText.time(date))
                            .font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
                if !controller.quotaError.isEmpty { InlineNote(text: controller.quotaError, warning: true) }
                Text("Manage GitHub authorization in Settings. Account quota includes other clients.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            case .local:
                ForEach(status(provider)?.models ?? []) { model in
                    Text(model.id).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                    if let context = model.contextWindow {
                        Text("Runtime context: \(context.formatted(.number.locale(ActivityText.locale))) tokens")
                            .font(.system(size: 10))
                    }
                    HStack(spacing: 8) {
                        capability("Vision", model.declared?.vision)
                        capability("Tools", model.declared?.tools)
                        capability("Parallel", model.declared?.parallelTools)
                    }
                }
                Text("Server-declared capabilities, not a Computer Use certification. Unsupported tools are not silently discarded.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Text("Search uses a Studio-native adapter. Cached-only search, filters, or an endpoint with no executed search results produce an explicit error.")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Text("No subscription quota. Token activity is recorded separately.")
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            }
        }
    }
    private func capability(_ name: String, _ value: Bool?) -> some View {
        Label(name, systemImage: value == true ? "checkmark.circle" : value == false ? "minus.circle" : "questionmark.circle")
            .font(.system(size: 8)).foregroundStyle(value == true ? Color.secondary : Color.orange)
    }
}
