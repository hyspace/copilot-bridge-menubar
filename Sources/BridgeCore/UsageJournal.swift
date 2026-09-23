import Foundation
import Darwin

/// Private, bounded write-ahead files containing only the typed usage metadata.
/// No prompts, response text, headers or diagnostic-channel credentials are stored.
/// Single-owner, like UsageStore. Commit to SQLite before deleting a journal entry.
public final class UsageJournal {
    private let root: URL
    private let limit: Int
    public init(root: URL, limit: Int = 4096) throws {
        self.root = root; self.limit = limit
        if let values = try? root.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw BridgeError.message("Usage journal cannot be a symbolic link.")
        }
        try AppPaths.prepare(root)
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw BridgeError.message("Usage journal must be a private directory, not a link.")
        }
    }
    private func entries() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    public func stage(_ event: UsageEvent) throws -> URL {
        try event.validate()
        guard try entries().count < limit else {
            throw BridgeError.message("Usage recovery journal is full. Existing records were preserved; check storage before continuing.")
        }
        let data = try JSONEncoder().encode(event)
        guard data.count <= 4096 else { throw BridgeError.message("Usage recovery metadata is too large.") }
        let url = root.appendingPathComponent(UUID().uuidString + ".json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        try syncDirectory()
        return url
    }
    public func acknowledge(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw BridgeError.message("Invalid usage journal path.")
        }
        try FileManager.default.removeItem(at: url)
        try syncDirectory()
    }
    /// Expired/corrupt entries are preserved for manual inspection, never guessed or
    /// deleted. They do not prevent newer, valid entries from being recovered.
    public func replay(into store: UsageStore) throws -> Int {
        var recovered = 0
        var firstError: Error?
        for url in try entries().prefix(limit) {
            if recovered >= 64 { break }
            let event: UsageEvent
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size <= 4096 else {
                    throw BridgeError.message("Invalid usage recovery file; preserved for inspection.")
                }
                event = try JSONDecoder().decode(UsageEvent.self, from: Data(contentsOf: url))
                try event.validate()
            } catch {
                if firstError == nil { firstError = error }
                continue
            }
            do {
                try store.record(event)
                try acknowledge(url)
                recovered += 1
            } catch {
                if firstError == nil { firstError = error }
                break // A busy/unwritable DB should incur at most one timeout per retry.
            }
        }
        if let firstError { throw firstError }
        return recovered
    }
    private func syncDirectory() throws {
        let fd = open(root.path, O_RDONLY)
        guard fd >= 0 else { throw BridgeError.message("Could not open usage recovery directory.") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw BridgeError.message("Could not sync usage recovery directory.") }
    }
}
