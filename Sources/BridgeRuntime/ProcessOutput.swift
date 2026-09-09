import Foundation
import BridgeCore

public struct LoginPrompt: Equatable {
    public var code: String
    public var expires: Date
}

/// Pipe handlers consume synchronously. No unbounded Task/DispatchQueue backlog per token.
final class ProcessOutput {
    private let lock = NSLock()
    private var stdout = LineFramer()
    private var stderr = LineFramer()
    private let log: RotatingLog
    private let store: UsageStore
    private let secrets: [String]
    private let eventToken: String
    private var lines: [String] = []
    private var login: LoginPrompt?
    private var authenticated = false
    private var failure: String?
    init(root: URL, secrets: [String], eventToken: String) throws {
        self.secrets = secrets
        self.eventToken = eventToken
        self.log = try RotatingLog(root: root.appendingPathComponent("Logs"))
        self.store = try UsageStore(url: root.appendingPathComponent("usage.sqlite"))
    }
    func consume(_ data: Data, error: Bool) {
        lock.lock(); defer { lock.unlock() }
        let batch = error ? stderr.append(data) : stdout.append(data)
        for raw in batch {
            if raw.hasPrefix("@@CBM:") {
                let json = Data(raw.dropFirst(6).utf8)
                guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
                      !eventToken.isEmpty, object["channel"] as? String == eventToken else {
                    append("[Ignored an unverified diagnostic event]")
                    continue
                }
                if let event = try? JSONDecoder().decode(UsageEvent.self, from: json), event.kind == "usage" {
                    do { try store.record(event) }
                    catch { append("Could not save usage: \(error.localizedDescription)") }
                    if event.tokensComplete == false {
                        let reasons = [
                            "partial": "only partial token counters were reported",
                            "not_reported": "upstream did not report token counters",
                            "interrupted": "stream ended before protocol completion",
                            "size_limit": "response exceeded the bounded usage parser limit",
                            "invalid_json": "upstream usage could not be parsed"
                        ]
                        let reason = reasons[object["tokenStatus"] as? String ?? ""] ?? "token usage is incomplete"
                        append("Usage: \(reason) (HTTP \(event.status)). Recorded counters are retained; missing usage is not zero.")
                    }
                    continue
                }
                do {
                    switch object["kind"] as? String {
                    case "authRequired":
                        if let code = object["code"] as? String,
                           code.range(of: #"^[A-Z0-9]{4}-[A-Z0-9]{4}$"#, options: .regularExpression) != nil {
                            let seconds = min(max(object["expiresIn"] as? Double ?? 900, 1), 1800)
                            authenticated = false
                            login = LoginPrompt(code: code, expires: Date().addingTimeInterval(seconds))
                            append("GitHub device authorization is required. Complete sign-in from the menu.")
                        }
                    case "authSuccess": authenticated = true; login = nil; append("GitHub authorization succeeded.")
                    case "authFailed": failure = "GitHub authorization expired or was denied. Please sign in again."; append(failure!)
                    case "fatal":
                        failure = Redactor.clean(object["message"] as? String ?? "The background service encountered a fatal error.", secrets: secrets)
                        append(failure!)
                    default: break
                    }
                    continue
                }
            }
            // Device codes belong only in the transient login UI, not persistent diagnostics.
            if raw.contains("https://github.com/login/device") && raw.contains("enter code") { continue }
            if raw.localizedCaseInsensitiveContains("GitHub token:")
                || raw.localizedCaseInsensitiveContains("Copilot token:") { append("[Credential log hidden]"); continue }
            append(Redactor.clean(raw, secrets: secrets))
        }
    }
    private func append(_ text: String) {
        lines.append(text)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        do { try log.append(text) } catch { failure = "Could not write logs: \(error.localizedDescription)" }
    }
    func snapshot() -> (lines: [String], login: LoginPrompt?, authenticated: Bool, failure: String?) {
        lock.lock(); defer { lock.unlock() }
        return (lines, login, authenticated, failure)
    }
}
