import XCTest
import AppKit
import SwiftUI
@testable import BridgeUI

/// Events are dispatched only to our own offscreen test window, never to a real app.
@MainActor
final class PanelInteractionTests: XCTestCase {
    private func click<V: View>(_ view: V, size: NSSize, points: [NSPoint]) async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        // SwiftUI does not route pointer actions in an unordered window.
        // Ordering behind other windows at an offscreen position avoids activation
        // and never moves the real mouse or exposes a test window to the user.
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderBack(nil)
        defer { window.close() }
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        for point in points {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                    location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                NSApplication.shared.sendEvent(event)
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testStandardAccentAndQuitButtonsAcceptClicksInEmptyEdges() async throws {
        for style in [PanelButtonStyle(), PanelButtonStyle(accent: true), PanelButtonStyle(destructive: true)] {
            var clicks = 0
            let view = Button { clicks += 1 } label: {
                Text("Quit").frame(maxWidth: .infinity)
            }.buttonStyle(style)
            let points = [NSPoint(x: 2, y: 2), NSPoint(x: 178, y: 26),
                          NSPoint(x: 90, y: 14), NSPoint(x: 2, y: 14)]
            try await click(view, size: NSSize(width: 180, height: 28), points: points)
            XCTAssertEqual(clicks, points.count)
        }
    }

    func testTabButtonsAcceptClicksAcrossFullWidthIncludingUnselectedTabs() async throws {
        for selected in [false, true] {
            var clicks = 0
            let view = Button("Logs") { clicks += 1 }
                .buttonStyle(PanelTabButtonStyle(selected: selected))
            let points = [NSPoint(x: 2, y: 2), NSPoint(x: 110, y: 22), NSPoint(x: 3, y: 12)]
            try await click(view, size: NSSize(width: 112, height: 24), points: points)
            XCTAssertEqual(clicks, points.count)
        }
    }

    func testDisabledButtonsNeverInvokeTheirAction() async throws {
        var clicks = 0
        let view = Button("Refresh usage") { clicks += 1 }
            .buttonStyle(PanelButtonStyle()).disabled(true)
        try await click(view, size: NSSize(width: 180, height: 28),
                        points: [NSPoint(x: 90, y: 14), NSPoint(x: 2, y: 2)])
        XCTAssertEqual(clicks, 0)
    }

    func testHoverAndPressHaveDistinctFeedbackAndDisabledButtonsHaveNone() {
        // Offscreen synthetic pointer motion cannot produce WindowServer hover
        // transitions. Test feedback state separately without moving the real mouse.
        let normal = PanelButtonFeedback.opacity(enabled: true, pressed: false, hovered: false)
        let hover = PanelButtonFeedback.opacity(enabled: true, pressed: false, hovered: true)
        let press = PanelButtonFeedback.opacity(enabled: true, pressed: true, hovered: true)
        XCTAssertEqual(normal, 0)
        XCTAssertGreaterThan(hover, normal)
        XCTAssertGreaterThan(press, hover)
        for pressed in [true, false] {
            for hovered in [true, false] {
                XCTAssertEqual(PanelButtonFeedback.opacity(enabled: false, pressed: pressed, hovered: hovered), 0)
            }
        }
    }

    func testDisclosureHeaderAndToggleLabelAcceptClicksOutsideText() async throws {
        var expanded = false
        let disclosure = PanelDisclosure(title: "Advanced", expanded: Binding(
            get: { expanded }, set: { expanded = $0 })) { EmptyView() }
        try await click(disclosure, size: NSSize(width: 320, height: 28),
                        points: [NSPoint(x: 220, y: 14)])
        XCTAssertTrue(expanded)
        var enabled = false
        var changes = 0
        let toggle = SettingToggle(title: "Auto mode", value: Binding(
            get: { enabled }, set: { enabled = $0; changes += 1 }))
        try await click(toggle, size: NSSize(width: 320, height: 30),
                        points: [NSPoint(x: 220, y: 15), NSPoint(x: 8, y: 15)])
        XCTAssertEqual(changes, 2, "Each label click must toggle exactly once")
        XCTAssertFalse(enabled)
        try await click(toggle.disabled(true), size: NSSize(width: 320, height: 30),
                        points: [NSPoint(x: 220, y: 15), NSPoint(x: 8, y: 15)])
        XCTAssertEqual(changes, 2, "Disabled labels must not toggle")
    }

    func testQuotaBarRendersGreenOnRightInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: QuotaBar(remainingFraction: 0.75)
                .frame(width: 200).environment(\.colorScheme, scheme))
            let image = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            let left = try XCTUnwrap(bitmap.colorAt(x: 25, y: 2)?.usingColorSpace(.deviceRGB))
            let right = try XCTUnwrap(bitmap.colorAt(x: 150, y: 2)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(left.redComponent, left.greenComponent, accuracy: 0.02)
            XCTAssertGreaterThan(right.greenComponent, right.redComponent + 0.15)
            XCTAssertGreaterThan(right.greenComponent, right.blueComponent + 0.15)
        }
    }

    func testStatusIconRemainsATemplateInLightAndDarkAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                let image = StatusItemIcon.make()
                XCTAssertNotNil(image)
                XCTAssertEqual(image?.isTemplate, true)
                XCTAssertEqual(image?.accessibilityDescription, "Codex Bridge")
            }
        }
    }
    func testMenuMarkUsesTheAppIconsThreeHollowNodesAndTransparentBackground() throws {
        let image = try XCTUnwrap(StatusItemIcon.make())
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 144,
            pixelsHigh: 144, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 144, height: 144))
        image.draw(in: NSRect(x: 0, y: 0, width: 144, height: 144))
        context.cgContext.flush()
        NSGraphicsContext.restoreGraphicsState()
        func alpha(x: Int, y: Int) -> CGFloat { bitmap.colorAt(x: x, y: y)?.alphaComponent ?? -1 }
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        XCTAssertLessThan(alpha(x: 0, y: 0), 0.01)
        // AppIcon's left, apex and right hollow nodes, with y flipped for bitmap rows.
        for (x, y) in [(24, 99), (72, 36), (120, 99)] {
            XCTAssertLessThan(alpha(x: x, y: y), 0.05)
            XCTAssertGreaterThan(alpha(x: x + 10, y: y), 0.8)
        }
        if let output = ProcessInfo.processInfo.environment["CBM_RENDER_OUTPUT"] {
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("menu-mark.png"))
        }
    }
}
