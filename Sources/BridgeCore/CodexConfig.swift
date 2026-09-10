import Foundation
import CryptoKit
import Darwin

public struct CodexManagedPlan: Codable, Equatable, Sendable {
    public var token: String
    public var port: Int
    public var installedSelector: String
    public var originalSelector: String?
    public var originalProviderDefined: Bool
    public var block: String
    public var separator: String
}
public struct CodexPlanRequest: Codable, Sendable {
    public var action: String
    public var text: String
    public var port: Int
    public var token: String?
    public var session: CodexManagedPlan?
    public var originalText: String?
    public init(action: String, text: String, port: Int, token: String? = nil, session: CodexManagedPlan? = nil,
                originalText: String? = nil) {
        self.action = action; self.text = text; self.port = port; self.token = token; self.session = session
        self.originalText = originalText
    }
}
public struct CodexPlanResult: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var text: String?
    public var plan: CodexManagedPlan?
    public var mode: String?
    public var reserved: Bool?
    public var profileOverride: Bool?
}
public struct CodexSwitchStatus: Equatable, Sendable {
    public var known = false
    public var enabled = false
    public var canChange = false
    public var managed = false
    public var port: Int?
    public var message = "Checking Codex configuration…"
    public init() {}
}

/// Serial caller; an OS lock additionally serializes different app/helper instances.
/// Every write is explicitly requested by the user. Status only reconciles metadata.
// In-process and OS locks cover every planner invocation/cache access. Immutable paths
// can cross queues; the failure hook exists only in debug/test builds.
public final class CodexConfigManager: @unchecked Sendable {
    public typealias Planner = (CodexPlanRequest) throws -> CodexPlanResult
    public let configURL: URL
    public let backupsURL: URL
    private let dataRoot: URL
    private let planner: Planner
    private let fm = FileManager.default
    private let processLock = NSLock()
    private static let limit = 1024 * 1024

    // Failure injection touches only temporary test files, never exposed by the UI.
    #if DEBUG
    var checkpoint: ((String) throws -> Void)?
    #endif
    private var inspectionCache: (String, Int, CodexPlanResult)?
    private func hitCheckpoint(_ name: String) throws {
        #if DEBUG
        try checkpoint?(name)
        #endif
    }

    private struct Image {
        var data: Data?
        var mode: UInt16 = 0o600
        var inode: UInt64 = 0
        var device: Int32 = 0
        var text: String {
            get throws {
                guard let text = String(data: data ?? Data(), encoding: .utf8) else {
                    throw BridgeError.message("Codex config must be UTF-8. No configuration was changed.")
                }
                return text
            }
        }
        var metadata: Metadata { Metadata(exists: data != nil, hash: Self.hash(data ?? Data()), mode: mode) }
        private static func hash(_ data: Data) -> String { CodexConfigManager.hash(data) }
    }
    private struct Metadata: Codable, Equatable {
        var exists: Bool
        var hash: String
        var mode: UInt16
    }
    private struct Journal: Codable {
        var version = 1
        var configPath: String
        var active: String?
        var activeSeal: String?
        var pending: String?
        var pendingSeal: String?
    }
    private struct Transaction: Codable {
        var version = 1
        var createdAt = ISO8601DateFormatter().string(from: Date())
        var configPath: String
        var kind: String
        var port: Int
        var previous: String?
        var previousSeal: String?
        var next: String?
        var before: Metadata
        var after: Metadata
        var plan: CodexManagedPlan?
    }

