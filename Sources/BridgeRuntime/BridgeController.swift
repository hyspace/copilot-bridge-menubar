import AppKit
import Foundation
import Combine
import ServiceManagement
import SystemConfiguration
import BridgeCore
import Darwin

public enum ServiceState: String { case stopped = "已停止", starting = "正在启动", running = "运行中", stopping = "正在停止", login = "等待授权", failed = "启动失败", backoff = "等待重试" }

@MainActor
public final class BridgeController: ObservableObject {
    @Published public var settings = BridgeSettings()
    @Published public private(set) var state: ServiceState = .stopped
    @Published public private(set) var message = ""
    @Published public private(set) var logs: [String] = []
    @Published public private(set) var login: LoginPrompt?
    @Published public private(set) var today = UsageTotals()
    @Published public private(set) var total = UsageTotals()
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
    private var unhealthyCount = 0
    private var instance = ""
    private var currentSettings: BridgeSettings?
    private var lanKey: String?
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
            ? "发现 CLI 缓存凭据（有效性由 GitHub 确认）" : "尚未找到 GitHub 登录凭据"
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
            message = "端口 \(settings.port) 已被占用。不会接管或杀死现有 CLI；请先停止它，或在设置中换端口。"
            return
        }
        guard let binary = backend,
              FileManager.default.isExecutableFile(atPath: binary.path) else {
            state = .failed; message = "缺少内置 Apple Silicon 服务。请使用 scripts/build-app.sh 生成完整 .app。"; return
        }
        do {
            if settings.scope == .lan { lanKey = try AccessKey.loadOrCreate() }
            else { lanKey = nil }
            instance = UUID().uuidString
            let child = Process()
            let stdout = Pipe(), stderr = Pipe()
            let eventToken = UUID().uuidString + UUID().uuidString
            let pump = try ProcessOutput(root: root, secrets: [lanKey, eventToken].compactMap { $0 },
                                         eventToken: eventToken)
            child.executableURL = binary
            child.arguments = settings.arguments(authOnly: loginOnly)
            child.environment = settings.environment(inheriting: ProcessInfo.processInfo.environment,
                home: home.path,
                parentPID: ProcessInfo.processInfo.processIdentifier, instance: instance,
                lanKey: lanKey, eventToken: eventToken)
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
        if isActive { message = "请先停止服务，再重新授权，避免两个进程同时更新凭据。"; return }
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
            let key = settings.scope == .lan ? try AccessKey.loadOrCreate() : nil
            let host = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" }
                ?? "<此 Mac 的局域网地址>"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(settings.referenceConfig(lanKey: key, hostName: host), forType: .string)
            message = "参考配置已复制；没有修改 Codex 配置。局域网地址请核对实际主机名/IP。"
        } catch { message = error.localizedDescription }
    }
    public func openLogs() { NSWorkspace.shared.open(root.appendingPathComponent("Logs")) }
    public func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginItemEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                message = "请在系统设置 → 通用 → 登录项中允许此 App。"
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { message = "登录项设置失败：\(error.localizedDescription)" }
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
                    message = "设备授权已过期，请重新登录。"
                    stop()
                }
            }
        }
        do {
            today = try store?.totals(today: true) ?? UsageTotals()
            total = try store?.totals(today: false) ?? UsageTotals()
        } catch { message = error.localizedDescription }
        if service != nil && state == .starting && Date().timeIntervalSince(startedAt) > startupTimeout {
            message = authOnly
                ? "获取授权信息或初始化超时；已停止，请检查网络后重新授权。"
                : "服务启动超过 \(Int(startupTimeout)) 秒；已停止以避免无限等待。请检查代理或登录。"
            stop()
            return
        }
        if authOnly || service == nil || state == .stopping { return }
        if healthTask == nil && Date().timeIntervalSince(lastHealth) >= healthInterval {
            lastHealth = Date(); checkHealth()
        }
        if state == .running, quotaTask == nil, Date().timeIntervalSince(quotaDate ?? .distantPast) >= 300 {
            refreshQuota()
        }
    }

    private func request(_ path: String, timeout: TimeInterval = 10) -> URLRequest? {
        guard let currentSettings else { return nil }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(currentSettings.port)\(path)")!)
        request.timeoutInterval = timeout
        if let lanKey { request.setValue(lanKey, forHTTPHeaderField: "X-Bridge-Key") }
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
                    throw BridgeError.message("监听端口的进程身份不匹配。")
                }
                unhealthyCount = 0; state = .running; login = nil
            } catch {
                guard !Task.isCancelled, self.instance == expected else { return }
                if state == .running {
                    unhealthyCount += 1
                    if unhealthyCount >= 3 { message = "健康检查连续失败；请检查日志。服务仍在运行，未强杀正在处理的请求。" }
                }
            }
        }
    }
    public func refreshQuota() {
        guard quotaTask == nil, state == .running, let request = request("/usage") else { return }
        let expected = instance
        isFetchingQuota = true
        quotaTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if instance == expected { quotaTask = nil; isFetchingQuota = false; quotaDate = Date() }
            }
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard instance == expected else { return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw BridgeError.message("GitHub 额度查询失败；请检查登录和代理。")
                }
                quota = try QuotaSnapshot.decode(data); quotaError = ""
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
                ? "GitHub 授权成功，可以启动服务。" : "授权未完成，请查看日志后重试。"
            return
        }
        state = .failed
        message = "后台服务退出（状态 \(process.terminationStatus)）。"
        guard currentSettings?.automaticRestart == true,
              let delay = restartPolicy.nextDelay() else {
            message += " 已停止自动重启；请检查日志。"; return
        }
        state = .backoff; message += " \(Int(delay)) 秒后重试。"
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
