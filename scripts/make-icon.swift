// Draws the placeholder app icon (stacked table sheets on a blue squircle) into
// App/Assets.xcassets/AppIcon.appiconset. Run: swift scripts/make-icon.swift
import AppKit

let outDir = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func drawIcon(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024  // design on a 1024 grid

    // macOS icon grid: 824 pt body centred in 1024 with a soft shadow.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.98, alpha: 1),
               ending: NSColor(calibratedRed: 0.08, green: 0.24, blue: 0.62, alpha: 1))!.draw(in: squircle, angle: -90)

    // Three stacked sheets ("laminate" layers), the front one a table.
    func sheet(_ dx: CGFloat, _ dy: CGFloat, alpha: CGFloat) -> NSRect {
        let rect = NSRect(x: (262 + dx) * s, y: (262 + dy) * s, width: 500 * s, height: 420 * s)
        let path = NSBezierPath(roundedRect: rect, xRadius: 36 * s, yRadius: 36 * s)
        NSColor.white.withAlphaComponent(alpha).setFill()
        path.fill()
        return rect
    }
    _ = sheet(56, 112, alpha: 0.35)
    _ = sheet(28, 56, alpha: 0.6)
    let front = sheet(0, 0, alpha: 1)

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: front, xRadius: 36 * s, yRadius: 36 * s).addClip()
    let rows = 5, columns = 3
    let rowHeight = front.height / CGFloat(rows)
    // Header band.
    NSColor(calibratedRed: 0.13, green: 0.40, blue: 0.86, alpha: 1).setFill()
    NSRect(x: front.minX, y: front.maxY - rowHeight, width: front.width, height: rowHeight).fill()
    // Zebra rows.
    NSColor(white: 0.92, alpha: 1).setFill()
    for row in stride(from: 2, to: rows, by: 2) {
        NSRect(x: front.minX, y: front.maxY - CGFloat(row + 1) * rowHeight, width: front.width, height: rowHeight).fill()
    }
    // Column lines.
    NSColor(white: 0.78, alpha: 1).setFill()
    for column in 1..<columns {
        NSRect(x: front.minX + front.width * CGFloat(column) / CGFloat(columns) - 3 * s, y: front.minY,
               width: 6 * s, height: front.height - rowHeight).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        let data = drawIcon(CGFloat(pixels)).representation(using: .png, properties: [:])!
        try data.write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
try #"{"info":{"version":1,"author":"xcode"}}"#.write(
    to: outDir.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(images.count) icon images to \(outDir.path)")
