//
//  CounselTheme.swift
//  LDAUI
//
//  The "Counsel" visual direction: paper-forward, restrained, and professional.
//  A single ink-blue accent is reserved for primary actions, focus, and
//  selection; it is never used as an entity color. Each entity type has its own
//  hue used as the highlight underline, the Safe Preview token fill, the legend
//  dot, and the sidebar dot.
//
//  Every color is appearance-adaptive: it carries a light and a dark variant and
//  resolves against the effective NSAppearance, so the whole app honors light,
//  dark, and system-following modes consistently.
//
//  The entity palette is pinned by CounselThemeContrastTests: every hue clears
//  WCAG contrast floors on paper and on the app surface in both appearances,
//  no two types share a hex, and no entity hue borrows the accent or danger
//  colors. Change a literal here and that suite decides whether it ships.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import LDACore

/// The Counsel palette. Colors resolve per appearance (light or dark).
public enum CounselTheme {

    /// A light and a dark sRGB 0xRRGGBB literal for one appearance-adaptive
    /// color. Exposed so the contrast tests measure the exact values the
    /// dynamic colors resolve to.
    struct HexPair: Equatable {
        let light: UInt32
        let dark: UInt32
    }

    // MARK: - Brand and surfaces

    static let inkAccentHex = HexPair(light: 0x3A4FA0, dark: 0x6E82DA)
    static let inkAccentFillHex = HexPair(light: 0x3A4FA0, dark: 0x4A5DB8)
    static let paperHex = HexPair(light: 0xFCFBF9, dark: 0x242529)
    static let appSurfaceHex = HexPair(light: 0xF4F5F7, dark: 0x1B1C1F)
    static let raisedHex = HexPair(light: 0xFFFFFF, dark: 0x2E2F33)
    static let textPrimaryHex = HexPair(light: 0x2B2E33, dark: 0xE9EAED)
    static let textSecondaryHex = HexPair(light: 0x5F636B, dark: 0x9CA1A9)
    static let hairlineHex = HexPair(light: 0xE2E4E8, dark: 0x3A3C41)
    static let dangerHex = HexPair(light: 0xB05F5C, dark: 0xD98B88)

    /// The single ink-blue accent for focus, selection, dots, and small marks.
    public static let inkAccent = dynamic(inkAccentHex)

    /// The fill for prominent buttons, where WHITE text sits on top. The dark
    /// variant is darker than inkAccent so white-on-fill clears WCAG AA 4.5:1
    /// (inkAccent's dark 0x6E82DA only reached 3.58:1).
    public static let inkAccentFill = dynamic(inkAccentFillHex)

    /// The document pane surface (warm paper).
    public static let paper = dynamic(paperHex)

    /// The recessed app chrome surface.
    public static let appSurface = dynamic(appSurfaceHex)

    /// A raised surface (cards, popovers, chips).
    public static let raised = dynamic(raisedHex)

    // MARK: - Text and lines

    /// Primary text.
    public static let textPrimary = dynamic(textPrimaryHex)

    /// Secondary text. Light variant darkened from 0x71757C (which only reached
    /// 4.24:1 on the sidebar surface) to clear WCAG AA on appSurface and paper.
    public static let textSecondary = dynamic(textSecondaryHex)

    /// The hairline border used in place of shadows.
    public static let hairline = dynamic(hairlineHex)

    /// A muted rose used for errors and warnings (for example an invalid regex).
    public static let danger = dynamic(dangerHex)

    /// The primary text as an NSColor, for AppKit-rendered document text.
    static let textPrimaryNSColor = dynamicNSColor(textPrimaryHex)

    // MARK: - Entity colors

