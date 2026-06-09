// Generates the LDA app icon: an ink-blue rounded-square with a white document
// whose lines include solid redaction bars, the universal "redacted document"
// motif, in the Counsel palette. Renders every iconset size and builds AppIcon.icns.
//
// Usage: swift packaging/make_icon.swift   (run from the package dir)
// House rules: English only. No em-dash or en-dash-as-separator.

import AppKit
import Foundation

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0, alpha: 1.0)
}

func roundedRect(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

func drawIcon(size S: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: S, height: S)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.interpolationQuality = .high

    // Background squircle with an ink-blue gradient.
    let margin = S * 0.075
    let bgRect = NSRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let bg = roundedRect(bgRect, bgRect.width * 0.225)
    let grad = NSGradient(colors: [color(0x5A6BCC), color(0x2C3B7A)])!
    grad.draw(in: bg, angle: -90)

    // White document sheet, centered, slightly portrait.
    let sheetW = S * 0.48
    let sheetH = S * 0.60
    let sheetRect = NSRect(x: (S - sheetW) / 2, y: (S - sheetH) / 2, width: sheetW, height: sheetH)
    let sheet = roundedRect(sheetRect, S * 0.028)
    color(0xFCFBF9).setFill()
    sheet.fill()

    // Text lines and redaction bars.
    let pad = sheetW * 0.16
    let lineX = sheetRect.minX + pad
    let fullW = sheetW - 2 * pad
    let lineH = sheetH * 0.062
    let gap = sheetH * 0.085
    // From the top of the sheet downward. Each entry: (relativeWidth, isRedaction).
    let lines: [(CGFloat, Bool)] = [
        (1.0, false),
        (1.0, true),   // redaction bar
        (0.82, false),
        (0.7, true),   // redaction bar
        (0.55, false),
    ]
    var y = sheetRect.maxY - sheetH * 0.20
    let light = color(0xC7CCD3)
    let ink = color(0x23262B)
    for (w, isRedaction) in lines {
        let barW = fullW * w
        let r = NSRect(x: lineX, y: y - lineH, width: barW, height: lineH)
        (isRedaction ? ink : light).setFill()
        roundedRect(r, lineH / 2).fill()
        y -= (lineH + gap)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// Build the iconset.
let fm = FileManager.default
let iconset = "packaging/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let entries: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in entries {
    let rep = drawIcon(size: size)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
print("iconset written to \(iconset)")
