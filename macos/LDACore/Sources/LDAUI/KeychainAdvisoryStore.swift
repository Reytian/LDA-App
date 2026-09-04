//
//  KeychainAdvisoryStore.swift
//  LDAUI
//
//  Observable wrapper over KeychainProtectionAdvisory so the UI can show, and
//  keep showing, the fact that Touch ID protection did not take effect.
//
//  Why the UI has to say this out loud: the app turns on user-presence
//  protection at launch, and the Settings copy tells the user their data is
//  behind Touch ID. When an existing unprotected key cannot be upgraded (which
//  happens on a locally signed Developer ID build with no provisioning
//  profile), the store keeps working with the old key and no prompt appears.
//  Silence there is the worst outcome: the user reads a promise the app is not
//  keeping. The advisory turns that into a visible, specific statement.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Combine
import Foundation
import LDACore

/// Publishes the Keychain protection advisory, if any.
@MainActor
final class KeychainAdvisoryStore: ObservableObject {

    /// A one-line, user-facing advisory, or nil when protection is intact.
    @Published private var revision = 0

    var advisory: String? { Self.localizedAdvisory() }

    private var observer: NSObjectProtocol?

    init() {
        // The fallback is discovered lazily, the first time a store reads a key
        // that cannot be upgraded, which is well after launch. Observing means
        // the advisory appears when that happens rather than only on the next
        // app run.
        observer = NotificationCenter.default.addObserver(
            forName: KeychainProtectionAdvisory.didFallBackNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.revision += 1
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Re-read the advisory. Used by views that appear after a fallback has
    /// already been recorded.
    func refresh() {
        revision += 1
    }

    private static func localizedAdvisory() -> String? {
        let scopes = KeychainProtectionAdvisory.affectedScopes
            .map { L10n.string($0) }
        guard !scopes.isEmpty else { return nil }
        var sentence = String(
            format: L10n.string("Touch ID could not be applied to %@. Those keys are still protected by your login keychain, but they unlock without a Touch ID prompt."),
            scopes.joined(separator: ", ") as NSString
        )
        // The reason, verbatim. The label is translated; the status itself is
        // not, and must not be: it is what the user quotes into a bug report
        // and what tells us which errSec this actually is. A localized
        // paraphrase of "OSStatus -34018" would destroy the only diagnostic
        // value the sentence carries.
        let details = KeychainProtectionAdvisory.diagnostics
        if !details.isEmpty {
            sentence += " " + String(
                format: L10n.string("Keychain reported: %@."),
                details.joined(separator: "; ") as NSString
            )
        }
        return sentence
    }
}