    /// The light and dark literals behind an entity hue. Two lightness tiers
    /// (mid and deep) keep red-green confusable types apart: PERSON and
    /// COMPANY, the two most frequent kinds, sit on opposite sides of the
    /// blue-yellow axis, and the digit-heavy kinds (DATE, AMOUNT, NATIONAL_ID,
    /// PHONE, CASE_NUMBER) take every quadrant so a reviewer who confuses them
    /// by content is not also confusing them by color. DATE stays a quiet warm
    /// neutral because it is the most frequent, lowest-risk kind and should
    /// not shout. See the scan-phase design spec for the measured contrast
    /// and CIEDE2000 tables.
    static func entityHex(for type: EntityType) -> HexPair {
        switch type {
        case .person:       return HexPair(light: 0x9E4A78, dark: 0xDB8AB2) // plum
        case .company:      return HexPair(light: 0x7A4A1E, dark: 0xE8B084) // sepia
        case .address:      return HexPair(light: 0x3D7F4A, dark: 0x68AC7A) // green
        case .email:        return HexPair(light: 0x14665A, dark: 0x8FD3C6) // deep teal
        case .phone:        return HexPair(light: 0x6B5EB5, dark: 0xA897ED) // violet
        case .bankAccount:  return HexPair(light: 0x585618, dark: 0xCFC98A) // olive
        case .nationalID:   return HexPair(light: 0x227C92, dark: 0x66ADC2) // petrol
        case .uscc:         return HexPair(light: 0x5C7A1F, dark: 0x92AD58) // moss
        case .date:         return HexPair(light: 0x7A6F67, dark: 0xACA199) // warm taupe
        case .amount:       return HexPair(light: 0x846F1E, dark: 0xBAA157) // gold
        case .caseNumber:   return HexPair(light: 0x34486A, dark: 0xB0BBD2) // slate
        case .licensePlate: return HexPair(light: 0x7E2A4B, dark: 0xE9A3B8) // wine
        case .wechatID:     return HexPair(light: 0x267A57, dark: 0x60B38C) // sea green
        case .url:          return HexPair(light: 0x2A66A6, dark: 0x7BA5E5) // cerulean
        case .seal:         return HexPair(light: 0xB0402C, dark: 0xE8907A) // vermilion
        case .unknown:      return HexPair(light: 0x505050, dark: 0xC6C6C6) // neutral
        }
    }

    /// The hue for an entity type, used as the highlight underline, the Safe
    /// Preview token fill, the legend dot, and the sidebar dot.
    public static func color(for type: EntityType) -> Color {
        Color(nsColor: entityNSColor(for: type))
    }

    /// The entity hue as an appearance-adaptive NSColor, for AppKit-rendered
    /// document text (underlines, fills, and tooltips in the text view).
    static func entityNSColor(for type: EntityType, alpha: CGFloat = 1.0) -> NSColor {
        dynamicNSColor(entityHex(for: type), alpha: alpha)
    }

    // MARK: - Spacing and radius tokens

    /// The 4pt-based spacing scale. Chrome uses xs...lg; the document pane uses
    /// the larger editorial rhythm directly.
    public enum Space {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
    }

    /// Scalable semantic roles for readable copy. Metadata stays compact while
    /// instructions and explanatory prose use the system reading size.
    public enum Typography {
        public static let pageTitle = Font.system(.title, design: .serif).weight(.semibold)
        public static let sectionTitle = Font.title3.weight(.semibold)
        public static let readingBody = Font.body
        public static let supporting = Font.callout
        public static let metadata = Font.caption
    }

    /// Corner radii.
    public enum Radius {
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 18
    }

    // MARK: - Dynamic color builders

    /// Build an appearance-adaptive SwiftUI color from a light and a dark sRGB
    /// literal. The underlying NSColor resolves itself against the drawing
    /// context's appearance, so it follows light, dark, and system modes.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        dynamic(HexPair(light: light, dark: dark))
    }

    static func dynamic(_ pair: HexPair) -> Color {
        Color(nsColor: dynamicNSColor(pair))
    }

    /// Build an appearance-adaptive NSColor. The alpha is applied inside the
    /// provider so a translucent fill stays dynamic instead of freezing to
    /// whichever appearance was current when it was created.
    static func dynamicNSColor(_ pair: HexPair, alpha: CGFloat = 1.0) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(srgb: isDark ? pair.dark : pair.light, alpha: alpha)
        }
    }
}

// MARK: - NSColor hex helper

private extension NSColor {
    /// Builds an sRGB NSColor from a 24-bit 0xRRGGBB literal.
    convenience init(srgb hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}
