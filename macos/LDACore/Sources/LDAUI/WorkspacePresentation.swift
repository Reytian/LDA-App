//
//  WorkspacePresentation.swift
//  LDAUI
//
//  Pure presentation decisions for the portable workspace (.ldawork): when Save
//  Workspace can run, what opening one over live work must ask first, what a
//  passphrase pair has to satisfy, and the sentences the user reads.
//
//  Kept free of SwiftUI on purpose so the gating and the wording are tested
//  directly rather than through a window.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

enum WorkspacePresentation {

    // MARK: - Save gating

    /// Save Workspace needs work to save. An empty tray has none.
    static func canSave(documentCount: Int) -> Bool {
        documentCount > 0
    }

    /// The neutral default file name.
    ///
    /// Deliberately NOT the matter label. This app's threat model says file
    /// names carry party names, which is the entire reason the archive
    /// encrypts its own entry names; defaulting the OUTER file name to the
    /// matter would put the party back on the outside of the envelope, in the
    /// place most likely to be emailed. The user can rename in the save panel,
    /// where that is their informed choice.
    static let defaultFileName = "LDA Workspace"

    /// The proposed name the save panel opens with.
    static func proposedFileName() -> String {
        defaultFileName + "." + WorkspaceArchive.fileExtension
    }

    // MARK: - Passphrase

    /// Shortest passphrase accepted for a file designed to travel. A workspace
    /// leaves this Mac by design, so its protection is only as good as what
    /// the user types.
    static let minimumPassphraseLength = 8

    /// Why a passphrase pair is not yet acceptable, or nil when it is.
    enum PassphraseIssue: Equatable {
        case empty
        case tooShort(minimum: Int)
        case mismatch
    }

    static func passphraseIssue(passphrase: String, confirmation: String) -> PassphraseIssue? {
        if passphrase.isEmpty { return .empty }
        if passphrase.count < minimumPassphraseLength {
            return .tooShort(minimum: minimumPassphraseLength)
        }
        if passphrase != confirmation { return .mismatch }
        return nil
    }

    static func message(for issue: PassphraseIssue) -> String {
        switch issue {
        case .empty:
            return "Enter a passphrase for this workspace file."
        case .tooShort(let minimum):
            return "Use at least \(minimum) characters."
        case .mismatch:
            return "The two passphrases do not match."
        }
    }

    /// The one-line warning beside the passphrase fields. States what the app
    /// does, not what is universally possible.
    static let irrecoverabilityNote = "LDA does not keep a copy of this "
        + "passphrase, so the app has no way to open the file without it. "
        + "Store it the way you would store the file."

    static let saveHelp = "Save this matter's documents, review decisions, and "
        + "replacements as one encrypted file you can reopen or hand to a colleague"

    // MARK: - Opening over live work

    /// What must happen before a workspace replaces what is on screen.
    enum OpenConflict: Equatable {
        /// Nothing is open; go straight to the passphrase.
        case openImmediately
        /// Live work would be replaced; ask first.
        case confirmReplacement
    }

    static func openConflict(hasActiveWork: Bool) -> OpenConflict {
        hasActiveWork ? .confirmReplacement : .openImmediately
    }

    static let replacementPrompt = "Opening a workspace closes the documents "
        + "and unfinished restore context in this window. Save the current work "
        + "as a workspace first, or discard it."

    // MARK: - Outcome

    /// The one-line result of a successful open, warnings appended.
    static func summary(_ summary: WorkspaceOpenSummary) -> String {
        let documents = summary.documentCount == 1 ? "1 document" : "\(summary.documentCount) documents"
        var line = "Opened \(documents)"
        if let matter = summary.matterLabel {
            line += " under \(matter)"
        }
        line += "."
        if summary.restoredEntityCount > 0 {
            line += " \(summary.restoredEntityCount) review decisions restored."
        }
        if !summary.warnings.isEmpty {
            line += " " + summary.warnings.joined(separator: " ")
        }
        return line
    }

    /// The one-line result of a failed open or save.
    static func failure(_ error: Error, action: String) -> String {
        "\(action) failed. \(error.localizedDescription)"
    }
}
