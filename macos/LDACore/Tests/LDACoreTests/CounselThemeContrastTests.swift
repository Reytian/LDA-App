//
//  CounselThemeContrastTests.swift
//  LDACoreTests
//
//  The entity palette is the only color channel that tells 16 kinds of PII
//  apart on the paper surface, so it is pinned by measurement rather than by
//  eye: every hue must clear WCAG 2.x contrast floors against the paper and
//  the app surface in BOTH appearances, no two types may share a hex, and the
//  dynamic colors must actually resolve to the declared hexes under the light
//  and dark NSAppearance. The old palette had five light-mode failures, one
//  duplicate pair (DATE and UNKNOWN), and PHONE on the danger hex; none of
//  those can come back silently while this file is green.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import XCTest
@testable import LDAUI
import LDACore

final class CounselThemeContrastTests: XCTestCase {

    /// The nine types a reviewer meets in almost every document. They carry
    /// the text-grade floor (4.5:1); the rare types carry the graphics floor.
    private static let commonTypes: [EntityType] = [
        .person, .company, .address, .email, .phone,
        .nationalID, .amount, .date, .caseNumber
    ]

    private static let textFloor: Double = 4.5
    private static let graphicsFloor: Double = 3.0

    // MARK: - Contrast floors

    func testEveryEntityHueClearsItsContrastFloorOnPaperInBothAppearances() {
        for type in EntityType.allCases {
            let hue = CounselTheme.entityHex(for: type)
            let floor = Self.commonTypes.contains(type) ? Self.textFloor : Self.graphicsFloor

            let light = WCAGContrast.ratio(hue.light, CounselTheme.paperHex.light)
            let dark = WCAGContrast.ratio(hue.dark, CounselTheme.paperHex.dark)

            XCTAssertGreaterThanOrEqual(
                light, floor,
                "\(type.rawValue) light hue reaches only \(light):1 on paper"
            )
            XCTAssertGreaterThanOrEqual(
                dark, floor,
                "\(type.rawValue) dark hue reaches only \(dark):1 on paper"
            )
        }
    }

    func testEveryEntityHueClearsTheGraphicsFloorOnTheAppSurface() {
        for type in EntityType.allCases {
            let hue = CounselTheme.entityHex(for: type)
            let light = WCAGContrast.ratio(hue.light, CounselTheme.appSurfaceHex.light)
            let dark = WCAGContrast.ratio(hue.dark, CounselTheme.appSurfaceHex.dark)

            XCTAssertGreaterThanOrEqual(
                light, Self.graphicsFloor,
                "\(type.rawValue) light dot reaches only \(light):1 on the app surface"
            )
            XCTAssertGreaterThanOrEqual(
                dark, Self.graphicsFloor,
                "\(type.rawValue) dark dot reaches only \(dark):1 on the app surface"
            )
        }
    }

    func testBodyTextStaysLegibleOverTheAcceptedFillInBothAppearances() {
        // The accepted highlight composites the hue at 0.18 over paper; the
        // primary text on top of it must stay well above AA (the design table
        // reports 8.3:1 or better for every type).
        for type in EntityType.allCases {
            let hue = CounselTheme.entityHex(for: type)
            let lightFill = WCAGContrast.composite(
                hue.light, over: CounselTheme.paperHex.light, alpha: 0.18
            )
            let darkFill = WCAGContrast.composite(
                hue.dark, over: CounselTheme.paperHex.dark, alpha: 0.18
            )
            XCTAssertGreaterThanOrEqual(
                WCAGContrast.ratio(CounselTheme.textPrimaryHex.light, lightFill), 7.0,
                "\(type.rawValue): light body text over the accepted fill"
            )
            XCTAssertGreaterThanOrEqual(
                WCAGContrast.ratio(CounselTheme.textPrimaryHex.dark, darkFill), 7.0,
                "\(type.rawValue): dark body text over the accepted fill"
            )
        }
    }

    // MARK: - Distinctness and reserved roles

    func testNoTwoEntityTypesShareAHexInEitherAppearance() {
        var seenLight: [UInt32: EntityType] = [:]
        var seenDark: [UInt32: EntityType] = [:]
        for type in EntityType.allCases {
            let hue = CounselTheme.entityHex(for: type)
            if let other = seenLight[hue.light] {
                XCTFail("\(type.rawValue) and \(other.rawValue) share the light hex")
            }
            if let other = seenDark[hue.dark] {
                XCTFail("\(type.rawValue) and \(other.rawValue) share the dark hex")
            }
            seenLight[hue.light] = type
            seenDark[hue.dark] = type
        }
    }

    func testNoEntityHueBorrowsAReservedChromeColor() {
        for type in EntityType.allCases {
            let hue = CounselTheme.entityHex(for: type)
            XCTAssertNotEqual(hue, CounselTheme.dangerHex, "\(type.rawValue) reuses the danger rose")
            XCTAssertNotEqual(hue, CounselTheme.inkAccentHex, "\(type.rawValue) reuses the ink accent")
        }
    }

    // MARK: - Appearance resolution

    func testEntityColorsResolveToTheDeclaredHexUnderEachAppearance() throws {
        for type in EntityType.allCases {
            let hue = CounselTheme.entityHex(for: type)
            let color = CounselTheme.entityNSColor(for: type)

            let light = try Self.resolve(color, in: .aqua)
            let dark = try Self.resolve(color, in: .darkAqua)

            XCTAssertEqual(Self.hex(of: light), hue.light, "\(type.rawValue) light resolution")
            XCTAssertEqual(Self.hex(of: dark), hue.dark, "\(type.rawValue) dark resolution")
        }
    }

    func testSurfaceColorsResolveToTheDeclaredHexUnderEachAppearance() throws {
        let paper = CounselTheme.dynamicNSColor(CounselTheme.paperHex)
        XCTAssertEqual(Self.hex(of: try Self.resolve(paper, in: .aqua)), CounselTheme.paperHex.light)
        XCTAssertEqual(Self.hex(of: try Self.resolve(paper, in: .darkAqua)), CounselTheme.paperHex.dark)
    }

    // MARK: - Helpers

    /// Resolve a dynamic NSColor to sRGB under a named appearance.
    private static func resolve(_ color: NSColor, in name: NSAppearance.Name) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolved, "\(name.rawValue) could not resolve the color to sRGB")
    }

    /// Pack an sRGB NSColor back into a 0xRRGGBB literal (rounded).
    private static func hex(of color: NSColor) -> UInt32 {
        let red = UInt32((color.redComponent * 255).rounded())
        let green = UInt32((color.greenComponent * 255).rounded())
        let blue = UInt32((color.blueComponent * 255).rounded())
        return (red << 16) | (green << 8) | blue
    }
}

// MARK: - WCAG math

/// WCAG 2.x relative luminance and contrast on sRGB 0xRRGGBB literals.
enum WCAGContrast {
    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        let (lighter, darker) = la >= lb ? (la, lb) : (lb, la)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Alpha-composite `top` at `alpha` over an opaque `base`, in sRGB space,
    /// which is what CoreGraphics does for a translucent fill on paper.
    static func composite(_ top: UInt32, over base: UInt32, alpha: Double) -> UInt32 {
        func blend(_ shift: UInt32) -> UInt32 {
            let t = Double((top >> shift) & 0xFF)
            let b = Double((base >> shift) & 0xFF)
            return UInt32((t * alpha + b * (1 - alpha)).rounded()) & 0xFF
        }
        return (blend(16) << 16) | (blend(8) << 8) | blend(0)
    }

    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255.0
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}
