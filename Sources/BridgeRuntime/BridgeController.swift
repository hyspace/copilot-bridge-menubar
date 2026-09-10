import AppKit
import Foundation
import Combine
import ServiceManagement
import BridgeCore
import Darwin

public enum ServiceState: String { case stopped = "Stopped", starting = "Starting", running = "Running", stopping = "Stopping", login = "Sign-in required", failed = "Failed", backoff = "Retrying" }

@MainActor
public final class BridgeController: ObservableObject {
    @Published public var settings = BridgeSettings()
    @Published public private(set) var state: ServiceState = .stopped
    @Published public private(set) var message = ""
    @Published public private(set) var logs: [String] = []
    @Published public private(set) var login: LoginPrompt?
    @Published public private(set) var today = UsageTotals()
    @Published public private(set) var total = UsageTotals()
    @Published public private(set) var activity: [ActivityDay] = []
    @Published public private(set) var quota: QuotaSnapshot?
    @Published public private(set) var quotaError = ""
    @Published public private(set) var quotaDate: Date?
    @Published public private(set) var loginItemEnabled = false
    @Published public private(set) var isFetchingQuota = false
    @Published public private(set) var gateway = GatewaySnapshot()
    @Published public private(set) var codexQuota: CodexQuota?
    @Published public private(set) var codexQuotaError = ""
    @Published public private(set) var gatewayError = ""
    @Published public private(set) var isFetchingSources = false
    @Published public private(set) var isUpdatingProvider = false
    @Published public private(set) var servicePID: Int32?
    @Published public private(set) var codexSwitch = CodexSwitchStatus()
    @Published public private(set) var isUpdatingCodex = false
    @Published private var pendingCodexValue: Bool?
    private let codexManager: CodexConfigManager
    private let codexHomeError: String?
    private let configQueue = DispatchQueue(label: "com.hyspace.bridge.codex-config")
    private var lastCodexCheck = Date.distantPast
    private var service: Process?
    private var output: ProcessOutput?
    private var pipes: [Pipe] = []
    private var readers: [PipeReader] = []
    private var timer: Timer?
    private var healthTask: Task<Void, Never>?
    private var quotaTask: Task<Void, Never>?
    private var sourcesTask: Task<Void, Never>?
    private var codexQuotaTask: Task<Void, Never>?
    private var authTask: Task<Void, Never>?
    private var controlToken = ""
    private var lastSourceCheck = Date.distantPast
    private var lastCodexQuotaCheck = Date.distantPast
    private var lastOpenedAuthURL: String?
    private var browserLoginRequested = false
    private var restartTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var startedAt = Date()
    private var lastHealth = Date.distantPast
    private var lastQuotaAttempt = Date.distantPast
    private var historyDay = ""
    private var unhealthyCount = 0
    private var instance = ""
    private var currentSettings: BridgeSettings?
    private var authOnly = false
    private var intentionallyStopping = false
    private var pendingRestart = false
    private var quitting = false
    private var restartPolicy = RestartPolicy()
    private var store: UsageStore?
    private let root: URL
    private let session: URLSession
    private let backend: URL?
    private let home: URL
    private let shutdownGrace: TimeInterval
    private let retryScale: Double
    private let healthInterval: TimeInterval
    private let startupTimeout: TimeInterval

    public convenience init(root: URL = AppPaths.root) {
        self.init(root: root,
            backend: Bundle.main.url(forResource: "copilot-bridge-service", withExtension: nil),
            home: FileManager.default.homeDirectoryForCurrentUser,
            launchFromArguments: CommandLine.arguments.contains("--start-service"),
            codexHome: ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap {
                $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil
            },
            codexHomeError: ProcessInfo.processInfo.environment["CODEX_HOME"].map {
                $0.hasPrefix("/") ? nil : "CODEX_HOME must be an absolute path. Codex configuration switching is disabled."
            } ?? nil)
    }

