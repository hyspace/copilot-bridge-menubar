import Foundation
import CSQLite

public struct UsageEvent: Codable {
    public var kind: String
    public var id: String
    public var timestamp: Double
    public var model: String
    public var status: Int
    public var input: Int64?
    public var output: Int64?
    public var cached: Int64?
    public var outcome: String
}

public struct UsageTotals: Equatable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cached: Int64 = 0
    public var requests: Int64 = 0
    public var errors: Int64 = 0
    public var unknown: Int64 = 0
    public init() {}
}

/// Single-owner SQLite connection. Call only on the owning serial queue / main actor.
public final class UsageStore {
    private var db: OpaquePointer?
    private var lastMaintenance = Date.distantPast
    public init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw BridgeError.message("无法打开本地用量数据库。")
        }
        do {
            try exec("PRAGMA journal_mode=WAL; PRAGMA busy_timeout=2000; PRAGMA wal_autocheckpoint=100;")
            try exec("""
            CREATE TABLE IF NOT EXISTS totals (
              day TEXT NOT NULL, model TEXT NOT NULL,
              input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0,
              cached INTEGER NOT NULL DEFAULT 0, requests INTEGER NOT NULL DEFAULT 0,
              errors INTEGER NOT NULL DEFAULT 0, unknown INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY(day,model));
            CREATE TABLE IF NOT EXISTS seen (id TEXT PRIMARY KEY, timestamp REAL NOT NULL);
            """)
            try exec("DELETE FROM seen WHERE timestamp < strftime('%s','now')-86400*2;")
            try exec("DELETE FROM totals WHERE day < date('now','-730 days');")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> BridgeError {
        .message("用量数据库错误：\(db.map { String(cString: sqlite3_errmsg($0)) } ?? "closed")")
    }
    private func bind(_ value: String, _ position: Int32, _ statement: OpaquePointer?) {
        sqlite3_bind_text(statement, position, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    public func record(_ event: UsageEvent) throws {
        guard event.kind == "usage", event.id.count <= 128, !event.id.isEmpty,
              event.timestamp.isFinite, abs(event.timestamp - Date().timeIntervalSince1970) < 86400 * 3,
              event.model.count <= 128,
              [event.input, event.output, event.cached].allSatisfy({ $0 == nil || (0...1_000_000_000).contains($0!) })
        else { throw BridgeError.message("忽略无效的用量事件。") }
        if Date().timeIntervalSince(lastMaintenance) > 3600 {
            try exec("DELETE FROM seen WHERE timestamp < strftime('%s','now')-86400*2;")
            try exec("DELETE FROM totals WHERE day < date('now','-730 days');")
            lastMaintenance = Date()
        }
        try exec("BEGIN IMMEDIATE")
        do {
            var s: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO seen VALUES (?,?)", -1, &s, nil) == SQLITE_OK else { throw failure() }
            bind(event.id, 1, s); sqlite3_bind_double(s, 2, event.timestamp)
            let insertResult = sqlite3_step(s); sqlite3_finalize(s)
            guard insertResult == SQLITE_DONE else { throw failure() }
            if sqlite3_changes(db) == 0 { try exec("COMMIT"); return }
            let sql = """
              INSERT INTO totals(day,model,input,output,cached,requests,errors,unknown)
              VALUES(date(?,'unixepoch','localtime'),?,?,?,?,1,?,?)
              ON CONFLICT(day,model) DO UPDATE SET
              input=input+excluded.input,output=output+excluded.output,cached=cached+excluded.cached,
              requests=requests+1,errors=errors+excluded.errors,unknown=unknown+excluded.unknown
              """
            guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw failure() }
            sqlite3_bind_double(s, 1, event.timestamp); bind(event.model, 2, s)
            sqlite3_bind_int64(s, 3, event.input ?? 0); sqlite3_bind_int64(s, 4, event.output ?? 0)
            sqlite3_bind_int64(s, 5, event.cached ?? 0)
            sqlite3_bind_int(s, 6, event.outcome == "complete" ? 0 : 1)
            sqlite3_bind_int(s, 7, event.input == nil || event.output == nil ? 1 : 0)
            let result = sqlite3_step(s); sqlite3_finalize(s)
            guard result == SQLITE_DONE else { throw failure() }
            try exec("COMMIT")
        } catch { try? exec("ROLLBACK"); throw error }
    }
    public func totals(today: Bool) throws -> UsageTotals {
        var s: OpaquePointer?
        let sql = "SELECT coalesce(sum(input),0),coalesce(sum(output),0),coalesce(sum(cached),0),coalesce(sum(requests),0),coalesce(sum(errors),0),coalesce(sum(unknown),0) FROM totals"
            + (today ? " WHERE day=date('now','localtime')" : "")
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw failure() }
        var result = UsageTotals()
        result.input = sqlite3_column_int64(s, 0); result.output = sqlite3_column_int64(s, 1)
        result.cached = sqlite3_column_int64(s, 2); result.requests = sqlite3_column_int64(s, 3)
        result.errors = sqlite3_column_int64(s, 4); result.unknown = sqlite3_column_int64(s, 5)
        return result
    }
}
