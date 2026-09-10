import Foundation
import Security
import Darwin

/// Dedicated private stdio protocol. Never runs the GUI or prints diagnostics
/// containing credentials. The backend is the only client; the UI receives status.
public enum CredentialBroker {
    private static let service = "com.hyspace.copilot-bridge-menubar.codex-bridge.accounts"

    public static func run() -> Int32 {
        do { try AppPaths.prepare(AppPaths.root) } catch { return 1 }
        let path = AppPaths.root.appendingPathComponent("credentials.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return 1 }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return 1 }
        defer { flock(fd, LOCK_UN) }
        var pending = Data()
        while true {
            let data = FileHandle.standardInput.availableData
            if data.isEmpty { return 0 }
            pending.append(data)
            guard pending.count <= 262144 else { return 1 }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let command = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = command["id"] as? String, id.count <= 128,
                      let key = command["key"] as? String, ["codex", "local"].contains(key),
                      let operation = command["operation"] as? String else { return 1 }
                var answer: [String: Any] = ["id": id]
                do {
                    switch operation {
                    case "read":
                        if let data = try read(key) {
                            answer["value"] = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                        }
                    case "write":
                        guard let value = command["value"] else { throw BrokerError.invalid }
                        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
                        guard data.count <= 65536 else { throw BrokerError.invalid }
                        try write(key, data)
                    case "remove": try remove(key)
                    default: throw BrokerError.invalid
                    }
                    answer["ok"] = true
                } catch { answer = ["id": id, "ok": false] }
                guard let response = try? JSONSerialization.data(withJSONObject: answer, options: [.fragmentsAllowed]) else { return 1 }
                FileHandle.standardOutput.write(response + Data([10]))
            }
        }
    }
    private enum BrokerError: Error { case invalid, status(OSStatus) }
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    private static func read(_ key: String) throws -> Data? {
        var q = query(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw BrokerError.status(status) }
        return data
    }
    private static func write(_ key: String, _ data: Data) throws {
        let q = query(key)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addition = q; addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(addition as CFDictionary, nil)
            guard result == errSecSuccess else { throw BrokerError.status(result) }
        } else if status != errSecSuccess { throw BrokerError.status(status) }
    }
    private static func remove(_ key: String) throws {
        let result = SecItemDelete(query(key) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw BrokerError.status(result) }
    }
}
