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
    private let journal: UsageJournal
    private var retryTimer: DispatchSourceTimer?
    private var usageFailure: String?
    private var lastUsageWarning = Date.distantPast
    private let secrets: [String]
    private let eventToken: String
    private var lines: [String] = []
    private var login: LoginPrompt?
    private var authenticated = false
    private var failure: String?
    init(root: URL, secrets: [String], eventToken: String, retryInterval: TimeInterval = 30) throws {
        self.secrets = secrets
        self.eventToken = eventToken
        self.log = try RotatingLog(root: root.appendingPathComponent("Logs"))
        self.store = try UsageStore(url: root.appendingPathComponent("usage.sqlite"))
        self.journal = try UsageJournal(root: root.appendingPathComponent("UsageRecovery"))
        replayUsage()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.hyspace.bridge.usage-recovery"))
        timer.schedule(deadline: .now() + retryInterval, repeating: retryInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.replayUsage()
        }
        timer.resume()
        retryTimer = timer
    }
    deinit { retryTimer?.cancel() }
    private func reportUsageFailure(_ text: String) {
        usageFailure = text
        // A persistent error must stay visible without filling the rotated logs.
        if Date().timeIntervalSince(lastUsageWarning) >= 60 {
            append(text); lastUsageWarning = Date()
        }
    }
    private func replayUsage() {
        do {
            let count = try journal.replay(into: store)
            if count > 0 { append("Recovered \(count) pending usage records (deduplicated).") }
            usageFailure = nil
        } catch { reportUsageFailure("Usage recovery needs attention: \(error.localizedDescription)") }
    }
    private func recordUsage(_ event: UsageEvent) {
        var entry: URL?
        var journalError: Error?
        do { entry = try journal.stage(event) }
        catch { journalError = error }
        do {
            try store.record(event)
            if let entry { try journal.acknowledge(entry) }
            if let journalError {
                reportUsageFailure("Usage saved, but crash-recovery journaling failed: \(journalError.localizedDescription)")
            }
        } catch {
            reportUsageFailure(entry != nil
                ? "Could not save usage; a private recovery record was retained and will retry every 30 seconds: \(error.localizedDescription)"
                : "Could not save or journal usage; this event could not be retained: \(error.localizedDescription)")
        }
    }
    func diagnostic(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        append(Redactor.clean(text, secrets: secrets))
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
                    recordUsage(event)
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
    func snapshot() -> (lines: [String], login: LoginPrompt?, authenticated: Bool, failure: String?, usageFailure: String?) {
        lock.lock(); defer { lock.unlock() }
        return (lines, login, authenticated, failure, usageFailure)
    }
}
