// Draws AppIcon.icns. Run from the repo root: swift Resources/icon.swift
import AppKit

let black = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.06, alpha: 1)
let teal = NSColor(srgbRed: 0x25 / 255.0, green: 0x6f / 255.0, blue: 0x82 / 255.0, alpha: 1)
let putty = NSColor(srgbRed: 0xde / 255.0, green: 0xda / 255.0, blue: 0xd3 / 255.0, alpha: 1)

/// Laid out on Apple's 1024 grid: an 824 square body with the screen inside it.
func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x * s, y: (1024 - y - h) * s, width: w * s, height: h * s)   // y measured from the top
    }

    black.setFill()
    NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s).fill()

    let (x, y, w, h) = (CGFloat(172), CGFloat(270), CGFloat(680), CGFloat(484))
    func p(_ px: CGFloat, _ py: CGFloat) -> NSPoint { NSPoint(x: px * s, y: (1024 - py) * s) }
    teal.setFill()
    NSBezierPath(roundedRect: r(x, y, w, h), xRadius: 40 * s, yRadius: 40 * s).fill()

    // The seek bar along the bottom of the screen, a bit under half played.
    let bar = r(x + 56, y + h - 76, w - 112, 22)
    putty.withAlphaComponent(0.35).setFill()
    NSBezierPath(roundedRect: bar, xRadius: 11 * s, yRadius: 11 * s).fill()
    putty.setFill()
    NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: bar.width * 0.42, height: bar.height),
                 xRadius: 11 * s, yRadius: 11 * s).fill()

    // Play mark, nudged right of centre so it looks centred.
    let cx = x + w / 2 + 16, cy = y + h / 2 - 34, half: CGFloat = 104
    let play = NSBezierPath()
    play.move(to: p(cx - half * 0.86, cy - half))
    play.line(to: p(cx + half, cy))
    play.line(to: p(cx - half * 0.86, cy + half))
    play.close()
    play.lineJoinStyle = .round
    play.lineWidth = 28 * s
    putty.setFill()
    putty.setStroke()
    play.fill()
    play.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
// Only the sizes that differ. macOS scales the 512 up for the rare 1024 case,
// and a flat icon survives that; the full set would triple the file.
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256@2x", 512)] {
    try! draw(px).write(to: set.appendingPathComponent("icon_\(name).png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! task.run()
task.waitUntilExit()
