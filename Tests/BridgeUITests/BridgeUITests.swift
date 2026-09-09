import XCTest
import AppKit
import SwiftUI
import BridgeUI
import BridgeCore
@testable import BridgeRuntime

/// Renders only our own SwiftUI views offscreen; never captures the user's screen.
@MainActor
final class BridgeUITests: XCTestCase {
    func testPopoverPagesRenderAtTheirActualSizeWithoutStartingAService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cbm-ui-test-\(UUID())")
        try AppPaths.prepare(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = BridgeController(root: root.appendingPathComponent("data"), backend: nil,
                                          home: root, heartbeat: 1000)
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertNil(controller.servicePID)
        // Optional developer artifact directory, not a screenshot of any real app.
        let output = ProcessInfo.processInfo.environment["CBM_RENDER_OUTPUT"].map { URL(fileURLWithPath: $0) }
        if let output { try AppPaths.prepare(output) }
        _ = NSApplication.shared
        for (index, title) in ["overview", "settings", "logs"].enumerated() {
            let view = MenuView(controller: controller, initialTab: index)
                .environment(\.colorScheme, .light)
                .background(Color(nsColor: .windowBackgroundColor))
            // ImageRenderer cannot render AppKit-backed segmented controls/scroll views.
            // Cache our own hidden hosting view instead. Never order a window on screen.
            let rectangle = NSRect(x: 0, y: 0, width: 420, height: 620)
            let host = NSHostingView(rootView: view)
            host.frame = rectangle
            host.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: rectangle, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertEqual(host.bounds.size.width, 420)
            XCTAssertEqual(host.bounds.size.height, 620)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 10000, "Blank \(title) rendering")
            if let output { try png.write(to: output.appendingPathComponent("\(title).png")) }
            window.close()
        }
        XCTAssertEqual(controller.state, .stopped)
        XCTAssertNil(controller.servicePID)
    }
}
