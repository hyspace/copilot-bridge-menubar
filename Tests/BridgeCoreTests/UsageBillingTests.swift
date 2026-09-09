import XCTest
import CSQLite
@testable import BridgeCore

final class UsageBillingTests: XCTestCase {
    private func database() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try AppPaths.prepare(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("usage.sqlite")
    }
    private func event(_ id: String, billing: Double?, input: Int64? = 100,
                       output: Int64? = 20, outcome: String = "complete") -> UsageEvent {
        UsageEvent(kind: "usage", id: id, timestamp: Date().timeIntervalSince1970,
            model: "test-\(id)", status: outcome == "complete" ? 200 : 503,
            input: input, output: output, cached: nil, outcome: outcome, nanoAiu: billing)
    }
    func testChargesAreAggregatedOnceAcrossModelsAndErrors() throws {
        let path = try database()
        let store = try UsageStore(url: path)
        let paid = event("paid", billing: 1_234_567_891)
        try store.record(paid); try store.record(paid)
        try store.record(event("free", billing: 0, input: 0, output: 0))
        try store.record(event("billing-only", billing: 250_000_000, input: nil, output: nil, outcome: "http_error"))
        try store.record(event("missing", billing: nil, input: 7, output: 3))
        let reopened = try UsageStore(url: path)
        for total in [try reopened.totals(today: true), try reopened.totals(today: false),
                      try XCTUnwrap(reopened.activity().last { !$0.isFuture }).usage] {
            XCTAssertEqual(total.requests, 4)
            XCTAssertEqual(total.input, 107); XCTAssertEqual(total.output, 23)
            XCTAssertEqual(total.unknown, 1); XCTAssertEqual(total.errors, 1)
            XCTAssertEqual(total.creditReports, 3); XCTAssertEqual(total.unknownCredits, 1)
            XCTAssertEqual(total.nanoAiu, 1_484_567_891)
            XCTAssertEqual(try XCTUnwrap(total.credits), 1.484567891, accuracy: 0.000000000001)
        }
    }
    func testZeroIsKnownButMissingBillingStaysUnknown() throws {
        let store = try UsageStore(url: database())
        try store.record(event("missing", billing: nil))
        XCTAssertNil(try store.totals(today: true).credits)
        XCTAssertEqual(try store.totals(today: true).unknownCredits, 1)
        try store.record(event("zero", billing: 0))
        XCTAssertEqual(try store.totals(today: true).credits, 0)
        XCTAssertEqual(try store.totals(today: true).creditReports, 1)
        XCTAssertEqual(try store.totals(today: true).unknownCredits, 1)
    }
    func testFractionalNanoUnitsAndInvalidBillingDoNotLoseTokenCounts() throws {
        let store = try UsageStore(url: database())
        try store.record(event("fraction", billing: 0.5))
        for (index, value) in [-1.0, .nan, .infinity, 9_007_199_254_741_000].enumerated() {
            try store.record(event("invalid-\(index)", billing: value))
        }
        let total = try store.totals(today: true)
        XCTAssertEqual(total.requests, 5); XCTAssertEqual(total.input, 500)
        XCTAssertEqual(total.creditReports, 1); XCTAssertEqual(total.unknownCredits, 4)
        XCTAssertEqual(try XCTUnwrap(total.credits), 0.0000000005, accuracy: 0.000000000000001)
        try store.record(event("invalid-tokens", billing: 125_000_000, input: -1, output: 1_000_000_001))
        let updated = try store.totals(today: true)
        XCTAssertEqual(updated.input, 500)
        XCTAssertEqual(updated.unknown, 1)
        XCTAssertEqual(updated.creditReports, 2)
        XCTAssertEqual(try XCTUnwrap(updated.credits), 0.1250000005, accuracy: 0.000000000000001)
    }
    func testOldAndMalformedBillingEventsDecodeWithoutLosingTokens() throws {
        let base = """
        {"kind":"usage","id":"one","timestamp":1,"model":"test","status":200,
        "input":100,"output":20,"cached":null,"outcome":"complete"
        """
        for suffix in ["}", ",\"nanoAiu\":null}", ",\"nanoAiu\":\"invalid\"}", ",\"nanoAiu\":true}"] {
            let value = try JSONDecoder().decode(UsageEvent.self, from: Data((base + suffix).utf8))
            XCTAssertEqual(value.input, 100); XCTAssertNil(value.nanoAiu)
        }
        let value = try JSONDecoder().decode(UsageEvent.self, from: Data((base + ",\"nanoAiu\":1250000000}").utf8))
        XCTAssertEqual(value.nanoAiu, 1_250_000_000)
    }
    func testMigrationMarksHistoricalRequestsUnknownNotFreeAndNeverUsesBalanceAsCost() throws {
        let path = try database()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE totals(day TEXT NOT NULL,model TEXT NOT NULL,input INTEGER NOT NULL DEFAULT 0,
        output INTEGER NOT NULL DEFAULT 0,cached INTEGER NOT NULL DEFAULT 0,requests INTEGER NOT NULL DEFAULT 0,
        errors INTEGER NOT NULL DEFAULT 0,unknown INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(day,model));
        INSERT INTO totals VALUES(date('now','localtime'),'old',1000,200,500,4,0,0);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(db)
        let store = try UsageStore(url: path)
        let snapshot = try QuotaSnapshot.decode(Data("""
        {"token_based_billing":true,"quota_snapshots":{"premium_interactions":{
          "quota_remaining":9000,"credits_used":1000,"entitlement":10000}}}
        """.utf8))
        try store.recordQuota(snapshot)
        let reopened = try UsageStore(url: path)
        let old = try XCTUnwrap(reopened.activity().last { !$0.isFuture })
        XCTAssertEqual(old.tokens, 1200)
        XCTAssertNil(old.usage.credits); XCTAssertEqual(old.usage.unknownCredits, 4)
        try reopened.record(event("new", billing: 125_000_000))
        let total = try reopened.totals(today: true)
        XCTAssertEqual(total.creditReports, 1); XCTAssertEqual(total.unknownCredits, 4)
        XCTAssertEqual(total.credits, 0.125)
        XCTAssertEqual(try reopened.latestQuota()?.snapshot.remaining, 9000)
    }
}