    // Dependency injection is internal and only used by native integration tests.
    // Release callers cannot replace the bundled backend through an environment flag.
    init(root: URL, backend: URL?, home: URL, heartbeat: TimeInterval = 1,
         shutdownGrace: TimeInterval = 5, retryScale: Double = 1, launchFromArguments: Bool = false,
         healthInterval: TimeInterval = 5, startupTimeout: TimeInterval = 90, codexHome: URL? = nil,
         configPlanner: CodexConfigManager.Planner? = nil, codexHomeError: String? = nil) {
        self.root = root
        self.backend = backend
        self.home = home
        self.shutdownGrace = shutdownGrace
        self.retryScale = retryScale
        self.healthInterval = healthInterval
        self.startupTimeout = startupTimeout
        self.codexHomeError = codexHomeError
        let planner = CodexConfigPlanner(executable: backend, home: home)
        codexManager = CodexConfigManager(home: codexHome ?? home.appendingPathComponent(".codex"),
                                         dataRoot: root, planner: configPlanner ?? planner.plan)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.connectionProxyDictionary = [:] // Control calls always stay on loopback.
        session = URLSession(configuration: configuration)
        do {
            try AppPaths.prepare(root)
            settings = try AppPaths.loadSettings(root: root)
            store = try UsageStore(url: root.appendingPathComponent("usage.sqlite"))
            if let observation = try store?.latestQuota() {
                quota = observation.snapshot; quotaDate = observation.observedAt
            }
            if let data = try store?.latestProviderQuota(.codex) {
                codexQuota = try? JSONDecoder().decode(CodexQuota.self, from: data)
            }
            try refreshUsage(forceHistory: true)
        } catch { message = error.localizedDescription }
        loginItemEnabled = SMAppService.mainApp.status == .enabled
        timer = Timer.scheduledTimer(withTimeInterval: heartbeat, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        if settings.startOnLaunch || launchFromArguments { start() }
        refreshCodexConfiguration()
    }

    deinit {
        timer?.invalidate()
        healthTask?.cancel(); quotaTask?.cancel(); restartTask?.cancel(); stopTask?.cancel()
        sourcesTask?.cancel(); codexQuotaTask?.cancel(); authTask?.cancel()
        readers.forEach { $0.stop() }
        session.invalidateAndCancel()
        if let service, service.isRunning { service.terminate() }
    }

    public var isActive: Bool { service != nil || state == .backoff }
    public var endpoint: String { "http://127.0.0.1:\((currentSettings ?? settings).port)/v1" }
    public var hasUnsavedChanges: Bool { currentSettings.map { $0 != settings } ?? false }
    public var canStoreLocalKey: Bool {
        state == .running && currentSettings?.localEnabled == true
            && currentSettings?.localURL == settings.localURL && !isUpdatingProvider
    }
    public var loginStatus: String {
        FileManager.default.fileExists(atPath: home
            .appendingPathComponent(".local/share/copilot-bridge/github_token").path)
            ? "Saved GitHub credentials found; validity is checked when connecting." : "No GitHub credentials found."
    }

    public func save() -> Bool {
        do { try AppPaths.saveSettings(settings, root: root); message = ""; return true }
        catch { message = error.localizedDescription; return false }
    }
    public func start(loginOnly: Bool = false, automatic: Bool = false) {
        guard service == nil, !quitting else { return }
        guard save() else { return }
        if !automatic { restartPolicy.reset() }
        restartTask?.cancel(); restartTask = nil
        if !loginOnly && !portAvailable(settings.port, host: settings.host) {
            state = .failed
            message = "Port \(settings.port) is in use. The existing process will not be stopped or taken over. Choose another port in Settings."
            return
        }
        guard let binary = backend,
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            state = .failed; message = "The bundled Apple Silicon service is missing. Build the complete app with scripts/build-app.sh."; return
        }
        do {
            instance = UUID().uuidString
            let child = Process()
            let stdout = Pipe(), stderr = Pipe()
            let eventToken = UUID().uuidString + UUID().uuidString
            controlToken = UUID().uuidString + UUID().uuidString
            let pump = try ProcessOutput(root: root, secrets: [eventToken, controlToken],
                                         eventToken: eventToken)
            child.executableURL = binary
            let gatewaySettings = try settings.writeGatewaySettings(root: root)
            child.arguments = settings.arguments(authOnly: loginOnly, gatewaySettingsPath: gatewaySettings.path)
            child.environment = settings.environment(inheriting: ProcessInfo.processInfo.environment,
                home: home.path,
                parentPID: ProcessInfo.processInfo.processIdentifier, instance: instance,
                eventToken: eventToken)
            child.environment?["CODEX_BRIDGE_CONTROL_TOKEN"] = controlToken
            if let executable = Bundle.main.executableURL {
                child.environment?["CODEX_BRIDGE_CREDENTIAL_HELPER"] = executable.path
            }
            child.currentDirectoryURL = root
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = stdout; child.standardError = stderr
            let drains = DispatchGroup()
            drains.enter(); drains.enter()
            let outReader = PipeReader(handle: stdout.fileHandleForReading,
                receive: { [weak pump] in pump?.consume($0, error: false) }, closed: { drains.leave() })
            let errReader = PipeReader(handle: stderr.fileHandleForReading,
                receive: { [weak pump] in pump?.consume($0, error: true) }, closed: { drains.leave() })
            readers = [outReader, errReader]
            child.terminationHandler = { [weak self, outReader, errReader] process in
                // Drain the final auth/usage record before publishing exit state.
                drains.notify(queue: .main) { [weak self] in
                    Task { @MainActor [weak self] in self?.didExit(process) }
                }
                // Bound shutdown even if a descendant accidentally retains a pipe FD.
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    outReader.stop(); errReader.stop()
                }
            }
            intentionallyStopping = false
            authOnly = loginOnly; output = pump; pipes = [stdout, stderr]
            currentSettings = settings
            try child.run()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
            service = child; servicePID = child.processIdentifier
            startedAt = Date(); lastHealth = .distantPast; unhealthyCount = 0
            lastQuotaAttempt = .distantPast
            lastSourceCheck = .distantPast; lastCodexQuotaCheck = .distantPast
            gateway = GatewaySnapshot(); gatewayError = ""
            state = .starting; login = nil; message = ""
        } catch {
            closePipes(); service = nil; output = nil; currentSettings = nil
            state = .failed; message = error.localizedDescription
        }
    }

    public func stop(restart: Bool = false) {
        pendingRestart = restart
        restartTask?.cancel(); restartTask = nil
        healthTask?.cancel(); healthTask = nil
        quotaTask?.cancel(); quotaTask = nil; isFetchingQuota = false
        sourcesTask?.cancel(); sourcesTask = nil; isFetchingSources = false
        codexQuotaTask?.cancel(); codexQuotaTask = nil
        authTask?.cancel(); authTask = nil; isUpdatingProvider = false
        guard let service else {
            state = .stopped
            if restart { pendingRestart = false; start() }
            return
        }
        intentionallyStopping = true; state = .stopping
        if service.isRunning { service.terminate() }
        stopTask?.cancel()
        let grace = shutdownGrace
        stopTask = Task { [weak self, weak service] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled, let self, let service,
                  self.service === service, service.isRunning else { return }
            kill(service.processIdentifier, SIGKILL)
        }
    }

    public func signIn() {
        if isActive { message = "Stop this app's service before signing in again, so two processes do not update credentials at once."; return }
        start(loginOnly: true)
    }
    public func openLogin() {
        guard login != nil else { return }
        NSWorkspace.shared.open(URL(string: "https://github.com/login/device")!)
    }
    public func copyDeviceCode() {
        guard let login else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(login.code, forType: .string)
    }
    public var codexConfigPath: String { codexManager.configURL.path }
    public var codexToggleValue: Bool { pendingCodexValue ?? codexSwitch.enabled }
    public var codexConfigPort: Int { (currentSettings ?? settings).port }
    public func openCodexBackups() {
        guard FileManager.default.fileExists(atPath: codexManager.backupsURL.path) else {
            message = "No Codex configuration backups have been created yet."; return
        }
        NSWorkspace.shared.open(codexManager.backupsURL)
    }
    public func refreshCodexConfiguration() {
        guard !isUpdatingCodex else { return }
        if let codexHomeError { codexSwitch.message = codexHomeError; return }
        isUpdatingCodex = true; lastCodexCheck = Date()
        let manager = codexManager, port = codexConfigPort
        configQueue.async { [weak self] in
            let result = manager.status(port: port)
            DispatchQueue.main.async {
                self?.codexSwitch = result; self?.isUpdatingCodex = false
            }
        }
    }
    public func setCodexEnabled(_ enabled: Bool) {
        guard !isUpdatingCodex, !quitting else { return }
        if let codexHomeError { message = codexHomeError; return }
        if enabled {
            do { _ = try settings.validated() }
            catch { message = error.localizedDescription; return }
        }
        isUpdatingCodex = true; pendingCodexValue = enabled
        let manager = codexManager, port = codexConfigPort
        configQueue.async { [weak self] in
            var errorMessage: String?
            do { try manager.setEnabled(enabled, port: port) }
            catch { errorMessage = error.localizedDescription }
            let status = manager.status(port: port)
            DispatchQueue.main.async {
                self?.codexSwitch = status
                self?.isUpdatingCodex = false
                self?.pendingCodexValue = nil
                self?.message = errorMessage ?? (enabled
                    ? "Bridge routing saved. Start the Bridge service, then restart Codex App."
                    : "Codex routing switched back. Restart Codex App to apply.")
            }
        }
    }
    public func openLogs() { NSWorkspace.shared.open(root.appendingPathComponent("Logs")) }
    public func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginItemEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                message = "Allow this app in System Settings > General > Login Items."
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { message = "Could not update the login item: \(error.localizedDescription)" }
    }
    public func quit() {
        quitting = true; timer?.invalidate(); timer = nil
        restartTask?.cancel(); restartTask = nil
        if service == nil {
            state = .stopped; session.invalidateAndCancel(); NSApp.terminate(nil)
        } else { stop() }
    }

    private func tick() {
        if Date().timeIntervalSince(lastCodexCheck) >= 10 { refreshCodexConfiguration() }
        if let output {
            let snapshot = output.snapshot()
            logs = snapshot.lines
            if let failure = snapshot.failure { message = failure }
            if snapshot.authenticated {
                login = nil
                if state == .login {
                    state = .starting
                    startedAt = Date() // Device authorization time is not startup time.
                }
            } else if let prompt = snapshot.login {
                if prompt.expires > Date() {
                    login = prompt
                    if state != .stopping { state = .login }
                } else if service != nil && state == .login {
                    login = nil
                    message = "Device authorization expired. Please sign in again."
                    stop()
                }
            }
        }
        do {
            try refreshUsage()
        } catch { message = error.localizedDescription }
        if service != nil && state == .starting && Date().timeIntervalSince(startedAt) > startupTimeout {
            message = authOnly
                ? "Authorization initialization timed out. Check your connection and sign in again."
                : "Service startup exceeded \(Int(startupTimeout)) seconds. Stopped waiting; check your proxy and sign-in status."
            stop()
            return
        }
        if authOnly || service == nil || state == .stopping { return }
        if healthTask == nil && Date().timeIntervalSince(lastHealth) >= healthInterval {
            lastHealth = Date(); checkHealth()
        }
        if state == .running, currentSettings?.copilotEnabled == true, quotaTask == nil,
           Date().timeIntervalSince(lastQuotaAttempt) >= 300 {
            refreshQuota()
        }
        if state == .running, sourcesTask == nil, Date().timeIntervalSince(lastSourceCheck) >= 3 {
            refreshSources()
        }
        if state == .running, gateway.codexLogin?.state == "connected", codexQuotaTask == nil,
           Date().timeIntervalSince(lastCodexQuotaCheck) >= 300 {
            refreshCodexQuota()
        }
    }

    private func refreshUsage(forceHistory: Bool = false) throws {
        let nextToday = try store?.totals(today: true) ?? UsageTotals()
        let nextTotal = try store?.totals(today: false) ?? UsageTotals()
        let changed = nextToday != today || nextTotal != total
        if nextToday != today { today = nextToday }
        if nextTotal != total { total = nextTotal }
        let day = ActivityCalendar.key(Date())
        if forceHistory || changed || historyDay != day || activity.isEmpty {
            let next = try store?.activity() ?? ActivityCalendar.grid()
            if activity != next { activity = next }
            historyDay = day
        }
    }

    private func request(_ path: String, timeout: TimeInterval = 10) -> URLRequest? {
        guard let currentSettings else { return nil }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(currentSettings.port)\(path)")!)
        request.timeoutInterval = timeout
        if path.hasPrefix("/bridge/") { request.setValue(controlToken, forHTTPHeaderField: "x-codex-bridge-token") }
        return request
    }
    public func refreshSources(force: Bool = false) {
        if force { sendControl("/bridge/refresh") }
        guard sourcesTask == nil, state == .running, let request = request("/bridge/status") else { return }
        lastSourceCheck = Date(); isFetchingSources = true
        let expected = instance
        sourcesTask = Task { [weak self] in
            guard let self else { return }
            defer { if instance == expected { sourcesTask = nil; isFetchingSources = false } }
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard instance == expected else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw BridgeError.message("Could not refresh provider status.")
                }
                let snapshot = try JSONDecoder().decode(GatewaySnapshot.self, from: data)
                gateway = snapshot; gatewayError = ""
                if snapshot.codexLogin?.state != "connected"
                    || codexQuota?.accountFingerprint != snapshot.codexLogin?.accountFingerprint {
                    codexQuota = nil; lastCodexQuotaCheck = .distantPast
                }
                if snapshot.codexLogin?.state == "connected" {
                    browserLoginRequested = false
                } else if browserLoginRequested, let raw = snapshot.codexLogin?.url,
                          raw != lastOpenedAuthURL, let url = URL(string: raw),
                          url.scheme == "https", url.host == "auth.openai.com" {
                    lastOpenedAuthURL = raw
                    NSWorkspace.shared.open(url)
                }
            } catch {
                if !Task.isCancelled && instance == expected { gatewayError = "Could not refresh provider status." }
            }
        }
    }
    public func connectCodex(device: Bool = false) {
        guard state == .running else { message = "Start the service before connecting Codex."; return }
        lastOpenedAuthURL = nil; browserLoginRequested = true
        codexQuota = nil; codexQuotaError = ""; lastCodexQuotaCheck = .distantPast
        sendControl("/bridge/auth/codex/start", body: ["method": device ? "device" : "browser"])
    }
    public func cancelCodexLogin() {
        browserLoginRequested = false
        sendControl("/bridge/auth/codex/cancel")
    }
    public func disconnectCodex() {
        browserLoginRequested = false; codexQuota = nil
        sendControl("/bridge/auth/codex/logout")
    }
    public func submitCodexCallback(_ callback: String) {
        sendControl("/bridge/auth/codex/respond", body: ["value": callback])
    }
    public func copyCodexDeviceCode() {
        guard let code = gateway.codexLogin?.code else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
    }
    public func setLocalAPIKey(_ value: String) {
        guard canStoreLocalKey else {
            message = "Enable the local source, then save and restart this service for the displayed API address before storing its key."
            return
        }
        sendControl("/bridge/local/key", body: ["value": value]) { [weak self] in
            guard let self else { return }
            settings.localRequiresKey = !value.isEmpty
            currentSettings?.localRequiresKey = !value.isEmpty
            do {
                var saved = try AppPaths.loadSettings(root: root)
                saved.localRequiresKey = !value.isEmpty
                try AppPaths.saveSettings(saved, root: root)
            } catch { message = "The key was stored, but its preference could not be saved. Save Settings before restarting." }
        }
    }
    private func sendControl(_ path: String, body: [String: Any] = [:], success: (() -> Void)? = nil) {
        guard authTask == nil, var request = request(path), state == .running else { return }
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let expected = instance
        isUpdatingProvider = true
        authTask = Task { [weak self] in
            guard let self else { return }
            defer { if instance == expected { authTask = nil; isUpdatingProvider = false } }
            do {
                let (_, response) = try await session.data(for: request)
                guard !Task.isCancelled, instance == expected else { return }
                guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                    throw BridgeError.message("The provider operation could not be completed.")
                }
                success?()
                lastSourceCheck = .distantPast
                refreshSources()
            } catch {
                if !Task.isCancelled && instance == expected { message = error.localizedDescription }
            }
        }
    }
    public func refreshCodexQuota() {
        guard codexQuotaTask == nil, state == .running, let request = request("/bridge/quota/codex", timeout: 30) else { return }
        lastCodexQuotaCheck = Date()
        let expected = instance
        codexQuotaTask = Task { [weak self] in
            guard let self else { return }
            defer { if instance == expected { codexQuotaTask = nil } }
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard instance == expected else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw BridgeError.message("Codex account quota is unavailable. Check your independent sign-in.")
                }
                let snapshot = try JSONDecoder().decode(CodexQuota.self, from: data)
                guard snapshot.accountFingerprint == gateway.codexLogin?.accountFingerprint else { return }
                codexQuota = snapshot
                try store?.recordProviderQuota(.codex, data: data)
                codexQuotaError = ""
            } catch {
                if !Task.isCancelled && instance == expected { codexQuotaError = error.localizedDescription }
            }
        }
    }
    private func checkHealth() {
        guard let request = request("/healthz", timeout: 3) else { return }
        let expected = instance
        healthTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.instance == expected { self.healthTask = nil } }
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard self.instance == expected, self.service != nil else { return }
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      object?["instance"] as? String == expected else {
                    throw BridgeError.message("The process listening on this port has a different instance identity.")
                }
                unhealthyCount = 0; state = .running; login = nil
            } catch {
                guard !Task.isCancelled, self.instance == expected else { return }
                if state == .running {
                    unhealthyCount += 1
                    if unhealthyCount >= 3 { message = "Health checks keep failing. Check Logs. The service is still running; active requests were not terminated." }
                }
            }
        }
    }
    public func refreshQuota() {
        guard quotaTask == nil, state == .running, currentSettings?.copilotEnabled == true,
              let request = request("/bridge/quota/copilot") else { return }
        let expected = instance
        isFetchingQuota = true
        lastQuotaAttempt = Date()
        quotaTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if instance == expected { quotaTask = nil; isFetchingQuota = false }
            }
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard instance == expected else { return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw BridgeError.message("Could not fetch GitHub quota. Check your sign-in and proxy settings.")
                }
                let snapshot = try QuotaSnapshot.decode(data)
                let observedAt = Date()
                quota = snapshot; quotaDate = observedAt; quotaError = ""
                try store?.recordQuota(snapshot, at: observedAt)
                try refreshUsage(forceHistory: true)
            } catch {
                if !Task.isCancelled && instance == expected { quotaError = error.localizedDescription }
            }
        }
    }
    private func didExit(_ process: Process) {
        guard service === process else { return }
        let wasAuth = authOnly
        let successfulAuth = output?.snapshot().authenticated == true
        if let snapshot = output?.snapshot() { logs = snapshot.lines }
        closePipes()
        stopTask?.cancel(); stopTask = nil
        healthTask?.cancel(); healthTask = nil
        quotaTask?.cancel(); quotaTask = nil; isFetchingQuota = false
        sourcesTask?.cancel(); sourcesTask = nil; isFetchingSources = false
        codexQuotaTask?.cancel(); codexQuotaTask = nil
        authTask?.cancel(); authTask = nil; isUpdatingProvider = false
        service = nil; servicePID = nil; output = nil; login = nil; authOnly = false
        state = .stopped
        if quitting { session.invalidateAndCancel(); NSApp.terminate(nil); return }
        if pendingRestart { pendingRestart = false; start(); return }
        if intentionallyStopping { return }
        if wasAuth {
            message = process.terminationStatus == 0 && successfulAuth
                ? "GitHub authorization succeeded. You can start the service." : "Authorization was not completed. Check Logs and try again."
            return
        }
        state = .failed
        message = "The background service exited (status \(process.terminationStatus))."
        guard currentSettings?.automaticRestart == true,
              let delay = restartPolicy.nextDelay() else {
            message += " Automatic restarts stopped. Check Logs."; return
        }
        state = .backoff; message += " Retrying in \(Int(delay)) seconds."
        let retryDelay = delay * retryScale
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(retryDelay))
            guard !Task.isCancelled else { return }
            self?.start(automatic: true)
        }
    }
    private func closePipes() {
        readers.forEach { $0.stop() }; readers.removeAll()
        for pipe in pipes {
            try? pipe.fileHandleForWriting.close()
        }
        pipes.removeAll()
    }
    private func portAvailable(_ port: Int, host: String) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        // Match server socket reuse semantics. A just-closed connection in TIME_WAIT
        // is not a live listener and must not make an ordinary restart look occupied.
        var reuse: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse,
                         socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
