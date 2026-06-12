// Generates the LDA app icon: an ink-blue rounded-square with a white document
// whose lines include solid redaction bars, the universal "redacted document"
// motif, in the Counsel palette. Renders every iconset size and builds AppIcon.icns.
//
// Usage: swift packaging/make_icon.swift   (run from the package dir)
// House rules: English only. No em-dash or en-dash-as-separator.

import AppKit
import Foundation

func color(_ hex: UInt32, _ a: CGFloat = 1.0) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0, alpha: a)
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

    let m = S * 0.075
    let bgRect = NSRect(x: m, y: m, width: S - 2 * m, height: S - 2 * m)
    let squircle = roundedRect(bgRect, bgRect.width * 0.225)

    // Background: lit and layered, clipped to the squircle.
    ctx.saveGState()
    squircle.addClip()
    NSGradient(colors: [color(0x44568C), color(0x162446)])!.draw(in: bgRect, angle: -90)
    NSGradient(colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0.0)])!
        .draw(fromCenter: NSPoint(x: S/2, y: S*0.82), radius: 0,
              toCenter: NSPoint(x: S/2, y: S*0.82), radius: S*0.55, options: [])
    NSGradient(colors: [color(0x000010, 0.0), color(0x000010, 0.26)])!
        .draw(fromCenter: NSPoint(x: S/2, y: S/2), radius: S*0.28,
              toCenter: NSPoint(x: S/2, y: S/2), radius: S*0.64, options: [])
    ctx.restoreGState()
    ctx.saveGState()
    squircle.addClip()
    color(0xFFFFFF, 0.18).setStroke()
    let rim = roundedRect(bgRect.insetBy(dx: 1.5, dy: 1.5), bgRect.width * 0.225)
    rim.lineWidth = max(1.5, S * 0.006)
    rim.stroke()
    ctx.restoreGState()

    // Document, a small stack with depth.
    let sw = S * 0.50, sh = S * 0.62
    let sr = NSRect(x: (S - sw)/2, y: (S - sh)/2, width: sw, height: sh)

    let back = roundedRect(NSRect(x: sr.minX - sw*0.05, y: sr.minY - sh*0.035, width: sw, height: sh), S*0.018)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S*0.01), blur: S*0.03, color: color(0x05091A, 0.35).cgColor)
    color(0xD9DAE0).setFill()
    back.fill()
    ctx.restoreGState()

    let fold = sw * 0.22
    let sheet = NSBezierPath()
    sheet.move(to: NSPoint(x: sr.minX, y: sr.minY))
    sheet.line(to: NSPoint(x: sr.minX, y: sr.maxY))
    sheet.line(to: NSPoint(x: sr.maxX - fold, y: sr.maxY))
    sheet.line(to: NSPoint(x: sr.maxX, y: sr.maxY - fold))
    sheet.line(to: NSPoint(x: sr.maxX, y: sr.minY))
    sheet.close()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S*0.018), blur: S*0.05, color: color(0x05091A, 0.40).cgColor)
    sheet.addClip()
    NSGradient(colors: [color(0xFFFFFF), color(0xEFEEEA)])!.draw(in: sr, angle: -90)
    ctx.restoreGState()

    ctx.saveGState()
    let foldTri = NSBezierPath()
    foldTri.move(to: NSPoint(x: sr.maxX - fold, y: sr.maxY))
    foldTri.line(to: NSPoint(x: sr.maxX - fold, y: sr.maxY - fold))
    foldTri.line(to: NSPoint(x: sr.maxX, y: sr.maxY - fold))
    foldTri.close()
    foldTri.addClip()
    NSGradient(colors: [color(0xCBCDD3), color(0xE7E7E4)])!
        .draw(in: NSRect(x: sr.maxX - fold, y: sr.maxY - fold, width: fold, height: fold), angle: -45)
    ctx.restoreGState()

    color(0xFFFFFF, 0.7).setStroke()
    let topHi = NSBezierPath()
    topHi.move(to: NSPoint(x: sr.minX + 2, y: sr.maxY - 1.5))
    topHi.line(to: NSPoint(x: sr.maxX - fold, y: sr.maxY - 1.5))
    topHi.lineWidth = max(1, S * 0.004)
    topHi.stroke()

    let pad = sw * 0.16, lx = sr.minX + pad, fw = sw - 2 * pad
    let lh = sh * 0.055, gap = sh * 0.085
    var y = sr.maxY - sh * 0.24
    func light(_ rel: CGFloat) {
        color(0xC4C8D0).setFill()
        roundedRect(NSRect(x: lx, y: y - lh, width: fw * rel, height: lh), lh/2).fill()
        y -= (lh + gap)
    }
    func redaction(_ rel: CGFloat) {
        let bh = lh * 1.9
        let r = NSRect(x: lx, y: y - bh, width: fw * rel, height: bh)
        ctx.saveGState()
        roundedRect(r, bh * 0.28).addClip()
        NSGradient(colors: [color(0x2A2C30), color(0x080809)])!.draw(in: r, angle: -90)
        ctx.restoreGState()
        color(0xFFFFFF, 0.12).setStroke()
        let hi = NSBezierPath()
        hi.move(to: NSPoint(x: r.minX + bh*0.3, y: r.maxY - 1.5))
        hi.line(to: NSPoint(x: r.maxX - bh*0.3, y: r.maxY - 1.5))
        hi.lineWidth = max(1, S * 0.004)
        hi.stroke()
        y -= (bh + gap)
    }
    light(0.9)
    redaction(1.0)
    light(0.85)
    light(0.6)

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
