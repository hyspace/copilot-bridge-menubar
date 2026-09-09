import Foundation
import BridgeCore

struct LoginPrompt: Equatable {
    var code: String
    var expires: Date
}

/// Pipe handlers consume synchronously. No unbounded Task/DispatchQueue backlog per token.
final class ProcessOutput {
    private let lock = NSLock()
    private var stdout = LineFramer()
    private var stderr = LineFramer()
    private let log: RotatingLog
    private let store: UsageStore
    private let secrets: [String]
    private var lines: [String] = []
    private var login: LoginPrompt?
    private var authenticated = false
    private var failure: String?
    init(root: URL, secrets: [String]) throws {
        self.secrets = secrets
        self.log = try RotatingLog(root: root.appendingPathComponent("Logs"))
        self.store = try UsageStore(url: root.appendingPathComponent("usage.sqlite"))
    }
    func consume(_ data: Data, error: Bool) {
        lock.lock(); defer { lock.unlock() }
        let batch = error ? stderr.append(data) : stdout.append(data)
        for raw in batch {
            if raw.hasPrefix("@@CBM:") {
                let json = Data(raw.dropFirst(6).utf8)
                if let event = try? JSONDecoder().decode(UsageEvent.self, from: json), event.kind == "usage" {
                    do { try store.record(event) }
                    catch { append("用量写入失败：\(error.localizedDescription)") }
                    continue
                }
                if let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] {
                    switch object["kind"] as? String {
                    case "authRequired":
                        if let code = object["code"] as? String,
                           code.range(of: #"^[A-Z0-9]{4}-[A-Z0-9]{4}$"#, options: .regularExpression) != nil {
                            let seconds = min(max(object["expiresIn"] as? Double ?? 900, 1), 1800)
                            login = LoginPrompt(code: code, expires: Date().addingTimeInterval(seconds))
                            append("需要 GitHub 设备授权；请在菜单中完成登录。")
                        }
                    case "authSuccess": authenticated = true; login = nil; append("GitHub 授权成功。")
                    case "authFailed": failure = "GitHub 授权已过期或被拒绝，请重新登录。"; append(failure!)
                    case "fatal":
                        failure = Redactor.clean(object["message"] as? String ?? "后台服务遇到不可恢复的错误。", secrets: secrets)
                        append(failure!)
                    default: break
                    }
                    continue
                }
            }
            // Device codes belong only in the transient login UI, not persistent diagnostics.
            if raw.contains("https://github.com/login/device") && raw.contains("enter code") { continue }
            if raw.localizedCaseInsensitiveContains("GitHub token:")
                || raw.localizedCaseInsensitiveContains("Copilot token:") { append("[凭据日志已隐藏]"); continue }
            append(Redactor.clean(raw, secrets: secrets))
        }
    }
    private func append(_ text: String) {
        lines.append(text)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        do { try log.append(text) } catch { failure = "日志写入失败：\(error.localizedDescription)" }
    }
    func snapshot() -> (lines: [String], login: LoginPrompt?, authenticated: Bool, failure: String?) {
        lock.lock(); defer { lock.unlock() }
        return (lines, login, authenticated, failure)
    }
}
