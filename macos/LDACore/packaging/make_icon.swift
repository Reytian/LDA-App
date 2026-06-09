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
    NSGradient(colors: [color(0x5A6BCC), color(0x2C3B7A)])!.draw(in: roundedRect(bgRect, bgRect.width * 0.225), angle: -90)

    // The redacted document: a white sheet with a folded top-right corner, a soft
    // drop shadow for depth, and one bold black redaction bar where a name was.
    let sheetW = S * 0.50
    let sheetH = S * 0.62
    let sr = NSRect(x: (S - sheetW) / 2, y: (S - sheetH) / 2, width: sheetW, height: sheetH)
    let fold = sheetW * 0.22

    let sheetPath = NSBezierPath()
    sheetPath.move(to: NSPoint(x: sr.minX, y: sr.minY))
    sheetPath.line(to: NSPoint(x: sr.minX, y: sr.maxY))
    sheetPath.line(to: NSPoint(x: sr.maxX - fold, y: sr.maxY))
    sheetPath.line(to: NSPoint(x: sr.maxX, y: sr.maxY - fold))
    sheetPath.line(to: NSPoint(x: sr.maxX, y: sr.minY))
    sheetPath.close()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.03,
                  color: color(0x101830).withAlphaComponent(0.30).cgColor)
    color(0xFCFBF9).setFill()
    sheetPath.fill()
    ctx.restoreGState()

    // The folded corner (a darker triangle).
    color(0xE2E4E8).setFill()
    let fp = NSBezierPath()
    fp.move(to: NSPoint(x: sr.maxX - fold, y: sr.maxY))
    fp.line(to: NSPoint(x: sr.maxX - fold, y: sr.maxY - fold))
    fp.line(to: NSPoint(x: sr.maxX, y: sr.maxY - fold))
    fp.close()
    fp.fill()

    // Text lines, with one bold black redaction bar as the focal element.
    let pad = sheetW * 0.16
    let lineX = sr.minX + pad
    let fullW = sheetW - 2 * pad
    let lineH = sheetH * 0.055
    let gap = sheetH * 0.085
    let light = color(0xC7CCD3)
    let ink = color(0x141414)
    var y = sr.maxY - sheetH * 0.24
    func bar(_ rel: CGFloat, _ c: NSColor, _ hMul: CGFloat = 1) {
        let bh = lineH * hMul
        c.setFill()
        roundedRect(NSRect(x: lineX, y: y - bh, width: fullW * rel, height: bh), bh / 2).fill()
        y -= (bh + gap)
    }
    bar(0.9, light)
    bar(1.0, ink, 1.9)   // the redaction bar
    bar(0.85, light)
    bar(0.6, light)

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
