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
    @Published private(set) var advisory: String?

    private var observer: NSObjectProtocol?

    init() {
        advisory = KeychainProtectionAdvisory.advisory
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
                self?.advisory = KeychainProtectionAdvisory.advisory
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
        advisory = KeychainProtectionAdvisory.advisory
    }
}
