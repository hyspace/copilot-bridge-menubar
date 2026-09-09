import XCTest
import CSQLite
@testable import BridgeCore

final class ActivityTests: XCTestCase {
    private func temporaryDatabase() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try AppPaths.prepare(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("usage.sqlite")
    }
    private func credits(_ remaining: Double) throws -> QuotaSnapshot {
        try QuotaSnapshot.decode(Data("""
        {"token_based_billing":true,"quota_snapshots":{"premium_interactions":{
          "quota_remaining":\(remaining),"entitlement":10000,"credits_used":1234.5678,"unlimited":false}}}
        """.utf8))
    }
    func testCalendarIsSundayAlignedAndDoesNotSkipDSTDays() throws {
        var calendar = ActivityCalendar.local
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        for parts in [DateComponents(year: 2026, month: 3, day: 11),
                      DateComponents(year: 2026, month: 11, day: 4)] {
            let end = try XCTUnwrap(calendar.date(from: parts))
            let days = ActivityCalendar.grid(ending: end, calendar: calendar)
            XCTAssertEqual(days.count, 182)
            XCTAssertEqual(Set(days.map(\.id)).count, 182)
            XCTAssertEqual(calendar.component(.weekday, from: days[0].date), 1)
            XCTAssertEqual(days.filter(\.isFuture).count, 3)
            XCTAssertEqual(days.last(where: { !$0.isFuture })?.id, ActivityCalendar.key(end, calendar: calendar))
            for pair in zip(days, days.dropFirst()) {
                XCTAssertEqual(calendar.dateComponents([.day], from: pair.0.date, to: pair.1.date).day, 1)
            }
        }
        XCTAssertEqual(ActivityCalendar.grid(weeks: 0).count, 7)
        XCTAssertEqual(ActivityCalendar.grid(weeks: Int.max).count, 371)
    }
    func testIntensityCountsCacheOnlyOnceAndRetainsUnknownUsage() {
        var usage = UsageTotals()
        usage.input = 80; usage.output = 20; usage.cached = 70
        let day = ActivityDay(date: Date(), usage: usage)
        XCTAssertEqual(day.tokens, 100)
        XCTAssertEqual(day.intensity(maximum: 400), 1)
        XCTAssertEqual(day.intensity(maximum: 200), 2)
        XCTAssertEqual(day.intensity(maximum: 140), 3)
        XCTAssertEqual(day.intensity(maximum: 100), 4)
        usage = UsageTotals(); usage.unknown = 1; usage.requests = 1
        let unknown = ActivityDay(date: Date(), usage: usage)
        XCTAssertEqual(unknown.intensity(maximum: 100), 0)
        XCTAssertTrue(unknown.hasUnknownUsage)
    }
    func testDailyAggregationAcrossModelsAndCreditsSurviveReopening() throws {
        let path = try temporaryDatabase()
        let store = try UsageStore(url: path)
        for index in 0..<2 {
            try store.record(UsageEvent(kind: "usage", id: "day-\(index)", timestamp: Date().timeIntervalSince1970,
                model: "model-\(index)", status: 200, input: 100, output: 20, cached: 50, outcome: "complete"))
        }
        let snapshot = try credits(8765.4321)
        let now = Date()
        try store.recordQuota(snapshot, at: now)
        let reopened = try UsageStore(url: path)
        let day = try XCTUnwrap(reopened.activity().first { $0.id == ActivityCalendar.key(now) })
        XCTAssertEqual(day.tokens, 240)
        XCTAssertEqual(day.usage.cached, 100)
        XCTAssertEqual(day.usage.requests, 2)
        XCTAssertEqual(day.quota?.snapshot, snapshot)
        XCTAssertEqual(try reopened.latestQuota()?.observedAt.timeIntervalSince1970, now.timeIntervalSince1970)
        XCTAssertNil(try reopened.activity().first?.quota)
    }
    func testOutOfOrderQuotaDoesNotReplaceLatestDailyBalance() throws {
        let store = try UsageStore(url: temporaryDatabase())
        let calendar = ActivityCalendar.local
        let noon = try XCTUnwrap(calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: Date())))
        try store.recordQuota(credits(50.125), at: noon)
        try store.recordQuota(credits(100), at: noon.addingTimeInterval(-60))
        XCTAssertEqual(try store.latestQuota()?.snapshot.remaining, 50.125)
        try store.recordQuota(credits(40.0625), at: noon.addingTimeInterval(60))
        XCTAssertEqual(try store.latestQuota()?.snapshot.remaining, 40.0625)
        XCTAssertEqual(try store.activity().filter { $0.quota != nil }.count, 1)
    }
    func testLegacyUnitsAndMalformedNumbersNeverBecomeCreditBalances() throws {
        let legacy = try QuotaSnapshot.decode(Data("""
        {"quota_snapshots":{"premium_interactions":{"remaining":42,"credits_used":8}}}
        """.utf8))
        XCTAssertEqual(legacy.kind, .premiumInteractions)
        XCTAssertNil(legacy.creditsUsed)
        let malformed = try QuotaSnapshot.decode(Data("""
        {"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"quota_remaining":true}}}
        """.utf8))
        XCTAssertNil(malformed.remaining)
        let store = try UsageStore(url: temporaryDatabase())
        try store.recordQuota(legacy)
        XCTAssertEqual(try store.latestQuota()?.snapshot.kind, .premiumInteractions)
    }
    func testExistingTokenDatabaseMigratesWithoutLosingRecords() throws {
        let path = try temporaryDatabase()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE totals(day TEXT NOT NULL,model TEXT NOT NULL,input INTEGER NOT NULL DEFAULT 0,
        output INTEGER NOT NULL DEFAULT 0,cached INTEGER NOT NULL DEFAULT 0,requests INTEGER NOT NULL DEFAULT 0,
        errors INTEGER NOT NULL DEFAULT 0,unknown INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(day,model));
        INSERT INTO totals VALUES(date('now','localtime'),'existing',123,45,60,2,0,0);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let migrated = try UsageStore(url: path)
        XCTAssertEqual(try migrated.totals(today: true).input, 123)
        XCTAssertNil(try migrated.latestQuota())
        try migrated.recordQuota(credits(100.25))
        XCTAssertEqual(try migrated.totals(today: true).requests, 2)
        XCTAssertEqual(try migrated.activity().last(where: { !$0.isFuture })?.tokens, 168)
    }
}
