//
//  MappingSidecarPresentation.swift
//  LDAUI
//
//  The copy and the rule behind the one choice the export sheet still offers:
//  whether to write a .ldamap next to the redacted document, and the
//  passphrase it then needs.
//
//  Two defaults changed and this file is where the reasoning is stated.
//
//  NO SIDECAR BY DEFAULT. The sidecar holds the original values. It is
//  ciphertext, not plaintext, so writing one was never an exposure by itself;
//  what made it wrong as a DEFAULT is where it lands. It appears in the folder
//  the user is about to send the redacted document from, under a name one
//  character different from it, so the two get attached together. The key's
//  default home is now a workspace on this Mac (see DefaultWorkspace), which
//  is reachable by Restore and not by a mail client.
//
//  A PASSPHRASE WHEN THERE IS ONE. The old sheet let the passphrase be blank
//  and fell back to a Keychain key. That produced the one thing a sidecar is
//  useless as: a file whose whole purpose is to travel, sealed with a key that
//  cannot leave this Mac. So a sidecar now requires a passphrase, and asking
//  for it twice is deliberate. Nothing about it is recoverable from this Mac,
//  and the person who needs it is usually not the person typing it.
//
//  Kept free of SwiftUI so the rule and the wording are tested directly rather
//  than through a window.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation

/// The export sheet's mapping-sidecar decision, as pure functions.
enum MappingSidecarPresentation {

    /// Whether an export writes a .ldamap beside its output, and under which
    /// passphrase, given what the sheet collected.
    ///
    /// The single definition of the default: `wantsSidecar` false yields nil,
    /// and nil is what `ReviewModel.export` reads as "write no sidecar". The
    /// two cannot drift, because there is no second place that decides.
    static func sidecarPassphrase(
        wantsSidecar: Bool,
        passphrase: String,
        confirmation: String
    ) -> String? {
        guard wantsSidecar,
              issue(wantsSidecar: wantsSidecar, passphrase: passphrase, confirmation: confirmation) == nil
        else { return nil }
        return passphrase
    }

    /// Why the sheet cannot export yet, or nil when it can.
    ///
    /// Reuses WorkspacePresentation's passphrase rule rather than restating
    /// it: both files are protecting something a colleague has to open on
    /// another Mac, so a shorter floor here would be an accident, not a
    /// decision.
    static func issue(
        wantsSidecar: Bool,
        passphrase: String,
        confirmation: String
    ) -> WorkspacePresentation.PassphraseIssue? {
        guard wantsSidecar else { return nil }
        return WorkspacePresentation.passphraseIssue(
            passphrase: passphrase,
            confirmation: confirmation
        )
    }

    /// The sentence under the passphrase fields, naming what is still wrong.
    ///
    /// The empty case gets its own noun: WorkspacePresentation's version says
    /// "workspace file", and telling a user to enter a passphrase for a
    /// workspace while they are writing a mapping file would send them
    /// looking for a sheet they never opened. The length and mismatch
    /// sentences carry no noun, so those are shared verbatim.
    static func message(
        for issue: WorkspacePresentation.PassphraseIssue,
        language: AppLanguage? = nil
    ) -> String {
        switch issue {
        case .empty:
            return L10n.string(
                "Enter a passphrase for this mapping file.",
                language: language
            )
        case .tooShort, .mismatch:
            return WorkspacePresentation.message(for: issue, language: language)
        }
    }
}
