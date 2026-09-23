import XCTest
@testable import BridgeCore

final class QuotaMonthProgressTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func testMonthBoundariesAndLeapFebruary() {
        let start = date("2028-02-01T00:00:00Z")
        XCTAssertEqual(QuotaMonthProgress(now: start, observedAt: start, reset: nil).fraction, 0)
        let middle = date("2028-02-15T12:00:00Z")
        XCTAssertEqual(QuotaMonthProgress(now: middle, observedAt: middle, reset: nil).fraction, 0.5)
        let next = date("2028-03-01T00:00:00Z")
        XCTAssertEqual(QuotaMonthProgress(now: next, observedAt: middle, reset: nil).fraction, 0)
        XCTAssertFalse(QuotaMonthProgress(now: next, observedAt: middle, reset: nil).canCompareBalance)
    }
    func testUTCReferenceIsUnaffectedByDaylightSavingTime() {
        let middle = date("2026-03-16T12:00:00Z")
        XCTAssertEqual(QuotaMonthProgress(now: middle, observedAt: middle, reset: nil).fraction, 0.5)
    }
    func testMissingFutureOrStaleObservationsCannotClaimPace() {
        let now = date("2026-09-22T12:00:00Z")
        for observed in [nil, now.addingTimeInterval(-901), now.addingTimeInterval(1)] {
            XCTAssertFalse(QuotaMonthProgress(now: now, observedAt: observed, reset: nil).canCompareBalance)
        }
        XCTAssertTrue(QuotaMonthProgress(now: now, observedAt: now.addingTimeInterval(-300), reset: nil).canCompareBalance)
    }
    func testResetParsingAndPastCycleProtection() {
        let now = date("2026-09-22T12:00:00Z")
        for reset in ["2026-10-01", "2026-10-01T00:00:00Z", "2026-10-01T00:00:00.000Z"] {
            XCTAssertTrue(QuotaMonthProgress(now: now, observedAt: now, reset: reset).canCompareBalance)
        }
        for reset in ["2026-09-22", "2026-09-22T12:00:00Z", "invalid"] {
            XCTAssertFalse(QuotaMonthProgress(now: now, observedAt: now, reset: reset).canCompareBalance)
        }
    }
}
