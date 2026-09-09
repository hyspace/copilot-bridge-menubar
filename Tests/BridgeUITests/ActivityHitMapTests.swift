import XCTest
import BridgeCore
@testable import BridgeUI

final class ActivityHitMapTests: XCTestCase {
    private func completeGrid() throws -> [ActivityDay] {
        var calendar = ActivityCalendar.local
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let saturday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 5)))
        return ActivityCalendar.grid(ending: saturday, calendar: calendar)
    }
    func testVisualDimensionsRemainUnchanged() {
        XCTAssertEqual(ActivityHitMap.side, 10)
        XCTAssertEqual(ActivityHitMap.gap, 2.5)
        XCTAssertEqual(ActivityHitMap.gridWidth(columns: 26), 322.5)
        XCTAssertEqual(ActivityHitMap.gridHeight, 85)
        XCTAssertEqual(ActivityHitMap.rowOrigin, 14.5)
    }
    func testHorizontalAndVerticalGuttersBelongToAdjacentDays() throws {
        let days = try completeGrid()
        let origin = ActivityHitMap.rowOrigin
        XCTAssertEqual(ActivityHitMap.index(at: CGPoint(x: 10.5, y: origin + 5), days: days), 0)
        XCTAssertEqual(ActivityHitMap.index(at: CGPoint(x: 12, y: origin + 5), days: days), 7)
        XCTAssertEqual(ActivityHitMap.index(at: CGPoint(x: 5, y: origin + 10.5), days: days), 0)
        XCTAssertEqual(ActivityHitMap.index(at: CGPoint(x: 5, y: origin + 12), days: days), 1)
        XCTAssertEqual(ActivityHitMap.index(at: CGPoint(x: 11.25, y: origin + 11.25), days: days), 8)
    }
    func testSweepingThroughEveryRowAndColumnHasNoHoverHoles() throws {
        let days = try completeGrid()
        let pitch = ActivityHitMap.side + ActivityHitMap.gap
        for row in 0..<7 {
            for x in stride(from: CGFloat(0), through: ActivityHitMap.gridWidth(columns: 26), by: 0.25) {
                let index = ActivityHitMap.index(
                    at: CGPoint(x: x, y: ActivityHitMap.rowOrigin + CGFloat(row) * pitch + 5), days: days)
                XCTAssertNotNil(index)
                XCTAssertEqual(index.map { $0 % 7 }, row)
            }
        }
        for column in 0..<26 {
            for y in stride(from: CGFloat(0), through: ActivityHitMap.gridHeight, by: 0.25) {
                let index = ActivityHitMap.index(
                    at: CGPoint(x: CGFloat(column) * pitch + 5, y: ActivityHitMap.rowOrigin + y), days: days)
                XCTAssertNotNil(index)
                XCTAssertEqual(index.map { $0 / 7 }, column)
            }
        }
    }
    func testOutsideGridAndFutureCellsAreNotInteractive() throws {
        var days = try completeGrid()
        for point in [CGPoint(x: -1, y: 20), CGPoint(x: 10, y: 0),
                      CGPoint(x: 323, y: 20), CGPoint(x: 5, y: 100),
                      CGPoint(x: CGFloat.infinity, y: 20)] {
            XCTAssertNil(ActivityHitMap.index(at: point, days: days))
        }
        days[0].isFuture = true
        XCTAssertNil(ActivityHitMap.index(at: CGPoint(x: 5, y: ActivityHitMap.rowOrigin + 5), days: days))
        XCTAssertNil(ActivityHitMap.index(at: .zero, days: []))
    }
}
