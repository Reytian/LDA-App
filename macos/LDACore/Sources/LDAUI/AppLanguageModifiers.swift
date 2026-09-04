//
//  AppLanguageModifiers.swift
//  LDAUI
//
//  The modifier half of the idiom introduced in AppLanguageEnvironment.swift.
//
//  .alert("x", ...), .confirmationDialog("x", ...), .navigationTitle("x") and
//  .accessibilityLabel("x") all take their title as a LocalizedStringKey when
//  handed a literal, which resolves against Bundle.main and the SYSTEM locale
//  and so never sees this app's in-app language override. Each wrapper here
//  resolves the key against \.appLanguage first and passes the finished String
//  to SwiftUI's StringProtocol overload, which renders verbatim.
//
//  These are modifiers rather than static factories because the position they
//  fix is a modifier position: there is no view to construct, only a title to
//  attach to one that already exists.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI

private struct L10nNavigationTitleModifier: ViewModifier {
    @Environment(\.appLanguage) private var language
    let key: String

    func body(content: Content) -> some View {
        content.navigationTitle(L10n.string(key, language: language))
    }
}

private struct L10nAccessibilityLabelModifier: ViewModifier {
    @Environment(\.appLanguage) private var language
    let key: String

    func body(content: Content) -> some View {
        content.accessibilityLabel(L10n.string(key, language: language))
    }
}

private struct L10nAlertModifier<Actions: View, Message: View>: ViewModifier {
    @Environment(\.appLanguage) private var language
    let key: String
    let isPresented: Binding<Bool>
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let message: () -> Message

    func body(content: Content) -> some View {
        content.alert(
            L10n.string(key, language: language),
            isPresented: isPresented,
            actions: actions,
            message: message
        )
    }
}

private struct L10nConfirmationDialogModifier<Actions: View, Message: View>: ViewModifier {
    @Environment(\.appLanguage) private var language
    let key: String
    let isPresented: Binding<Bool>
    let titleVisibility: Visibility
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let message: () -> Message

    func body(content: Content) -> some View {
        content.confirmationDialog(
            L10n.string(key, language: language),
            isPresented: isPresented,
            titleVisibility: titleVisibility,
            actions: actions,
            message: message
        )
    }
}

extension View {
    /// `.navigationTitle("literal")` routed through the environment language.
    func l10nNavigationTitle(_ key: String) -> some View {
        modifier(L10nNavigationTitleModifier(key: key))
    }

    /// `.accessibilityLabel("literal")` routed through the environment language.
    /// VoiceOver copy is copy: it needs translating for the same reason the
    /// visible label does, and it is the half nobody notices going stale.
    func l10nAccessibilityLabel(_ key: String) -> some View {
        modifier(L10nAccessibilityLabelModifier(key: key))
    }

    func l10nAlert<Actions: View, Message: View>(
        _ key: String,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> Actions,
        @ViewBuilder message: @escaping () -> Message
    ) -> some View {
        modifier(
            L10nAlertModifier(
                key: key,
                isPresented: isPresented,
                actions: actions,
                message: message
            )
        )
    }

    func l10nAlert<Actions: View>(
        _ key: String,
        isPresented: Binding<Bool>,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        modifier(
            L10nAlertModifier(
                key: key,
                isPresented: isPresented,
                actions: actions,
                message: { EmptyView() }
            )
        )
    }

    func l10nConfirmationDialog<Actions: View, Message: View>(
        _ key: String,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: @escaping () -> Actions,
        @ViewBuilder message: @escaping () -> Message
    ) -> some View {
        modifier(
            L10nConfirmationDialogModifier(
                key: key,
                isPresented: isPresented,
                titleVisibility: titleVisibility,
                actions: actions,
                message: message
            )
        )
    }

    func l10nConfirmationDialog<Actions: View>(
        _ key: String,
        isPresented: Binding<Bool>,
        titleVisibility: Visibility = .automatic,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        modifier(
            L10nConfirmationDialogModifier(
                key: key,
                isPresented: isPresented,
                titleVisibility: titleVisibility,
                actions: actions,
                message: { EmptyView() }
            )
        )
    }
}
