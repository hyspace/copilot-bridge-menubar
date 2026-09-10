import XCTest
import CSQLite
@testable import BridgeCore

final class ProviderUsageTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cbm-provider-test-\(UUID())")
        try AppPaths.prepare(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testSameModelAndRequestIDStayIndependentAcrossSources() throws {
        let store = try UsageStore(url: root().appendingPathComponent("usage.sqlite"))
        for source in UsageProvider.allCases {
            var event = UsageEvent(kind: "usage", id: "same-request", timestamp: Date().timeIntervalSince1970,
                model: "same-model", status: 200, input: 100, output: 10, cached: 80, outcome: "complete", nanoAiu: 1000000000)
            event.provider = source
            try store.record(event); try store.record(event)
        }
        let total = try store.totals(today: true)
        XCTAssertEqual(total.requests, 3)
        XCTAssertEqual(total.input + total.output, 330)
        XCTAssertEqual(total.credits, 1) // A local/Codex extension cannot be counted as Copilot credits.
        XCTAssertEqual(total.billingRequests, 1)
        XCTAssertEqual(total.unknownCredits, 0)
        let day = try XCTUnwrap(store.activity().last { !$0.isFuture })
        XCTAssertEqual(day.providers.count, 3)
        XCTAssertEqual(day.tokens, 330)
        for source in UsageProvider.allCases {
            XCTAssertEqual(day.providers[source]?.input, 100)
            XCTAssertEqual(try store.totals(today: true, provider: source).requests, 1)
        }
    }
    func testLegacyMigrationMakesSnapshotAndKeepsRowsAndDeduplication() throws {
        let url = try root().appendingPathComponent("usage.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
          CREATE TABLE totals(day TEXT NOT NULL,model TEXT NOT NULL,input INTEGER NOT NULL DEFAULT 0,
          output INTEGER NOT NULL DEFAULT 0,cached INTEGER NOT NULL DEFAULT 0,requests INTEGER NOT NULL DEFAULT 0,
          errors INTEGER NOT NULL DEFAULT 0,unknown INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(day,model));
          INSERT INTO totals VALUES(date('now','localtime'),'old-model',100,20,10,1,0,0);
          CREATE TABLE seen(id TEXT PRIMARY KEY,timestamp REAL NOT NULL);
          INSERT INTO seen VALUES('old-id',strftime('%s','now'));
          """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let store = try UsageStore(url: url)
        let backup = url.appendingPathExtension("before-providers-v2.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(Array(try Data(contentsOf: backup)[18..<20]), [1, 1], "Snapshot must not require WAL/SHM sidecars")
        let event = UsageEvent(kind: "usage", id: "old-id", timestamp: Date().timeIntervalSince1970,
            model: "old-model", status: 200, input: 100, output: 20, cached: 10, outcome: "complete")
        try store.record(event)
        XCTAssertEqual(try store.totals(today: true, provider: .copilot).requests, 1)
        XCTAssertEqual(try store.totals(today: true, provider: .local).requests, 0)
        XCTAssertEqual(try UsageStore(url: url).totals(today: true).input, 100)
    }
    func testMissingProviderIsLegacyCopilotButInvalidProviderIsRejected() throws {
        let base = #"{"kind":"usage","id":"x","timestamp":1,"model":"m","status":200,"outcome":"complete""#
        let old = try JSONDecoder().decode(UsageEvent.self, from: Data((base + "}").utf8))
        XCTAssertEqual(old.provider, .copilot)
        XCTAssertThrowsError(try JSONDecoder().decode(UsageEvent.self, from: Data((base + #","provider":"unexpected"}"#).utf8)))
    }
    func testLegacySettingsRetainValuesAndUseSafeNewDefaults() throws {
        let settings = try JSONDecoder().decode(BridgeSettings.self, from: Data(#"{"port":4143,"model":"old-model","debug":true}"#.utf8))
        XCTAssertEqual(settings.port, 4143); XCTAssertEqual(settings.model, "old-model")
        XCTAssertTrue(settings.codexEnabled); XCTAssertTrue(settings.copilotEnabled)
        XCTAssertFalse(settings.localEnabled); XCTAssertEqual(settings.localURL, "")
        let path = try settings.writeGatewaySettings(root: root())
        let text = try String(contentsOf: path, encoding: .utf8)
        XCTAssertFalse(text.contains("access_token")); XCTAssertFalse(text.contains("refresh_token"))
        XCTAssertEqual(settings.arguments(gatewaySettingsPath: path.path).first, "gateway")
    }
    func testProviderQuotaHistoryNeverReplacesAnotherSourcesSnapshot() throws {
        let store = try UsageStore(url: root().appendingPathComponent("usage.sqlite"))
        let a = Data(#"{"provider":"codex","windows":[]}"#.utf8)
        let b = Data(#"{"provider":"copilot","remaining":10}"#.utf8)
        try store.recordProviderQuota(.codex, data: a)
        try store.recordProviderQuota(.copilot, data: b)
        XCTAssertEqual(try store.latestProviderQuota(.codex), a)
        XCTAssertEqual(try store.latestProviderQuota(.copilot), b)
    }
    private func legacyDatabase(_ url: URL, model: String = "old") throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, """
          CREATE TABLE totals(day TEXT NOT NULL,model TEXT NOT NULL,input INTEGER NOT NULL DEFAULT 0,
          output INTEGER NOT NULL DEFAULT 0,cached INTEGER NOT NULL DEFAULT 0,requests INTEGER NOT NULL DEFAULT 0,
          errors INTEGER NOT NULL DEFAULT 0,unknown INTEGER NOT NULL DEFAULT 0,
          nano_aiu REAL NOT NULL DEFAULT 0,credit_reports INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(day,model));
          INSERT INTO totals VALUES(date('now','localtime'),'\(model)',123,0,0,1,0,0,0,0);
          CREATE TABLE seen(id TEXT PRIMARY KEY,timestamp REAL NOT NULL);
          """, nil, nil, nil), SQLITE_OK)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func testCorruptMigrationBackupFailsClosedAndKeepsOriginalRows() throws {
        let url = try root().appendingPathComponent("usage.sqlite")
        try legacyDatabase(url)
        let backup = url.appendingPathExtension("before-providers-v2.sqlite")
        let corrupt = Data(repeating: 120, count: 1024)
        try corrupt.write(to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        XCTAssertThrowsError(try UsageStore(url: url))
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT input FROM totals", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(statement, 0), 123)
        sqlite3_finalize(statement)
        XCTAssertNotEqual(sqlite3_prepare_v2(db, "SELECT provider FROM totals", -1, &statement, nil), SQLITE_OK)
        sqlite3_finalize(statement)
    }
    func testRetryRetainsOldBackupButCreatesAConsistentNewSnapshot() throws {
        let url = try root().appendingPathComponent("usage.sqlite")
        try legacyDatabase(url, model: "new-state")
        let backup = url.appendingPathExtension("before-providers-v2.sqlite")
        try legacyDatabase(backup, model: "earlier-state")
        let original = try Data(contentsOf: backup)
        let store = try UsageStore(url: url)
        XCTAssertEqual(try store.totals(today: true).input, 123)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        let retry = try XCTUnwrap(files.first { $0.lastPathComponent.contains("before-providers-v2.retry-") })
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(retry.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT model FROM totals", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "new-state")
    }
    func testUsageDatabaseSymlinkCannotMutateItsTargetBeforeMigration() throws {
        let directory = try root()
        let target = directory.appendingPathComponent("original.sqlite")
        let link = directory.appendingPathComponent("usage.sqlite")
        try legacyDatabase(target)
        let before = try Data(contentsOf: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try UsageStore(url: link))
        XCTAssertEqual(try Data(contentsOf: target), before)
    }
}
