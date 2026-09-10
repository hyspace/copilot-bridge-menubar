import Foundation
import CSQLite
import Darwin

public struct UsageEvent: Codable {
    public var kind: String
    public var id: String
    public var timestamp: Double
    public var model: String
    public var provider: UsageProvider = .copilot
    public var status: Int
    public var input: Int64?
    public var output: Int64?
    public var cached: Int64?
    public var outcome: String
    /// Raw server billing units, separate from token usage and account balances.
    public var nanoAiu: Double? = nil
    public var tokensComplete: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case kind, id, timestamp, model, provider, status, input, output, cached, outcome, nanoAiu, tokensComplete
    }
}

extension UsageEvent {
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(String.self, forKey: .kind)
        id = try values.decode(String.self, forKey: .id)
        timestamp = try values.decode(Double.self, forKey: .timestamp)
        model = try values.decode(String.self, forKey: .model)
        provider = try values.decodeIfPresent(UsageProvider.self, forKey: .provider) ?? .copilot
        status = try values.decode(Int.self, forKey: .status)
        input = try? values.decodeIfPresent(Int64.self, forKey: .input)
        output = try? values.decodeIfPresent(Int64.self, forKey: .output)
        cached = try? values.decodeIfPresent(Int64.self, forKey: .cached)
        outcome = try values.decode(String.self, forKey: .outcome)
        // Older producers omit billing. A malformed billing extension must not
        // discard otherwise valid token usage.
        nanoAiu = try? values.decodeIfPresent(Double.self, forKey: .nanoAiu)
        tokensComplete = try? values.decodeIfPresent(Bool.self, forKey: .tokensComplete)
    }
}

public struct UsageTotals: Equatable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cached: Int64 = 0
    public var requests: Int64 = 0
    public var errors: Int64 = 0
    public var unknown: Int64 = 0
    public var nanoAiu: Double = 0
    public var creditReports: Int64 = 0
    public var billingRequests: Int64?
    public var unknownCredits: Int64 { max(0, (billingRequests ?? requests) - creditReports) }
    public var credits: Double? { creditReports > 0 ? nanoAiu / 1_000_000_000 : nil }
    public init() {}
}

