#!/usr/bin/env swift
// Original vector artwork for the app icon: a three-node bridge on a blue tile.
// No SF Symbols font or artwork is embedded in this application icon.
// Usage: swift scripts/generate-icon.swift build/icon
import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/icon", isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func render(_ size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "IconGeneration", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.setShouldAntialias(true)
    context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(size) / 1024)
    scale.concat()

    let bounds = CGRect(x: 64, y: 64, width: 896, height: 896)
    let tile = NSBezierPath(roundedRect: bounds, xRadius: 200, yRadius: 200)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.shadowBlurRadius = 25
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    rgb(0x176BD8).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [rgb(0x0752CB), rgb(0x1389F5), rgb(0x47B6FF)])!
        .draw(in: tile, angle: 80)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let glow = NSBezierPath(ovalIn: CGRect(x: -80, y: 630, width: 1180, height: 560))
    NSColor.white.withAlphaComponent(0.06).setFill()
    glow.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.22).setStroke()
    let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 198, yRadius: 198)
    border.lineWidth = 3
    border.stroke()

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
    NSColor.white.withAlphaComponent(0.96).setStroke()
    bridge.stroke()
    for point in [CGPoint(x: 384, y: 335), CGPoint(x: 448, y: 306),
                  CGPoint(x: 512, y: 296), CGPoint(x: 576, y: 306), CGPoint(x: 640, y: 335)] {
        NSColor.white.withAlphaComponent(0.68).setFill()
        NSBezierPath(ovalIn: CGRect(x: point.x - 11, y: point.y - 11, width: 22, height: 22)).fill()
    }
    for (index, point) in [left, top, right].enumerated() {
        NSColor.white.setFill()
        NSBezierPath(ovalIn: CGRect(x: point.x - 73, y: point.y - 73, width: 146, height: 146)).fill()
        rgb(index == 1 ? 0x1687E8 : 0x1269DC).setFill()
        NSBezierPath(ovalIn: CGRect(x: point.x - 30, y: point.y - 30, width: 60, height: 60)).fill()
    }
    context.cgContext.flush()
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGeneration", code: 2)
    }
    return png
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(size * scale).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
try render(1024).write(to: output.appendingPathComponent("AppIcon.png"))
let command = Process()
command.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
command.arguments = ["--convert", "icns", "--output", output.appendingPathComponent("AppIcon.icns").path, iconset.path]
try command.run()
command.waitUntilExit()
guard command.terminationStatus == 0 else {
    fputs("iconutil failed. Check its diagnostics and run the generator with normal macOS tool permissions.\n", stderr)
    exit(command.terminationStatus)
}
print(output.appendingPathComponent("AppIcon.icns").path)
