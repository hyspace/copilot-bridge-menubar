import XCTest
import CSQLite
@testable import BridgeCore

final class UsageRecoveryTests: XCTestCase {
    private func fixture() throws -> (URL, UsageStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cbm-recovery-\(UUID())")
        try AppPaths.prepare(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, try UsageStore(url: root.appendingPathComponent("usage.sqlite")))
    }
    private func event(_ id: String = UUID().uuidString) -> UsageEvent {
        UsageEvent(kind: "usage", id: id, timestamp: Date().timeIntervalSince1970,
                   model: "synthetic", status: 200, input: 100, output: 20,
                   cached: 10, outcome: "complete", nanoAiu: 125_000_000)
    }
    private func sql(_ root: URL, _ command: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("usage.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, command, nil, nil, nil), SQLITE_OK)
    }
    func testExplicitSeenColumnsAllowAnAdditiveSchemaExtension() throws {
        let (root, _) = try fixture()
        try sql(root, "ALTER TABLE seen ADD COLUMN extra TEXT")
        let reopened = try UsageStore(url: root.appendingPathComponent("usage.sqlite"))
        try reopened.record(event())
        XCTAssertEqual(try reopened.totals(today: true).requests, 1)
    }
    func testProviderSchemaIsRejectedBeforeAnyMigrationOrCleanup() throws {
        let (root, _) = try fixture()
        try sql(root, """
        DROP TABLE seen;
        CREATE TABLE seen(id TEXT,timestamp REAL,provider TEXT,PRIMARY KEY(provider,id));
        INSERT INTO seen VALUES('old',1,'copilot');
        """)
        XCTAssertThrowsError(try UsageStore(url: root.appendingPathComponent("usage.sqlite"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("incompatible version"))
        }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("usage.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM seen WHERE timestamp=1", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1, "Incompatible data must not be pruned")
    }
    func testIDsSurviveTheEntireThreeDayReplayWindow() throws {
        let (root, store) = try fixture()
        var value = event()
        value.timestamp -= 2.5 * 86400
        try store.record(value)
        let reopened = try UsageStore(url: root.appendingPathComponent("usage.sqlite"))
        try reopened.record(value)
        XCTAssertEqual(try reopened.totals(today: false).requests, 1)
    }
    func testJournalSurvivesRestartAndCommitBeforeAckDoesNotDoubleCount() throws {
        let (root, store) = try fixture()
        let directory = root.appendingPathComponent("journal")
        let journal = try UsageJournal(root: directory)
        let first = event(), second = event()
        let entry = try journal.stage(first)
        _ = try journal.stage(second)
        try store.record(first) // Simulate a crash after commit and before deleting its file.
        let permissions = try FileManager.default.attributesOfItem(atPath: entry.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(try UsageJournal(root: directory).replay(into: store), 2)
        XCTAssertEqual(try store.totals(today: true).requests, 2)
        XCTAssertEqual(try store.totals(today: true).credits, 0.25)
        XCTAssertEqual(try journal.replay(into: store), 0)
    }
    func testFailedWriteLeavesJournalAndRollsBackDedupUntilRetry() throws {
        let (root, store) = try fixture()
        let journal = try UsageJournal(root: root.appendingPathComponent("journal"))
        let entry = try journal.stage(event())
        try sql(root, "CREATE TRIGGER fail_write BEFORE INSERT ON totals BEGIN SELECT RAISE(ABORT,'injected'); END")
        XCTAssertThrowsError(try journal.replay(into: store))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path))
        XCTAssertEqual(try store.totals(today: true).requests, 0)
        try sql(root, "DROP TRIGGER fail_write")
        XCTAssertEqual(try journal.replay(into: store), 1)
        XCTAssertEqual(try store.totals(today: true).requests, 1)
    }
    func testInvalidEntriesAreKeptWithoutBlockingValidMetadata() throws {
        let (root, store) = try fixture()
        let directory = root.appendingPathComponent("journal")
        let journal = try UsageJournal(root: directory)
        let corrupt = directory.appendingPathComponent("000-corrupt.json")
        try Data("not JSON".utf8).write(to: corrupt)
        _ = try journal.stage(event())
        XCTAssertThrowsError(try journal.replay(into: store))
        XCTAssertEqual(try store.totals(today: true).requests, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
    }
    func testJournalBoundsDoNotEvictExistingRecords() throws {
        let (root, _) = try fixture()
        let journal = try UsageJournal(root: root.appendingPathComponent("journal"), limit: 1)
        let entry = try journal.stage(event())
        XCTAssertThrowsError(try journal.stage(event()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path))
    }
    func testTypedJournalNeverCopiesResponseOrChannelFields() throws {
        let (root, _) = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event())) as? [String: Any])
        object["channel"] = "PRIVATE-CHANNEL"
        object["response"] = "PRIVATE-RESPONSE"
        let decoded = try JSONDecoder().decode(UsageEvent.self, from: JSONSerialization.data(withJSONObject: object))
        let journal = try UsageJournal(root: root.appendingPathComponent("journal"))
        let text = try String(contentsOf: journal.stage(decoded), encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE"))
    }
}