    public init(home: URL, dataRoot: URL, planner: @escaping Planner) {
        self.dataRoot = dataRoot
        let canonical = home.standardizedFileURL.resolvingSymlinksInPath()
        configURL = canonical.appendingPathComponent("config.toml")
        backupsURL = dataRoot.appendingPathComponent("CodexConfig", isDirectory: true)
            .appendingPathComponent(Self.hash(Data(configURL.path.utf8)), isDirectory: true)
        self.planner = planner
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func problem(_ message: String) -> BridgeError { .message(message) }
    private func validID(_ id: String) -> Bool { UUID(uuidString: id)?.uuidString.lowercased() == id }
    private func validSeal(_ seal: String?) -> Bool {
        guard let seal else { return false }
        return seal.count == 64 && seal.allSatisfy { "0123456789abcdef".contains($0) }
    }
    private func directory(_ url: URL, create: Bool = true, privateMode: Bool = true) throws {
        if create && !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == getuid(),
              !privateMode || s.st_mode & 0o077 == 0 else {
            throw problem("The configuration or backup directory is not a safe, owned directory.")
        }
    }
    private func read(_ url: URL, privateMode: Bool = false, limit: Int = CodexConfigManager.limit) throws -> Image {
        var pathStat = stat()
        if lstat(url.path, &pathStat) != 0 {
            if errno == ENOENT { return Image(data: nil) }
            throw problem("Could not inspect a configuration file.")
        }
        guard pathStat.st_mode & S_IFMT == S_IFREG, pathStat.st_nlink == 1, pathStat.st_uid == getuid(),
              !privateMode || pathStat.st_mode & 0o077 == 0,
              pathStat.st_size <= limit else {
            throw problem("Refusing an unsafe file: symlinks, hard links, non-owned files and oversized files are not supported.")
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw problem("Could not safely open a configuration file.") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_ino == pathStat.st_ino, before.st_dev == pathStat.st_dev else {
            throw problem("Configuration changed while it was being opened. Try again.")
        }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw problem("Could not read a configuration file.") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > limit { throw problem("Configuration exceeded the safe size limit.") }
        }
        var after = stat(), finalPath = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &finalPath) == 0,
              before.st_ino == finalPath.st_ino, before.st_dev == finalPath.st_dev,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw problem("Configuration changed while it was being read. Try again.")
        }
        return Image(data: data, mode: UInt16(before.st_mode & 0o777),
                     inode: UInt64(before.st_ino), device: before.st_dev)
    }
    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw problem("Could not open a directory for durable configuration storage.") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw problem("Could not sync configuration storage.") }
    }
    private func writeNew(_ data: Data, to url: URL, mode: UInt16 = 0o600) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(mode))
        guard fd >= 0 else { throw problem("Could not create a private configuration backup or staging file.") }
        defer { close(fd) }
        var position = 0
        try data.withUnsafeBytes { bytes in
            while position < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: position), bytes.count - position)
                if count < 0 { if errno == EINTR { continue }; throw problem("Could not write a configuration backup.") }
                guard count > 0 else { throw problem("Configuration storage stopped accepting data.") }
                position += count
            }
        }
        guard fchmod(fd, mode_t(mode)) == 0, fsync(fd) == 0 else { throw problem("Could not durably save configuration data.") }
    }
    private var stateURL: URL { backupsURL.appendingPathComponent("state.json") }
    private func save(_ journal: Journal) throws {
        let data = try JSONEncoder().encode(journal)
        let temp = backupsURL.appendingPathComponent(".state-\(UUID().uuidString.lowercased()).tmp")
        try writeNew(data, to: temp)
        guard rename(temp.path, stateURL.path) == 0 else { throw problem("Could not commit configuration recovery metadata.") }
        try syncDirectory(backupsURL)
    }
    private func loadJournal() throws -> Journal {
        guard let data = try read(stateURL, privateMode: true, limit: 16384).data else {
            return Journal(configPath: configURL.path)
        }
        guard let journal = try? JSONDecoder().decode(Journal.self, from: data),
              journal.version == 1, journal.configPath == configURL.path,
              journal.active.map(validID) ?? true, journal.pending.map(validID) ?? true,
              journal.active == nil ? journal.activeSeal == nil : validSeal(journal.activeSeal),
              journal.pending == nil ? journal.pendingSeal == nil : validSeal(journal.pendingSeal) else {
            throw problem("Configuration recovery metadata is invalid. No configuration was changed; review backups.")
        }
        return journal
    }
    private func transactionURL(_ id: String) throws -> URL {
        guard validID(id) else { throw problem("Invalid configuration backup identifier.") }
        return backupsURL.appendingPathComponent(id, isDirectory: true)
    }
    private func load(_ id: String, seal: String?) throws -> (Transaction, Image, Image) {
        let root = try transactionURL(id)
        try directory(root, create: false)
        guard validSeal(seal),
              let metadata = try read(root.appendingPathComponent("manifest.json"), privateMode: true, limit: 16 * Self.limit).data,
              Self.hash(metadata) == seal,
              let transaction = try? JSONDecoder().decode(Transaction.self, from: metadata),
              transaction.version == 1, transaction.configPath == configURL.path,
              (1024...65535).contains(transaction.port),
              ["enable", "disable", "legacyOff"].contains(transaction.kind),
              transaction.previous.map(validID) ?? true, transaction.next.map(validID) ?? true,
              transaction.kind != "enable" || (transaction.next == id && transaction.plan?.token == id) else {
            throw problem("The original configuration backup is missing or invalid. No configuration was changed.")
        }
        func image(_ name: String, _ expected: Metadata) throws -> Image {
            guard expected.mode <= 0o777,
                  let data = try read(root.appendingPathComponent(name), privateMode: true).data,
                  Self.hash(data) == expected.hash, expected.exists || data.isEmpty else {
                throw problem("A configuration backup failed its integrity check. No configuration was changed.")
            }
            return Image(data: expected.exists ? data : nil, mode: expected.mode)
        }
        return (transaction, try image("before.toml", transaction.before), try image("after.toml", transaction.after))
    }
    private func stagingURL(_ id: String) -> URL {
        configURL.deletingLastPathComponent().appendingPathComponent(".copilot-bridge-\(id).tmp")
    }
    private func sameContents(_ a: Image, _ b: Image) -> Bool { a.data == b.data && (a.data == nil || a.mode == b.mode) }
    private func reconcile(_ journal: inout Journal) throws {
        guard let pending = journal.pending else { return }
        let (transaction, before, after) = try load(pending, seal: journal.pendingSeal)
        guard transaction.previous == journal.active, transaction.previousSeal == journal.activeSeal else {
            throw problem("Conflicting configuration recovery metadata; review backups.")
        }
        let current = try read(configURL)
        let stage = try read(stagingURL(pending))
        if sameContents(current, after) && (stage.data == nil || sameContents(stage, before) || sameContents(stage, after)) {
            journal.active = transaction.next
            journal.activeSeal = transaction.next == nil ? nil : journal.pendingSeal
        } else if sameContents(stage, after) && stage.data != nil {
            // Still-staged candidate, including a rolled-back late edit: keep the
            // user's current file and abort bookkeeping, not the external edit.
        } else if sameContents(current, before) && stage.data == nil {
            // The last app stopped before committing the config (or rolled back).
        } else if sameContents(stage, before) || (before.data == nil && stage.data == nil) {
            // A writer may add unrelated settings after our atomic swap but before
            // metadata is committed. Validate ownership semantically; do not
            // overwrite that writer just to recover the transaction journal.
            if transaction.kind == "enable", let plan = transaction.plan {
                _ = try planned(.init(action: "disable", text: current.text, port: transaction.port, session: plan,
                                      originalText: before.text))
                journal.active = transaction.next
                journal.activeSeal = transaction.next == nil ? nil : journal.pendingSeal
            } else {
                let inspection = try planned(.init(action: "inspect", text: current.text, port: transaction.port))
                guard inspection.mode == "off", inspection.reserved != true else {
                    throw problem("A concurrent provider edit prevents automatic recovery. All versions were retained; review backups.")
                }
                journal.active = nil
                journal.activeSeal = nil
            }
        } else {
            throw problem("An interrupted configuration change conflicts with another edit. All recovery files were kept; review backups.")
        }
        journal.pending = nil
        journal.pendingSeal = nil
        try save(journal)
        if stage.data != nil { try fm.removeItem(at: stagingURL(pending)); try syncDirectory(configURL.deletingLastPathComponent()) }
    }
    private func locked<T>(_ body: (inout Journal) throws -> T) throws -> T {
        guard processLock.try() else { throw problem("Another configuration change is in progress. Try again shortly.") }
        defer { processLock.unlock() }
        try directory(dataRoot)
        try directory(backupsURL.deletingLastPathComponent())
        try directory(backupsURL)
        let lock = backupsURL.appendingPathComponent("lock")
        let fd = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw problem("Could not open the configuration lock.") }
        defer { close(fd) }
        var s = stat()
        guard fstat(fd, &s) == 0, s.st_mode & S_IFMT == S_IFREG, s.st_nlink == 1,
              s.st_uid == getuid(), s.st_mode & 0o077 == 0 else { throw problem("Unsafe configuration lock file.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw problem("Another configuration change is in progress. Try again shortly.") }
        defer { flock(fd, LOCK_UN) }
        var journal = try loadJournal()
        try reconcile(&journal)
        return try body(&journal)
    }
    private func planned(_ request: CodexPlanRequest) throws -> CodexPlanResult {
        let key = Self.hash(Data(request.text.utf8))
        if request.action == "inspect", let cache = inspectionCache,
           cache.0 == key, cache.1 == request.port { return cache.2 }
        let result = try planner(request)
        guard result.ok else { throw problem(result.error ?? "Could not safely plan the Codex configuration.") }
        if request.action == "inspect" { inspectionCache = (key, request.port, result) }
        return result
    }
    public func status(port: Int) -> CodexSwitchStatus {
        do {
            return try locked { journal in
                let current = try read(configURL)
                if current.data != nil && current.mode & 0o200 == 0 {
                    throw problem("Codex config is read-only. It was left unchanged.")
                }
                var result = CodexSwitchStatus()
                if let active = journal.active {
                    do {
                        let (transaction, original, after) = try load(active, seal: journal.activeSeal)
                        guard let plan = transaction.plan else { throw problem("The original provider backup is missing.") }
                        if !sameContents(current, after) {
                            _ = try planned(.init(action: "disable", text: current.text, port: plan.port, session: plan,
                                                  originalText: original.text))
                        }
                        result.known = true; result.enabled = true; result.managed = true; result.port = plan.port
                        result.canChange = true
                        result.message = "Bridge routing is saved for Codex App."
                    } catch {
                        result.message = error.localizedDescription
                        if let inspection = try? planned(.init(action: "inspect", text: current.text, port: port)) {
                            result.known = true; result.enabled = inspection.mode == "on" || inspection.mode == "legacy"
                        }
                    }
                } else {
                    let inspection = try planned(.init(action: "inspect", text: current.text, port: port))
                    result.known = true
                    result.enabled = inspection.mode == "on" || inspection.mode == "legacy"
                    if inspection.reserved == true {
                        throw problem("A managed Bridge configuration has no verified restore point. Review backups; no changes were made.")
                    }
                    result.canChange = inspection.profileOverride != true
                    result.port = result.enabled ? port : nil
                    result.message = inspection.profileOverride == true ? "The selected profile overrides the provider. Resolve that override first."
                        : result.enabled ? "Manual Bridge config. Off backs it up and selects Codex’s default provider; the previous provider is unknown."
                        : "Uses Codex’s existing provider. Turn on to use Bridge."
                }
                return result
            }
        } catch {
            var result = CodexSwitchStatus(); result.message = error.localizedDescription
            return result
        }
    }
    public func setEnabled(_ enabled: Bool, port: Int) throws {
        try locked { journal in
            let before = try read(configURL)
            guard before.data == nil || before.mode & 0o200 != 0 else {
                throw problem("Codex config is read-only. It was left unchanged.")
            }
            let id = UUID().uuidString.lowercased()
            if enabled, let active = journal.active {
                let (transaction, original, installed) = try load(active, seal: journal.activeSeal)
                guard let plan = transaction.plan, plan.port == port else {
                    throw problem("Turn Codex routing off before changing its port. The original backup is retained.")
                }
                if !sameContents(before, installed) {
                    _ = try planned(.init(action: "disable", text: before.text, port: port, session: plan,
                                          originalText: original.text))
                }
                return // Repeated enable never overwrites the original restore point.
            }
            let kind: String, after: Image, plan: CodexManagedPlan?
            if enabled {
                let result = try planned(.init(action: "enable", text: before.text, port: port, token: id))
                guard let text = result.text, let managed = result.plan, managed.token == id, managed.port == port else {
                    throw problem("The configuration planner returned an invalid change.")
                }
                kind = "enable"; plan = managed
                after = Image(data: Data(text.utf8), mode: before.mode)
            } else if let active = journal.active {
                let (transaction, original, installed) = try load(active, seal: journal.activeSeal)
                guard let managed = transaction.plan else { throw problem("The original provider backup is missing.") }
                kind = "disable"; plan = nil
                if sameContents(before, installed) { after = original }
                else {
                    let result = try planned(.init(action: "disable", text: before.text, port: managed.port, session: managed,
                                                  originalText: original.text))
                    guard let text = result.text else { throw problem("Could not safely restore the original provider.") }
                    after = Image(data: original.data == nil && text.isEmpty ? nil : Data(text.utf8), mode: before.mode)
                }
            } else {
                let inspection = try planned(.init(action: "inspect", text: before.text, port: port))
                guard inspection.reserved != true else { throw problem("The managed configuration has no verified backup. No changes were made.") }
                if inspection.mode != "legacy" { return }
                let result = try planned(.init(action: "legacyOff", text: before.text, port: port))
                guard let text = result.text else { throw problem("Could not safely leave the manual Bridge configuration.") }
                kind = "legacyOff"; plan = nil; after = Image(data: Data(text.utf8), mode: before.mode)
            }
            let transactionPort = try journal.active.flatMap { try load($0, seal: journal.activeSeal).0.plan?.port } ?? port
            try commit(id: id, kind: kind, port: transactionPort, before: before, after: after, plan: plan, journal: &journal)
        }
    }
    private func commit(id: String, kind: String, port: Int, before: Image, after: Image, plan: CodexManagedPlan?,
                        journal: inout Journal) throws {
        try directory(configURL.deletingLastPathComponent(), privateMode: false)
        let root = try transactionURL(id)
        try directory(root)
        let transaction = Transaction(configPath: configURL.path, kind: kind, port: port, previous: journal.active, previousSeal: journal.activeSeal,
            next: kind == "enable" ? id : nil, before: before.metadata, after: after.metadata, plan: plan)
        let manifest = try JSONEncoder().encode(transaction)
        guard (after.data?.count ?? 0) <= Self.limit, manifest.count <= 16 * Self.limit else {
            throw problem("The planned configuration exceeds safe storage limits. No configuration was changed.")
        }
        // Immutable, fsynced full snapshots exist BEFORE a pending write is published.
        try writeNew(before.data ?? Data(), to: root.appendingPathComponent("before.toml"))
        try writeNew(after.data ?? Data(), to: root.appendingPathComponent("after.toml"))
        try writeNew(manifest, to: root.appendingPathComponent("manifest.json"))
        try syncDirectory(root); try syncDirectory(backupsURL)
        try hitCheckpoint("backup")
        journal.pending = id; journal.pendingSeal = Self.hash(manifest); try save(journal)
        let stage = stagingURL(id)
        if let data = after.data { try writeNew(data, to: stage, mode: after.mode) }
        try hitCheckpoint("prepared")
        let current = try read(configURL)
        guard sameContents(current, before), current.inode == before.inode, current.device == before.device else {
            journal.pending = nil; journal.pendingSeal = nil; try save(journal)
            if sameContents(try read(stage), after), after.data != nil {
                try fm.removeItem(at: stage); try syncDirectory(configURL.deletingLastPathComponent())
            }
            throw problem("Codex config changed before commit. No edit was overwritten; recovery files were kept.")
        }
        try hitCheckpoint("beforeSwap")
        let result: Int32
        if before.data != nil && after.data != nil {
            result = renamex_np(stage.path, configURL.path, UInt32(RENAME_SWAP))
        } else if before.data != nil {
            result = renamex_np(configURL.path, stage.path, UInt32(RENAME_EXCL))
        } else {
            result = renamex_np(stage.path, configURL.path, UInt32(RENAME_EXCL))
        }
        guard result == 0 else { throw problem("Could not atomically change Codex config. Recovery files were kept.") }
        try syncDirectory(configURL.deletingLastPathComponent())
        try hitCheckpoint("swapped")
        let displaced = try read(stage)
        // Unlike a blind rename, SWAP retains a late concurrent write. Roll back
        // only while the installed file is still ours; never delete either edit.
        if before.data != nil && !sameContents(displaced, before) {
            let current = try read(configURL)
            if sameContents(current, after) {
                if after.data != nil { _ = renamex_np(stage.path, configURL.path, UInt32(RENAME_SWAP)) }
                else { _ = renamex_np(stage.path, configURL.path, UInt32(RENAME_EXCL)) }
                try syncDirectory(configURL.deletingLastPathComponent())
            }
            throw problem("A concurrent config edit was detected and retained. Review recovery files before retrying.")
        }
        let installed = try read(configURL)
        guard sameContents(installed, after) else { throw problem("Codex config changed during commit. Both versions were retained; review backups.") }
        try hitCheckpoint("committed")
        journal.active = transaction.next
        journal.activeSeal = transaction.next == nil ? nil : journal.pendingSeal
        journal.pending = nil; journal.pendingSeal = nil; try save(journal)
        if displaced.data != nil { try fm.removeItem(at: stage); try syncDirectory(configURL.deletingLastPathComponent()) }
    }
}
