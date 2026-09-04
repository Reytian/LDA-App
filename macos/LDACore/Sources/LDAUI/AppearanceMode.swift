//
//  AppearanceMode.swift
//  LDAUI
//
//  The user's theme preference: follow the system, or force light or dark. Stored
//  via @AppStorage so the window and Settings stay in sync. Default is System.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI

/// How the app chooses light vs dark.
public enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    /// The UserDefaults / @AppStorage key shared by the app and Settings.
    public static let storageKey = "com.haotianyi.LDA.appearance"

    public var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The SwiftUI color scheme to force, or nil to follow the system.
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Resolve a stored raw value to a mode, defaulting to System.
    public static func from(rawValue: String) -> AppearanceMode {
        AppearanceMode(rawValue: rawValue) ?? .system
    }
}
