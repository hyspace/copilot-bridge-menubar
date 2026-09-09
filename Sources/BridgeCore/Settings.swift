import Foundation

public enum NetworkScope: String, Codable, CaseIterable { case local, lan }
public enum AccountType: String, Codable, CaseIterable { case individual, business, enterprise }

public struct BridgeSettings: Codable, Equatable {
    public var scope: NetworkScope = .local
    public var port = 4142
    public var model = ""
    public var debug = false
    public var rateLimitSeconds = 0
    public var waitForRateLimit = false
    public var autoMode = false
    public var accountType: AccountType = .individual
    public var upstreamURL = ""
    public var proxyURL = ""
    public var noProxy = "localhost,127.0.0.1,::1"
    public var vsCodeVersion = ""
    public var startOnLaunch = false
    public var automaticRestart = true
    public init() {}
    public var host: String { scope == .local ? "127.0.0.1" : "0.0.0.0" }

    public func validated() throws -> Self {
        guard (1024...65535).contains(port) else { throw BridgeError.message("Port must be between 1024 and 65535.") }
        guard (0...3600).contains(rateLimitSeconds) else { throw BridgeError.message("Request interval must be between 0 and 3600 seconds.") }
        guard model.count <= 128 && !model.contains(where: \.isNewline) else {
            throw BridgeError.message("The model name is too long or contains a line break.")
        }
        if !upstreamURL.isEmpty {
            guard let url = URL(string: upstreamURL), url.scheme == "https",
                  url.host != nil, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else {
                throw BridgeError.message("The upstream must be an HTTPS URL without credentials, a query or a fragment.")
            }
        }
        if !proxyURL.isEmpty {
            guard let url = URL(string: proxyURL), ["http", "https"].contains(url.scheme ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else {
                throw BridgeError.message("Use an HTTP(S) proxy URL without embedded credentials.")
            }
        }
        return self
    }

    public func arguments(authOnly: Bool = false) -> [String] {
        if authOnly { return ["auth", "--host", "127.0.0.1", "--port", String(port)] }
        var args = ["start", "--host", host, "--port", String(port),
                    "--no-codex-setup", "--no-claude-setup", "--no-prompt"]
        if !model.isEmpty { args += ["--model", model] }
        if debug { args += ["--debug"] }
        if rateLimitSeconds > 0 { args += ["--rate-limit", String(rateLimitSeconds)] }
        if waitForRateLimit { args += ["--wait"] }
        if autoMode { args += ["--auto"] }
        return args
    }

    public func environment(inheriting source: [String: String], home: String,
                            parentPID: Int32, instance: String,
                            eventToken: String? = nil) -> [String: String] {
        // Do not inherit arbitrary runtime loaders, API credentials, or trace destinations.
        let allowed = ["PATH", "TMPDIR", "LANG", "LC_ALL", "SSL_CERT_FILE", "SSL_CERT_DIR",
                       "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy"]
        var env = source.filter { allowed.contains($0.key) }
        env["HOME"] = home
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["NO_COLOR"] = "1"
        env["FORCE_COLOR"] = "0"
        env["COPILOT_ACCOUNT_TYPE"] = accountType.rawValue
        env["CBM_PARENT_PID"] = String(parentPID)
        env["COPILOT_BRIDGE_INSTANCE_ID"] = instance
        if let eventToken { env["COPILOT_BRIDGE_EVENTS_TOKEN"] = eventToken }
        if !upstreamURL.isEmpty { env["COPILOT_BASE_URL"] = upstreamURL }
        if !proxyURL.isEmpty {
            env["HTTPS_PROXY"] = proxyURL; env["HTTP_PROXY"] = proxyURL
            env.removeValue(forKey: "https_proxy"); env.removeValue(forKey: "http_proxy")
        }
        env["NO_PROXY"] = noProxy
        env.removeValue(forKey: "no_proxy")
        if !vsCodeVersion.isEmpty { env["COPILOT_VSCODE_VERSION"] = vsCodeVersion }
        return env
    }

}

public enum BridgeError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

public enum AppPaths {
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CopilotBridgeMenuBar", isDirectory: true)
    }
    public static func prepare(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    public static func loadSettings(root: URL) throws -> BridgeSettings {
        let path = root.appendingPathComponent("settings.json")
        if !FileManager.default.fileExists(atPath: path.path) { return BridgeSettings() }
        return try JSONDecoder().decode(BridgeSettings.self, from: Data(contentsOf: path)).validated()
    }
    public static func saveSettings(_ settings: BridgeSettings, root: URL) throws {
        _ = try settings.validated(); try prepare(root)
        let path = root.appendingPathComponent("settings.json")
        try JSONEncoder().encode(settings).write(to: path, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
