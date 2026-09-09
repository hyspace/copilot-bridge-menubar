import AppKit
import Foundation
import Combine
import ServiceManagement
import SystemConfiguration
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
    @Published public private(set) var servicePID: Int32?
    private var service: Process?
    private var output: ProcessOutput?
    private var pipes: [Pipe] = []
    private var readers: [PipeReader] = []
    private var timer: Timer?
    private var healthTask: Task<Void, Never>?
    private var quotaTask: Task<Void, Never>?
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
            launchFromArguments: CommandLine.arguments.contains("--start-service"))
    }

    // Dependency injection is internal and only used by native integration tests.
    // Release callers cannot replace the bundled backend through an environment flag.
    init(root: URL, backend: URL?, home: URL, heartbeat: TimeInterval = 1,
         shutdownGrace: TimeInterval = 5, retryScale: Double = 1, launchFromArguments: Bool = false,
         healthInterval: TimeInterval = 5, startupTimeout: TimeInterval = 90) {
        self.root = root
        self.backend = backend
        self.home = home
        self.shutdownGrace = shutdownGrace
        self.retryScale = retryScale
        self.healthInterval = healthInterval
        self.startupTimeout = startupTimeout
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
            try refreshUsage(forceHistory: true)
        } catch { message = error.localizedDescription }
        loginItemEnabled = SMAppService.mainApp.status == .enabled
        timer = Timer.scheduledTimer(withTimeInterval: heartbeat, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        if settings.startOnLaunch || launchFromArguments { start() }
    }

    deinit {
        timer?.invalidate()
        healthTask?.cancel(); quotaTask?.cancel(); restartTask?.cancel(); stopTask?.cancel()
        readers.forEach { $0.stop() }
        session.invalidateAndCancel()
        if let service, service.isRunning { service.terminate() }
    }

    public var isActive: Bool { service != nil || state == .backoff }
    public var endpoint: String { "http://127.0.0.1:\((currentSettings ?? settings).port)/v1" }
    public var hasUnsavedChanges: Bool { currentSettings.map { $0 != settings } ?? false }
    public var loginStatus: String {
        FileManager.default.fileExists(atPath: home
            .appendingPathComponent(".local/share/copilot-bridge/github_token").path)
            ? "CLI credentials found; GitHub verifies whether they are valid." : "No GitHub credentials found."
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
            let pump = try ProcessOutput(root: root, secrets: [eventToken],
                                         eventToken: eventToken)
            child.executableURL = binary
            child.arguments = settings.arguments(authOnly: loginOnly)
            child.environment = settings.environment(inheriting: ProcessInfo.processInfo.environment,
                home: home.path,
                parentPID: ProcessInfo.processInfo.processIdentifier, instance: instance,
                eventToken: eventToken)
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
    public func copyReference() {
        do {
            _ = try settings.validated()
            let host = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" }
                ?? "<this-mac-lan-address>"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(settings.referenceConfig(hostName: host), forType: .string)
            message = "Reference configuration copied. Existing files were not changed."
        } catch { message = error.localizedDescription }
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
        if state == .running, quotaTask == nil, Date().timeIntervalSince(lastQuotaAttempt) >= 300 {
            refreshQuota()
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
        return request
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
        guard quotaTask == nil, state == .running, let request = request("/usage") else { return }
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
