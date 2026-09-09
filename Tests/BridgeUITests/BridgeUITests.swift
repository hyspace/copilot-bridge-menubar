import XCTest
import AppKit
import SwiftUI
@testable import BridgeUI
import BridgeCore
import CSQLite
@testable import BridgeRuntime

/// Renders only our own SwiftUI views offscreen; never captures the user's screen.
@MainActor
final class BridgeUITests: XCTestCase {
    private func seedSyntheticHistory(at root: URL) throws {
        try AppPaths.prepare(root)
        let path = root.appendingPathComponent("usage.sqlite")
        let store = try UsageStore(url: path)
        let now = Date()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for (index, day) in ActivityCalendar.grid(ending: now).enumerated() where !day.isFuture {
            if index % 6 != 0 {
                let input = ((index * 47) % 13 + 1) * 1800
                let sql = "INSERT INTO totals VALUES('\(day.id)','synthetic',\(input),\(input / 5),\(input / 3),\(index % 10 + 2),0,0)"
                XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
            }
            if index % 9 != 0 {
                let quota = try QuotaSnapshot.decode(Data("""
                {"token_based_billing":true,"quota_snapshots":{"premium_interactions":{
                "quota_remaining":\(10000 - Double(index) * 10.25),"entitlement":10000,
                "credits_used":\(Double(index) * 10.25),"percent_remaining":\((10000 - Double(index) * 10.25) / 100),"unlimited":false}}}
                """.utf8))
                let observed = min(day.date.addingTimeInterval(12 * 3600), now)
                try store.recordQuota(quota, at: observed)
            }
        }
    }

    func testPopoverPagesRenderAtTheirActualSizeWithoutStartingAService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cbm-ui-test-\(UUID())")
        try AppPaths.prepare(root)
        defer { try? FileManager.default.removeItem(at: root) }
        try seedSyntheticHistory(at: root.appendingPathComponent("data"))
        let controller = BridgeController(root: root.appendingPathComponent("data"), backend: nil,
                                          home: root, heartbeat: 1000)
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertNil(controller.servicePID)
        // Optional developer artifact directory, not a screenshot of any real app.
        let output = ProcessInfo.processInfo.environment["CBM_RENDER_OUTPUT"].map { URL(fileURLWithPath: $0) }
        if let output { try AppPaths.prepare(output) }
        _ = NSApplication.shared
        for (index, title, dark) in [(0, "overview", false), (0, "overview-dark", true),
                                    (1, "settings", false), (2, "logs", false)] {
            let view = MenuView(controller: controller, initialTab: index)
                .environment(\.colorScheme, dark ? .dark : .light)
                .background(Color(nsColor: .windowBackgroundColor))
            // ImageRenderer cannot render AppKit-backed segmented controls/scroll views.
            // Cache our own hidden hosting view instead. Never order a window on screen.
            let rectangle = NSRect(x: 0, y: 0, width: PanelLayout.width, height: PanelLayout.height)
            let host = NSHostingView(rootView: view)
            host.frame = rectangle
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let window = NSWindow(contentRect: rectangle, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertEqual(host.bounds.size.width, PanelLayout.width)
            XCTAssertEqual(host.bounds.size.height, PanelLayout.height)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 10000, "Blank \(title) rendering")
            if let output { try png.write(to: output.appendingPathComponent("\(title).png")) }
            window.close()
        }
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertNil(controller.servicePID)
    }

    func testHoverDetailsContainBothTokensAndRealCreditSnapshot() throws {
        let now = Date()
        var usage = UsageTotals()
        usage.input = 1200; usage.output = 300; usage.cached = 400; usage.requests = 2
        let snapshot = try QuotaSnapshot.decode(Data("""
        {"token_based_billing":true,"quota_snapshots":{"premium_interactions":{
        "quota_remaining":8125.375,"entitlement":10000,"credits_used":1874.625}}}
        """.utf8))
        var day = ActivityDay(date: now, usage: usage,
                              quota: QuotaObservation(snapshot: snapshot, observedAt: now))
        let tooltip = ActivityText.tooltip(day)
        XCTAssertTrue(tooltip.contains("1,500 recorded tokens"))
        XCTAssertTrue(tooltip.contains("8,125.375 credits remaining"))
        XCTAssertTrue(tooltip.contains("Account-wide balance observed"))
        XCTAssertTrue(tooltip.contains("Credits used this billing cycle: 1,874.625"))
        day.quota = nil
        XCTAssertEqual(ActivityText.balance(day), "Credits: not recorded")
        XCTAssertTrue(ActivityText.tooltip(day).contains("cannot be reconstructed"))
        usage = UsageTotals(); usage.unknown = 1; usage.requests = 1
        day.usage = usage
        XCTAssertEqual(ActivityText.tokens(day), "Tokens unreported")
        XCTAssertTrue(ActivityText.tooltip(day).contains("missing token usage"))
    }
}
