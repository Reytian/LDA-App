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

// MARK: - The remaining localizing positions
//
// L10n.text, L10n.button and .l10nHelp covered three of the twelve forms that
// reach a localizing position. Label, TextField, SecureField, Toggle, Picker,
// a Button carrying a role, and the alert / confirmationDialog /
// navigationTitle / accessibilityLabel modifiers had no sanctioned route at
// all, so every one of those sites had to stay a raw literal and render in the
// system language rather than the picked one.
//
// Each wrapper below resolves the key first and then hands the finished String
// to SwiftUI's StringProtocol overload, never the LocalizedStringKey one. That
// distinction is the whole point: the LocalizedStringKey overload would look
// the resolved text up a SECOND time against Bundle.main and, on a miss, render
// the already-translated string as its own key.

extension L10n {
    /// `Label("x", systemImage:)` routed through the environment language.
    static func label(_ key: String, systemImage: String) -> some View {
        L10nLabelView(key: key, systemImage: systemImage)
    }

    /// `Button("x", role:)`. The roleless overload above stays the common case;
    /// this one exists because `role` changes the rendering (destructive red,
    /// cancel bolding) and cannot be dropped to reuse it.
    static func button(
        _ key: String,
        role: ButtonRole?,
        action: @escaping () -> Void
    ) -> some View {
        L10nRoleButtonView(key: key, role: role, action: action)
    }

    /// `TextField("prompt", text:)`, where the key is the placeholder prompt.
    static func textField(_ key: String, text: Binding<String>) -> some View {
        L10nTextFieldView(key: key, text: text)
    }

    /// The passphrase counterpart of `L10n.textField`.
    static func secureField(_ key: String, text: Binding<String>) -> some View {
        L10nSecureFieldView(key: key, text: text)
    }

    static func toggle(_ key: String, isOn: Binding<Bool>) -> some View {
        L10nToggleView(key: key, isOn: isOn)
    }

    static func picker<Selection: Hashable, Content: View>(
        _ key: String,
        selection: Binding<Selection>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        L10nPickerView(key: key, selection: selection, content: content)
    }
}

private struct L10nLabelView: View {
    @Environment(\.appLanguage) private var language
    let key: String
    let systemImage: String

    var body: some View {
        Label(L10n.string(key, language: language), systemImage: systemImage)
    }
}

private struct L10nRoleButtonView: View {
    @Environment(\.appLanguage) private var language
    let key: String
    let role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(L10n.string(key, language: language), role: role) { action() }
    }
}

private struct L10nTextFieldView: View {
    @Environment(\.appLanguage) private var language
    let key: String
    let text: Binding<String>

    var body: some View {
        TextField(L10n.string(key, language: language), text: text)
    }
}

private struct L10nSecureFieldView: View {
    @Environment(\.appLanguage) private var language
    let key: String
    let text: Binding<String>

    var body: some View {
        SecureField(L10n.string(key, language: language), text: text)
    }
}

private struct L10nToggleView: View {
    @Environment(\.appLanguage) private var language
    let key: String
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(L10n.string(key, language: language), isOn: isOn)
    }
}

private struct L10nPickerView<Selection: Hashable, Content: View>: View {
    @Environment(\.appLanguage) private var language
    let key: String
    let selection: Binding<Selection>
    @ViewBuilder let content: () -> Content

    var body: some View {
        Picker(L10n.string(key, language: language), selection: selection) {
            content()
        }
    }
}
