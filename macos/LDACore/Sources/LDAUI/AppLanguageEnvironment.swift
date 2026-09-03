//
//  AppLanguageEnvironment.swift
//  LDAUI
//
//  The interface-language override lives in the SwiftUI environment, not in
//  Bundle.main and the system locale.
//
//  Text("x"), Button("x"), Label("x", systemImage:), .help("x"), a literal
//  passed to a LocalizedStringKey-typed parameter, and Text(LocalizedStringKey(s))
//  all resolve against Bundle.main and the SYSTEM locale. The catalogs live in
//  LDACore_LDAUI.bundle behind this app's OWN in-app override, so every one of
//  those forms misses the resource bundle and falls back to the English key.
//  .environment(\.locale, appLocale) sets a Locale and never a bundle, so it
//  cannot help either.
//
//  L10n.text and L10n.button read \.appLanguage from the environment instead,
//  so a screen written against this idiom resolves correctly in the language
//  the user picked, in the SwiftPM dev binary exactly as in the packaged app,
//  and updates the instant the picker changes with no @AppStorage seam of its
//  own.
//
//  L10n.text("Choose a detection model") is four characters longer than
//  Text("..."). That is deliberate: the correct idiom must be nearly as cheap
//  to type as the broken one, or the lint becomes an argument instead of a
//  habit.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI

private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue = AppLanguage.system
}

extension EnvironmentValues {
    /// The interface language every LDAUI view renders in. Set once per scene
    /// in LDAApp, next to `.environment(\.locale, appLocale)`, from the same
    /// `@AppStorage(AppLanguage.storageKey)` value.
    public var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}

extension L10n {
    /// Resolves `key` against `language` and formats it with `arguments` when
    /// there are any. The one place `L10n.text` and `L10n.button` turn a key
    /// into the string they render.
    static func formatted(
        _ key: String,
        language: AppLanguage?,
        _ arguments: [CVarArg]
    ) -> String {
        let resolved = L10n.string(key, language: language)
        guard !arguments.isEmpty else { return resolved }
        return String(
            format: resolved,
            locale: (language ?? .system).locale,
            arguments: arguments
        )
    }

    /// The ONLY way this package renders plain copy. Reads `\.appLanguage`
    /// from the environment inside its own `body`, so it needs no `@AppStorage`
    /// seam of its own to update when the language changes.
    static func text(_ key: String, _ arguments: CVarArg...) -> some View {
        L10nTextView(key: key, arguments: arguments)
    }

    /// The button counterpart of `L10n.text`.
    static func button(
        _ key: String,
        _ arguments: CVarArg...,
        action: @escaping () -> Void
    ) -> some View {
        L10nButtonView(key: key, arguments: arguments, action: action)
    }
}

private struct L10nTextView: View {
    @Environment(\.appLanguage) private var language
    let key: String
    let arguments: [CVarArg]

    var body: some View {
        Text(verbatim: L10n.formatted(key, language: language, arguments))
    }
}

private struct L10nButtonView: View {
    @Environment(\.appLanguage) private var language
    let key: String
    let arguments: [CVarArg]
    let action: () -> Void

    var body: some View {
        // The StringProtocol overload of Button, never the LocalizedStringKey
        // one: the string handed in is already resolved, so it must render
        // verbatim rather than being looked up a second time against
        // Bundle.main.
        Button(L10n.formatted(key, language: language, arguments)) { action() }
    }
}

private struct L10nHelpModifier: ViewModifier {
    @Environment(\.appLanguage) private var language
    let key: String

    func body(content: Content) -> some View {
        content.help(Text(verbatim: L10n.string(key, language: language)))
    }
}

extension View {
    /// `.help(...)` routed through the environment language, in place of
    /// `.help("literal")`, which resolves against Bundle.main.
    func l10nHelp(_ key: String) -> some View {
        modifier(L10nHelpModifier(key: key))
    }
}
