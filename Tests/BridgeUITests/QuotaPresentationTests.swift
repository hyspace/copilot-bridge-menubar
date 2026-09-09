import XCTest
import BridgeCore
@testable import BridgeUI

final class QuotaPresentationTests: XCTestCase {
    private func quota(_ fields: String, credits: Bool = true) throws -> QuotaSnapshot {
        try QuotaSnapshot.decode(Data("""
        {"token_based_billing":\(credits),"quota_snapshots":{"premium_interactions":{\(fields)}}}
        """.utf8))
    }

    func testUsesReportedCreditAmountWithoutReplacingItWithRoundedPercent() throws {
        let presentation = QuotaPresentation(snapshot: try quota("""
        "credits_used":250.25,"quota_remaining":749.75,"entitlement":1000,"percent_remaining":75
        """))
        XCTAssertEqual(presentation.used, 250.25)
        XCTAssertEqual(presentation.remaining, 749.75)
        XCTAssertEqual(presentation.remainingFraction, 0.75)
        XCTAssertFalse(presentation.usedIsDerived)
        XCTAssertEqual(presentation.usedTitle, "Credits used")
        XCTAssertEqual(presentation.remainingTitle, "Credits remaining")
    }

    func testMissingBillingHasExplicitlyLabeledLimitedQuotaFallback() throws {
        let presentation = QuotaPresentation(snapshot: try quota("""
        "quota_remaining":750,"entitlement":1000
        """))
        XCTAssertEqual(presentation.used, 250)
        XCTAssertEqual(presentation.remainingFraction, 0.75)
        XCTAssertTrue(presentation.usedIsDerived)
        XCTAssertEqual(presentation.usedTitle, "Credits used (derived)")
    }

    func testMissingAmountsAreNotTreatedAsZeroOrInferredFromPercentage() throws {
        let presentation = QuotaPresentation(snapshot: try quota(#""percent_remaining":70"#))
        XCTAssertNil(presentation.used)
        XCTAssertNil(presentation.remaining)
        XCTAssertEqual(presentation.remainingFraction, 0.7)
        XCTAssertFalse(presentation.usedIsDerived)
        XCTAssertNil(QuotaPresentation(snapshot: try quota("")).remainingFraction)
    }

    func testUnlimitedDoesNotInferConsumptionOrRenderABar() throws {
        var snapshot = try quota(#""unlimited":true,"entitlement":1000,"quota_remaining":750,"percent_remaining":75"#)
        XCTAssertNil(QuotaPresentation(snapshot: snapshot).used)
        XCTAssertNil(QuotaPresentation(snapshot: snapshot).remainingFraction)
        snapshot.creditsUsed = 23
        XCTAssertEqual(QuotaPresentation(snapshot: snapshot).used, 23)
    }

    func testZeroUsageAndExhaustedQuotaHaveOppositeBarEndpoints() throws {
        let unused = QuotaPresentation(snapshot: try quota(#""credits_used":0,"quota_remaining":100,"entitlement":100"#))
        XCTAssertEqual(unused.used, 0)
        XCTAssertEqual(unused.remainingFraction, 1)
        let exhausted = QuotaPresentation(snapshot: try quota(#""quota_remaining":0,"entitlement":100"#))
        XCTAssertEqual(exhausted.used, 100)
        XCTAssertEqual(exhausted.remainingFraction, 0)
        let zeroLimit = QuotaPresentation(snapshot: try quota(#""entitlement":0,"quota_remaining":0"#))
        XCTAssertEqual(zeroLimit.used, 0)
        XCTAssertNil(zeroLimit.remainingFraction)
    }

    func testInvalidValuesAndInconsistentLimitsDoNotProduceInvalidGeometry() throws {
        var snapshot = try quota(#""entitlement":100,"quota_remaining":200,"percent_remaining":120"#)
        XCTAssertNil(QuotaPresentation(snapshot: snapshot).used)
        XCTAssertNil(QuotaPresentation(snapshot: snapshot).remainingFraction)
        snapshot.creditsUsed = .infinity
        snapshot.percentRemaining = .nan
        snapshot.remaining = -1
        XCTAssertNil(QuotaPresentation(snapshot: snapshot).used)
        XCTAssertNil(QuotaPresentation(snapshot: snapshot).remaining)
        XCTAssertNil(QuotaPresentation(snapshot: snapshot).remainingFraction)
        snapshot.remaining = 25
        XCTAssertEqual(QuotaPresentation(snapshot: snapshot).remainingFraction, 0.25)
    }

    func testLegacyQuotaKeepsItsUnits() throws {
        let presentation = QuotaPresentation(snapshot: try quota(
            #""quota_remaining":200,"entitlement":300,"credits_used":900"#, credits: false))
        XCTAssertEqual(presentation.used, 100)
        XCTAssertEqual(presentation.usedTitle, "Used (derived)")
        XCTAssertEqual(presentation.remainingTitle, "Remaining")
    }
}
