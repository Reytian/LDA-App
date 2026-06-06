//
//  CounselTheme.swift
//  LDAUI
//
//  The "Counsel" visual direction: paper-forward, restrained, and professional.
//  A single ink-blue accent is reserved for primary actions, focus, and
//  selection; it is never used as an entity color. Each entity type has its own
//  low-chroma hue used only as a highlight underline and a sidebar dot.
//
//  Every color is appearance-adaptive: it carries a light and a dark variant and
//  resolves against the effective NSAppearance, so the whole app honors light,
//  dark, and system-following modes consistently.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import LDACore

/// The Counsel palette. Colors resolve per appearance (light or dark).
public enum CounselTheme {

    // MARK: - Brand and surfaces

    /// The single ink-blue accent. Primary actions, focus, and selection only.
    public static let inkAccent = dynamic(light: 0x3A4FA0, dark: 0x6E82DA)

    /// The document pane surface (warm paper).
    public static let paper = dynamic(light: 0xFCFBF9, dark: 0x242529)

    /// The recessed app chrome surface.
    public static let appSurface = dynamic(light: 0xF4F5F7, dark: 0x1B1C1F)

    /// A raised surface (cards, popovers, chips).
    public static let raised = dynamic(light: 0xFFFFFF, dark: 0x2E2F33)

    // MARK: - Text and lines

    /// Primary text.
    public static let textPrimary = dynamic(light: 0x2B2E33, dark: 0xE9EAED)

    /// Secondary text.
    public static let textSecondary = dynamic(light: 0x71757C, dark: 0x9CA1A9)

    /// The hairline border used in place of shadows.
    public static let hairline = dynamic(light: 0xE2E4E8, dark: 0x3A3C41)

    /// A muted rose used for errors and warnings (for example an invalid regex).
    public static let danger = dynamic(light: 0xB05F5C, dark: 0xD98B88)

    // MARK: - Entity colors

    /// The hue for an entity type, used as a highlight underline and a sidebar
    /// dot. Dark variants are lifted for legibility on a dark surface.
    public static func color(for type: EntityType) -> Color {
        switch type {
        case .person:
            return dynamic(light: 0x4F62B0, dark: 0x8B9BE6)
        case .company:
            return dynamic(light: 0x3E8497, dark: 0x6FBDD0)
        case .address:
            return dynamic(light: 0x4E8C68, dark: 0x86C9A1)
        case .email:
            return dynamic(light: 0x3F84B5, dark: 0x77B6E0)
        case .nationalID, .uscc, .bankAccount:
            return dynamic(light: 0xA07A2E, dark: 0xD9B968)
        case .amount:
            return dynamic(light: 0x9A5499, dark: 0xD18FCF)
        case .phone:
            return dynamic(light: 0xB05F5C, dark: 0xE09A97)
        case .date, .unknown:
            return dynamic(light: 0x8A8175, dark: 0xBFB6A6)
        }
    }

    // MARK: - Dynamic color builder

    /// Build an appearance-adaptive SwiftUI color from a light and a dark sRGB
    /// literal. The underlying NSColor resolves itself against the drawing
    /// context's appearance, so it follows light, dark, and system modes.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(srgb: isDark ? dark : light)
        })
    }
}

// MARK: - NSColor hex helper

private extension NSColor {
    /// Builds an sRGB NSColor from a 24-bit 0xRRGGBB literal.
    convenience init(srgb hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