/// Single-owner SQLite connection. Call only on the owning serial queue / main actor.
public final class UsageStore {
    private var db: OpaquePointer?
    private var lastMaintenance = Date.distantPast
    public init(url: URL) throws {
        let safePath = try noFollowSQLitePath(url)
        var before = stat()
        if lstat(safePath, &before) == 0 {
            guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, before.st_uid == getuid(),
                  before.st_mode & 0o200 != 0 else {
                throw BridgeError.message("Refusing an unsafe usage database file. No migration was attempted.")
            }
        } else if errno != ENOENT {
            throw BridgeError.message("Could not inspect the usage database.")
        }
        guard sqlite3_open_v2(safePath, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            sqlite3_close(db); db = nil
            throw BridgeError.message("Could not open the local usage database.")
        }
        do {
            guard chmod(safePath, 0o600) == 0 else { throw BridgeError.message("Could not make the usage database private.") }
            try exec("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=2000; PRAGMA wal_autocheckpoint=100;")
            try exec("""
            CREATE TABLE IF NOT EXISTS totals (
              day TEXT NOT NULL, model TEXT NOT NULL,
              input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
              cached INTEGER NOT NULL DEFAULT 0, requests INTEGER NOT NULL DEFAULT 0,
              errors INTEGER NOT NULL DEFAULT 0, unknown INTEGER NOT NULL DEFAULT 0,
              nano_aiu REAL NOT NULL DEFAULT 0, credit_reports INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY(day,model));
            CREATE TABLE IF NOT EXISTS seen (id TEXT PRIMARY KEY, timestamp REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS quota_history (
              day TEXT PRIMARY KEY, observed_at REAL NOT NULL, snapshot TEXT NOT NULL);
            """)
            try migrateBillingColumns()
            try migrateProviders(url: url)
            try exec("""
            CREATE TABLE IF NOT EXISTS provider_quota_history (
              day TEXT NOT NULL, provider TEXT NOT NULL, observed_at REAL NOT NULL, snapshot TEXT NOT NULL,
              PRIMARY KEY(day,provider));
            """)
            try exec("DELETE FROM seen WHERE timestamp < strftime('%s','now')-86400*2;")
            try exec("DELETE FROM totals WHERE day < date('now','-730 days');")
            try exec("DELETE FROM quota_history WHERE day < date('now','-730 days');")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> BridgeError {
        .message("Usage database error: \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")")
    }
    private func bind(_ value: String, _ position: Int32, _ statement: OpaquePointer?) {
        sqlite3_bind_text(statement, position, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    private func migrateBillingColumns() throws {
        // Serialize the schema check with other readers/writers opening the same
        // database. Historical requests have zero billing reports, not zero cost.
        try exec("BEGIN IMMEDIATE")
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(totals)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
            var columns = Set<String>()
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                if let name = sqlite3_column_text(statement, 1) { columns.insert(String(cString: name)) }
                result = sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
            guard result == SQLITE_DONE else { throw failure() }
            if !columns.contains("nano_aiu") { try exec("ALTER TABLE totals ADD COLUMN nano_aiu REAL NOT NULL DEFAULT 0") }
            if !columns.contains("credit_reports") { try exec("ALTER TABLE totals ADD COLUMN credit_reports INTEGER NOT NULL DEFAULT 0") }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    private func totalColumns() throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(totals)", -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw failure() }
        return names
    }
    private func noFollowSQLitePath(_ url: URL) throws -> String {
        // NSURL re-shortens /private/var to /var when appending a component.
        // SQLite NOFOLLOW also checks parent directories, so use libc's physical
        // parent path and append the final filename without resolving that file.
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else {
            throw BridgeError.message("Could not resolve the usage database directory.")
        }
        defer { free(parent) }
        return String(cString: parent) + "/" + url.lastPathComponent
    }
    private func validateMigrationBackup(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 100, info.st_size <= 512 * 1024 * 1024 else {
            throw BridgeError.message("The usage migration backup is not a safe, private SQLite file. It was not overwritten.")
        }
        var backup: OpaquePointer?
        // macOS exposes TMPDIR through /var -> /private/var. Resolve directory
        // aliases, but never the final database file (which must not be a link).
        let safePath = try noFollowSQLitePath(url)
        guard sqlite3_open_v2(safePath, &backup, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            sqlite3_close(backup)
            throw BridgeError.message("The usage migration backup cannot be opened. It was not overwritten.")
        }
        defer { sqlite3_close(backup) }
        var check: OpaquePointer?
        guard sqlite3_prepare_v2(backup, "PRAGMA quick_check", -1, &check, nil) == SQLITE_OK else {
            throw BridgeError.message("The usage migration backup could not be checked (SQLite \(sqlite3_errcode(backup)): \(String(cString: sqlite3_errmsg(backup)))).")
        }
        defer { sqlite3_finalize(check) }
        guard sqlite3_step(check) == SQLITE_ROW, let result = sqlite3_column_text(check, 0),
              String(cString: result) == "ok", sqlite3_step(check) == SQLITE_DONE else {
            throw BridgeError.message("The usage migration backup failed its integrity check.")
        }
        for sql in [
            "SELECT day,model,input,output,cached,requests,errors,unknown,nano_aiu,credit_reports FROM totals LIMIT 0",
            "SELECT id,timestamp FROM seen LIMIT 0"
        ] {
            var statement: OpaquePointer?
            let prepared = sqlite3_prepare_v2(backup, sql, -1, &statement, nil)
            let result = prepared == SQLITE_OK ? sqlite3_step(statement) : SQLITE_ERROR
            sqlite3_finalize(statement)
            guard result == SQLITE_DONE else {
                throw BridgeError.message("The usage migration backup has an unexpected schema.")
            }
        }
    }
    private func backupBeforeProviderMigration(_ url: URL) throws -> URL {
        var backupURL = url.appendingPathExtension("before-providers-v2.sqlite")
        var existing = stat()
        if lstat(backupURL.path, &existing) == 0 {
            try validateMigrationBackup(backupURL)
            // A prior attempt may have stopped before migration while more old
            // requests were recorded. Keep that backup, but snapshot THIS attempt.
            backupURL = url.appendingPathExtension("before-providers-v2.retry-\(UUID().uuidString).sqlite")
        } else if errno != ENOENT {
            throw BridgeError.message("Could not inspect the usage migration backup.")
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".usage-backup-\(UUID().uuidString).sqlite")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure() }
        close(fd)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var destination: OpaquePointer?
        guard sqlite3_open_v2(temporary.path, &destination, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(destination); throw failure()
        }
        defer { sqlite3_close(destination) }
        // The owning connection holds BEGIN IMMEDIATE: other writers cannot
        // change the pre-migration state. Backup reads use a separate connection
        // because SQLite cannot back up a source in its own write transaction.
        var source: OpaquePointer?
        let safePath = try noFollowSQLitePath(url)
        guard sqlite3_open_v2(safePath, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            sqlite3_close(source); throw BridgeError.message("Could not safely open the source of the usage migration backup.")
        }
        defer { sqlite3_close(source) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else { throw failure() }
        var result: Int32 = SQLITE_OK
        let deadline = Date().addingTimeInterval(5)
        repeat {
            result = sqlite3_backup_step(backup, 128)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED { sqlite3_sleep(10) }
        } while (result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED) && Date() < deadline
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw failure() }
        // SQLite copies the source's WAL header into the backup. Normalize this
        // standalone snapshot before closing it so validation/rollback never
        // depends on a later-created -wal/-shm sidecar.
        guard sqlite3_exec(destination, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw BridgeError.message("Could not finalize a standalone usage migration snapshot.")
        }
        guard sqlite3_close(destination) == SQLITE_OK else { throw failure() }
        destination = nil
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize(); try handle.close()
        try validateMigrationBackup(temporary)
        try FileManager.default.moveItem(at: temporary, to: backupURL)
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        guard directory >= 0 else { throw failure() }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw BridgeError.message("Could not sync the usage migration backup directory.") }
        return backupURL
    }
    private func migrateProviders(url: URL) throws {
        guard try !totalColumns().contains("provider") else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            // Recheck under the SQLite write lock: the UI and pipe consumer each
            // own a connection and can open at the same time.
            if try totalColumns().contains("provider") { try exec("COMMIT"); return }
            let backup = try backupBeforeProviderMigration(url)
            try exec("""
            ALTER TABLE totals RENAME TO copilot_totals_legacy;
            CREATE TABLE totals (
              day TEXT NOT NULL, provider TEXT NOT NULL DEFAULT 'copilot', model TEXT NOT NULL,
              input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
              cached INTEGER NOT NULL DEFAULT 0, requests INTEGER NOT NULL DEFAULT 0,
              errors INTEGER NOT NULL DEFAULT 0, unknown INTEGER NOT NULL DEFAULT 0,
              nano_aiu REAL NOT NULL DEFAULT 0, credit_reports INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY(day,provider,model));
            INSERT INTO totals(day,provider,model,input,output,cached,requests,errors,unknown,nano_aiu,credit_reports)
              SELECT day,'copilot',model,input,output,cached,requests,errors,unknown,nano_aiu,credit_reports
              FROM copilot_totals_legacy;
            ALTER TABLE seen RENAME TO copilot_seen_legacy;
            CREATE TABLE seen(id TEXT NOT NULL, timestamp REAL NOT NULL, provider TEXT NOT NULL DEFAULT 'copilot',
              PRIMARY KEY(provider,id));
            INSERT INTO seen(id,timestamp,provider) SELECT id,timestamp,'copilot' FROM copilot_seen_legacy;
            CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, backup_file TEXT NOT NULL, migrated_at TEXT NOT NULL);
            """)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO schema_migrations VALUES(2,?,datetime('now'))", -1, &statement, nil) == SQLITE_OK else { throw failure() }
            bind(backup.lastPathComponent, 1, statement)
            let result = sqlite3_step(statement); sqlite3_finalize(statement)
            guard result == SQLITE_DONE else { throw failure() }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    public func record(_ event: UsageEvent) throws {
        guard event.kind == "usage", event.id.count <= 128, !event.id.isEmpty,
              event.timestamp.isFinite, abs(event.timestamp - Date().timeIntervalSince1970) < 86400 * 3,
              event.model.count <= 512
        else { throw BridgeError.message("Ignored an invalid usage event.") }
        func tokenCount(_ value: Int64?) -> Int64? {
            value.flatMap { (0...1_000_000_000).contains($0) ? $0 : nil }
        }
        let input = tokenCount(event.input), output = tokenCount(event.output), cached = tokenCount(event.cached)
        let billing = (event.provider == .copilot ? event.nanoAiu : nil).flatMap { value -> Double? in
            value.isFinite && value >= 0 && value <= 9_007_199_254_740_991 ? value : nil
        }
        if Date().timeIntervalSince(lastMaintenance) > 3600 {
            try exec("DELETE FROM seen WHERE timestamp < strftime('%s','now')-86400*2;")
            try exec("DELETE FROM totals WHERE day < date('now','-730 days');")
            try exec("DELETE FROM quota_history WHERE day < date('now','-730 days');")
            lastMaintenance = Date()
        }
        try exec("BEGIN IMMEDIATE")
        do {
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO seen(id,timestamp,provider) VALUES (?,?,?)", -1, &s, nil) == SQLITE_OK else { throw failure() }
            bind(event.id, 1, s); sqlite3_bind_double(s, 2, event.timestamp)
            bind(event.provider.rawValue, 3, s)
            let insertResult = sqlite3_step(s); sqlite3_finalize(s)
            guard insertResult == SQLITE_DONE else { throw failure() }
            if sqlite3_changes(db) == 0 { try exec("COMMIT"); return }
            let sql = """
              INSERT INTO totals(day,model,input,output,cached,requests,errors,unknown,nano_aiu,credit_reports,provider)
              VALUES(date(?,'unixepoch','localtime'),?,?,?,?,1,?,?,?,?,?)
              ON CONFLICT(day,provider,model) DO UPDATE SET
              input=input+excluded.input,output=output+excluded.output,cached=cached+excluded.cached,
              requests=requests+1,errors=errors+excluded.errors,unknown=unknown+excluded.unknown,
              nano_aiu=nano_aiu+excluded.nano_aiu,credit_reports=credit_reports+excluded.credit_reports
              """
            guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw failure() }
            sqlite3_bind_double(s, 1, event.timestamp); bind(event.model, 2, s)
            sqlite3_bind_int64(s, 3, input ?? 0); sqlite3_bind_int64(s, 4, output ?? 0)
            sqlite3_bind_int64(s, 5, cached ?? 0)
            sqlite3_bind_int(s, 6, event.outcome == "complete" ? 0 : 1)
            sqlite3_bind_int(s, 7, input == nil || output == nil || event.tokensComplete == false ? 1 : 0)
            sqlite3_bind_double(s, 8, billing ?? 0)
            sqlite3_bind_int(s, 9, billing == nil ? 0 : 1)
            bind(event.provider.rawValue, 10, s)
            let result = sqlite3_step(s); sqlite3_finalize(s)
            guard result == SQLITE_DONE else { throw failure() }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    public func totals(today: Bool, provider: UsageProvider? = nil) throws -> UsageTotals {
        var s: OpaquePointer?
        let sql = "SELECT coalesce(sum(input),0),coalesce(sum(output),0),coalesce(sum(cached),0),coalesce(sum(requests),0),coalesce(sum(errors),0),coalesce(sum(unknown),0),coalesce(sum(nano_aiu),0),coalesce(sum(credit_reports),0),coalesce(sum(CASE WHEN provider='copilot' THEN requests ELSE 0 END),0) FROM totals"
            + " WHERE 1=1" + (today ? " AND day=date('now','localtime')" : "") + (provider == nil ? "" : " AND provider=?")
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(s) }
        if let provider { bind(provider.rawValue, 1, s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw failure() }
        var result = UsageTotals()
        result.input = sqlite3_column_int64(s, 0); result.output = sqlite3_column_int64(s, 1)
        result.cached = sqlite3_column_int64(s, 2); result.requests = sqlite3_column_int64(s, 3)
        result.errors = sqlite3_column_int64(s, 4); result.unknown = sqlite3_column_int64(s, 5)
        result.nanoAiu = sqlite3_column_double(s, 6); result.creditReports = sqlite3_column_int64(s, 7)
        result.billingRequests = sqlite3_column_int64(s, 8)
        return result
    }

    public func recordProviderQuota(_ provider: UsageProvider, data: Data, at date: Date = Date()) throws {
        guard data.count <= 16384, (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw BridgeError.message("Invalid account quota snapshot.")
        }
        var s: OpaquePointer?
        let sql = """
          INSERT INTO provider_quota_history(day,provider,observed_at,snapshot) VALUES(?,?,?,?)
          ON CONFLICT(day,provider) DO UPDATE SET observed_at=excluded.observed_at,snapshot=excluded.snapshot
          WHERE excluded.observed_at>=provider_quota_history.observed_at
          """
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(s) }
        bind(ActivityCalendar.key(date), 1, s); bind(provider.rawValue, 2, s)
        sqlite3_bind_double(s, 3, date.timeIntervalSince1970); bind(String(decoding: data, as: UTF8.self), 4, s)
        guard sqlite3_step(s) == SQLITE_DONE else { throw failure() }
        try exec("DELETE FROM provider_quota_history WHERE day < date('now','-730 days')")
    }
    public func latestProviderQuota(_ provider: UsageProvider) throws -> Data? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT snapshot FROM provider_quota_history WHERE provider=? ORDER BY observed_at DESC LIMIT 1", -1, &s, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(s) }
        bind(provider.rawValue, 1, s)
        let result = sqlite3_step(s)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW, let text = sqlite3_column_text(s, 0) else { throw failure() }
        return Data(String(cString: text).utf8)
    }

    /// One last-observed account balance per local day. Never infer credit cost from tokens.
    public func recordQuota(_ snapshot: QuotaSnapshot, at date: Date = Date(),
                            calendar: Calendar = ActivityCalendar.local) throws {
        guard date.timeIntervalSince1970.isFinite else { throw BridgeError.message("Invalid quota observation time.") }
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        guard json.utf8.count <= 16384 else { throw BridgeError.message("Quota snapshot is too large.") }
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO quota_history(day,observed_at,snapshot) VALUES(?,?,?)
        ON CONFLICT(day) DO UPDATE SET observed_at=excluded.observed_at,snapshot=excluded.snapshot
        WHERE excluded.observed_at >= quota_history.observed_at
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        bind(ActivityCalendar.key(date, calendar: calendar), 1, statement)
        sqlite3_bind_double(statement, 2, date.timeIntervalSince1970); bind(json, 3, statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        try exec("DELETE FROM quota_history WHERE day < date('now','-730 days');")
    }

    public func latestQuota() throws -> QuotaObservation? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT observed_at,snapshot FROM quota_history ORDER BY observed_at DESC LIMIT 1",
                                -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw failure() }
        return try quotaObservation(statement, timestampColumn: 0, jsonColumn: 1)
    }

    private func quotaObservation(_ statement: OpaquePointer?, timestampColumn: Int32,
                                  jsonColumn: Int32) throws -> QuotaObservation {
        guard let pointer = sqlite3_column_text(statement, jsonColumn) else { throw failure() }
        let snapshot = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(String(cString: pointer).utf8))
        return QuotaObservation(snapshot: snapshot,
            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, timestampColumn)))
    }

    public func activity(ending: Date = Date(), weeks: Int = 26,
                         calendar: Calendar = ActivityCalendar.local) throws -> [ActivityDay] {
        var days = ActivityCalendar.grid(ending: ending, weeks: weeks, calendar: calendar)
        guard let first = days.first else { return days }
        let lastKey = ActivityCalendar.key(ending, calendar: calendar)
        let indices = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element.id, $0.offset) })
        var statement: OpaquePointer?
        let sql = """
        SELECT day,sum(input),sum(output),sum(cached),sum(requests),sum(errors),sum(unknown),sum(nano_aiu),sum(credit_reports),provider
        FROM totals WHERE day>=? AND day<=? GROUP BY day,provider
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        bind(first.id, 1, statement); bind(lastKey, 2, statement)
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let pointer = sqlite3_column_text(statement, 0), let index = indices[String(cString: pointer)] {
                var usage = UsageTotals()
                usage.input = sqlite3_column_int64(statement, 1); usage.output = sqlite3_column_int64(statement, 2)
                usage.cached = sqlite3_column_int64(statement, 3); usage.requests = sqlite3_column_int64(statement, 4)
                usage.errors = sqlite3_column_int64(statement, 5); usage.unknown = sqlite3_column_int64(statement, 6)
                usage.nanoAiu = sqlite3_column_double(statement, 7); usage.creditReports = sqlite3_column_int64(statement, 8)
                let provider = sqlite3_column_text(statement, 9).flatMap { UsageProvider(rawValue: String(cString: $0)) } ?? .copilot
                usage.billingRequests = provider == .copilot ? usage.requests : 0
                days[index].providers[provider] = usage
                days[index].usage.input += usage.input; days[index].usage.output += usage.output
                days[index].usage.cached += usage.cached; days[index].usage.requests += usage.requests
                days[index].usage.errors += usage.errors; days[index].usage.unknown += usage.unknown
                days[index].usage.nanoAiu += usage.nanoAiu; days[index].usage.creditReports += usage.creditReports
                days[index].usage.billingRequests = (days[index].usage.billingRequests ?? 0) + (usage.billingRequests ?? 0)
            }
            result = sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
        guard result == SQLITE_DONE else { throw failure() }
        guard sqlite3_prepare_v2(db, "SELECT day,observed_at,snapshot FROM quota_history WHERE day>=? AND day<=?",
                                -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        bind(first.id, 1, statement); bind(lastKey, 2, statement)
        result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let pointer = sqlite3_column_text(statement, 0), let index = indices[String(cString: pointer)] {
                days[index].quota = try quotaObservation(statement, timestampColumn: 1, jsonColumn: 2)
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw failure() }
        return days
    }
}
