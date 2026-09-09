import Foundation

public enum Redactor {
    public static func clean(_ text: String, secrets: [String] = []) -> String {
        var value = text
        for secret in secrets where !secret.isEmpty { value = value.replacingOccurrences(of: secret, with: "[REDACTED]") }
        for pattern in [
            #"(?i)(Bearer|token)\s+[A-Za-z0-9._~+/=-]{8,}"#,
            #"\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)\b"#,
            #"(?i)(authorization|x-bridge-key)\s*[:=]\s*[^,\s]+"#,
            #"(?i)([?&](?:token|key|access_token|api_key)=)[^&\s]+"#
        ] {
            value = value.replacingOccurrences(of: pattern, with: "[REDACTED]", options: .regularExpression)
        }
        return String(value.prefix(8192))
    }
}

public struct LineFramer {
    private var pending = Data()
    public private(set) var droppedBytes = 0
    public init() {}
    public mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 10 {
                lines.append(String(decoding: pending, as: UTF8.self)); pending.removeAll(keepingCapacity: true)
            } else if pending.count < 65536 { pending.append(byte) }
            else { droppedBytes += 1 }
        }
        return lines
    }
}

public final class RotatingLog {
    private let root: URL
    private let maxBytes: Int
    private var handle: FileHandle?
    private var bytes = 0
    public init(root: URL, maxBytes: Int = 2 * 1024 * 1024) throws {
        self.root = root; self.maxBytes = maxBytes
        try AppPaths.prepare(root); try open()
    }
    private var path: URL { root.appendingPathComponent("bridge.log") }
    private func open() throws {
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        handle = try FileHandle(forWritingTo: path)
        bytes = Int(try handle?.seekToEnd() ?? 0)
    }
    public func append(_ line: String) throws {
        let data = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        if bytes + data.count > maxBytes {
            try handle?.close(); handle = nil
            let fm = FileManager.default
            for index in stride(from: 2, through: 0, by: -1) {
                let source = index == 0 ? path : root.appendingPathComponent("bridge.\(index).log")
                let dest = root.appendingPathComponent("bridge.\(index + 1).log")
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: dest) }
            }
            try open()
        }
        try handle?.write(contentsOf: data); bytes += data.count
    }
    deinit { try? handle?.close() }
}

public struct RestartPolicy {
    private var failures: [Date] = []
    public init() {}
    public mutating func nextDelay(now: Date = Date()) -> TimeInterval? {
        failures = failures.filter { now.timeIntervalSince($0) < 600 }
        guard failures.count < 5 else { return nil }
        failures.append(now)
        return min(pow(2, Double(failures.count)), 60)
    }
    public mutating func reset() { failures.removeAll() }
}
