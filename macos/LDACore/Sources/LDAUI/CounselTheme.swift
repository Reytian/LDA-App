//
//  CounselTheme.swift
//  LDAUI
//
//  The "Counsel" visual direction: light, paper-forward, restrained, and
//  professional. A single ink-blue accent is reserved for primary actions,
//  focus, and selection; it is never used as an entity color. Each entity type
//  has its own low-chroma hue used only as a highlight underline and a sidebar
//  dot, never as a saturated fill.
//
//  Surfaces favor hairlines over shadows. The document body uses a serif; chrome
//  uses the default SF Pro; tokens use a monospaced face.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

/// The Counsel palette and color resolver. All colors are defined as sRGB
/// literals so the look is stable regardless of the system accent or theme.
public enum CounselTheme {

    // MARK: - Brand and surfaces

    /// The single ink-blue accent. Primary actions, focus, and selection only;
    /// never an entity color.
    public static let inkAccent = Color(hex: 0x3A4FA0)

    /// The document pane surface (paper).
    public static let paper = Color(hex: 0xFCFBF9)

    /// The app chrome surface.
    public static let appSurface = Color(hex: 0xF4F5F7)

    /// A raised surface (cards, popovers, chips).
    public static let raised = Color(hex: 0xFFFFFF)

    // MARK: - Text and lines

    /// Primary text.
    public static let textPrimary = Color(hex: 0x2B2E33)

    /// Secondary text.
    public static let textSecondary = Color(hex: 0x71757C)

    /// The hairline border used in place of shadows.
    public static let hairline = Color(hex: 0xE2E4E8)

    // MARK: - Entity colors

    /// The low-chroma hue for an entity type. Used as a highlight underline and
    /// a sidebar dot, never as a saturated fill. The ink accent is intentionally
    /// excluded so accent and entity semantics never collide.
    public static func color(for type: EntityType) -> Color {
        switch type {
        case .person:
            return Color(hex: 0x4F62B0)
        case .company:
            return Color(hex: 0x3E8497)
        case .address:
            return Color(hex: 0x4E8C68)
        case .email:
            return Color(hex: 0x3F84B5)
        case .nationalID, .uscc, .bankAccount:
            return Color(hex: 0xA07A2E)
        case .amount:
            return Color(hex: 0x9A5499)
        case .phone:
            return Color(hex: 0xB05F5C)
        case .date, .unknown:
            return Color(hex: 0x8A8175)
        }
    }
}

// MARK: - Color hex helper

private extension Color {
    /// Builds an sRGB color from a 24-bit 0xRRGGBB literal. sRGB is explicit so
    /// the palette stays stable regardless of the system accent or theme.
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
    }
}
