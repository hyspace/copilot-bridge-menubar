import AppKit

public enum StatusItemIcon {
    public static func make() -> NSImage? {
        // The original AppIcon mark from scripts/generate-icon.swift, with the
        // blue background removed and node centers cut out for template tinting.
        // Retain its arch, three nodes and five lower dots (not an SF Symbol).
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            let scale: CGFloat = 16 / 580
            context.translateBy(x: 1, y: (18 - 468 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -222, y: -285)
            context.setShouldAntialias(true)

            let left = CGPoint(x: 295, y: 396)
            let top = CGPoint(x: 512, y: 680)
            let right = CGPoint(x: 729, y: 396)
            let bridge = NSBezierPath()
            bridge.move(to: left)
            bridge.curve(to: top, controlPoint1: CGPoint(x: 295, y: 565),
                         controlPoint2: CGPoint(x: 365, y: 680))
            bridge.curve(to: right, controlPoint1: CGPoint(x: 659, y: 680),
                         controlPoint2: CGPoint(x: 729, y: 565))
            bridge.lineWidth = 66
            bridge.lineCapStyle = .round
            NSColor.black.withAlphaComponent(0.96).setStroke()
            bridge.stroke()
            NSColor.black.withAlphaComponent(0.68).setFill()
            for point in [CGPoint(x: 384, y: 335), CGPoint(x: 448, y: 306),
                          CGPoint(x: 512, y: 296), CGPoint(x: 576, y: 306), CGPoint(x: 640, y: 335)] {
                NSBezierPath(ovalIn: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)).fill()
            }
            NSColor.black.setFill()
            for point in [left, top, right] {
                NSBezierPath(ovalIn: CGRect(x: point.x - 73, y: point.y - 73, width: 146, height: 146)).fill()
            }
            context.setBlendMode(.clear)
            for point in [left, top, right] {
                context.fillEllipse(in: CGRect(x: point.x - 30, y: point.y - 30, width: 60, height: 60))
            }
            return true
        }
        image.accessibilityDescription = "Copilot Bridge"
        // AppKit adapts to the actual menu-bar background, not just system theme.
        image.isTemplate = true
        return image
    }
}
