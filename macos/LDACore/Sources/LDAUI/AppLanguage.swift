//
//  AppLanguage.swift
//  LDAUI
//
//  The persisted interface-language preference shared by every app scene.
//  Stable raw values are locale identifiers and never translated.
//

import Foundation

/// Languages available for the LDA interface.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case french = "fr"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    public var id: String { rawValue }

    public static let storageKey = "com.haotianyi.LDA.appLanguage"

    /// Language names remain recognizable before and after the picker changes.
    ///
    /// `language` is the language THIS NAME renders in, not the language it
    /// names: `.system.nativeName(language: .simplifiedChinese)` is
    /// "跟随系统". Defaults to nil, which resolves against `AppLanguage.selected`
    /// (UserDefaults) for call sites outside a SwiftUI body; a view should
    /// instead pass `\.appLanguage` from the environment, so the label updates
    /// the instant the picker changes rather than lagging one relaunch behind.
    public func nativeName(language: AppLanguage? = nil) -> String {
        switch self {
        case .system: return L10n.string("Follow System", language: language)
        case .english: return "English"
        case .french: return "Français"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        }
    }

    public var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        default: return Locale(identifier: rawValue)
        }
    }

    public static func from(rawValue: String) -> AppLanguage {
        AppLanguage(rawValue: rawValue) ?? .system
    }

    public static func selected(defaults: UserDefaults = .standard) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: storageKey) else { return .system }
        return from(rawValue: rawValue)
    }

    public static func select(
        _ language: AppLanguage,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(language.rawValue, forKey: storageKey)
    }
}
