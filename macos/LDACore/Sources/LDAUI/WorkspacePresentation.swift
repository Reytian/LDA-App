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
//  House rules: user-facing copy is localized. No prohibited dash separators.
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

    static func message(
        for issue: PassphraseIssue,
        language: AppLanguage? = nil
    ) -> String {
        switch issue {
        case .empty:
            return L10n.string(
                "Enter a passphrase for this workspace file.",
                language: language
            )
        case .tooShort(let minimum):
            return String(
                format: L10n.string(
                    "Use at least %lld characters.",
                    language: language
                ),
                locale: (language ?? AppLanguage.selected()).locale,
                Int64(minimum)
            )
        case .mismatch:
            return L10n.string(
                "The two passphrases do not match.",
                language: language
            )
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
    static func summary(
        _ summary: WorkspaceOpenSummary,
        language: AppLanguage? = nil
    ) -> String {
        let locale = (language ?? AppLanguage.selected()).locale
        let documentKey = summary.documentCount == 1 ? "%lld document" : "%lld documents"
        let documents = String(
            format: L10n.string(documentKey, language: language),
            locale: locale,
            Int64(summary.documentCount)
        )
        let openingKey = summary.matterLabel == nil ? "Opened %@." : "Opened %@ under %@."
        var arguments: [CVarArg] = [documents as NSString]
        if let matter = summary.matterLabel {
            arguments.append(matter as NSString)
        }
        var line = String(
            format: L10n.string(openingKey, language: language),
            locale: locale,
            arguments: arguments
        )
        if summary.restoredEntityCount > 0 {
            let decisionKey = summary.restoredEntityCount == 1
                ? " %lld review decision restored."
                : " %lld review decisions restored."
            line += String(
                format: L10n.string(decisionKey, language: language),
                locale: locale,
                Int64(summary.restoredEntityCount)
            )
        }
        if !summary.warnings.isEmpty {
            line += " " + summary.warnings.joined(separator: " ")
        }
        return line
    }

    // MARK: - Archive failures

    /// Translate archive errors at the UI boundary. Names and lower-level
    /// details are format arguments, so they remain exactly as received.
    static func archiveErrorDescription(
        _ error: Error,
        language: AppLanguage? = nil
    ) -> String? {
        guard let archiveError = error as? WorkspaceArchiveError else { return nil }
        switch archiveError {
        case .wrongPassphrase:
            return L10n.string(
                "That passphrase did not open this workspace file.",
                language: language
            )
        case .createdByNewerVersion(let found, let supported):
            return format(
                "This workspace file was created by a newer version of LDA "
                    + "(format %lld; this app reads format %lld). Update LDA to open it.",
                language: language,
                arguments: [Int64(found), Int64(supported)]
            )
        case .damagedFile(let detail):
            return format(
                "This workspace file could not be read. %@",
                language: language,
                arguments: [detail as NSString]
            )
        case .documentUnreadable(let name, let detail):
            return format(
                "Could not read %@ while saving the workspace. %@",
                language: language,
                arguments: [name as NSString, detail as NSString]
            )
        case .tooLarge(let detail):
            return format(
                "This workspace file is too large to open. %@",
                language: language,
                arguments: [detail as NSString]
            )
        case .unsupportedDocumentKind(let name):
            return format(
                "This workspace file lists %@, which is not a document type LDA opens. "
                    + "It was not written by LDA and has not been opened.",
                language: language,
                arguments: [name as NSString]
            )
        case .writeFailed(let detail):
            return format(
                "The workspace file could not be saved. %@",
                language: language,
                arguments: [detail as NSString]
            )
        }
    }

    // MARK: - Open warnings

    static func matterSelectionWarning(
        matterLabel: String,
        errorDescription: String,
        language: AppLanguage? = nil
    ) -> String {
        format(
            "This workspace belongs to the matter \"%@\", which could not be selected "
                + "on this Mac. %@ The documents opened without a matter.",
            language: language,
            arguments: [matterLabel as NSString, errorDescription as NSString]
        )
    }

    static func snapshotRelocationWarning(
        documentName: String,
        appliedCount: Int,
        droppedCount: Int,
        language: AppLanguage? = nil
    ) -> String {
        let matched = format(
            appliedCount == 1
                ? "%@ reads slightly differently in this version of LDA, so its "
                    + "%lld protected value was matched by text."
                : "%@ reads slightly differently in this version of LDA, so its "
                    + "%lld protected values were matched by text.",
            language: language,
            arguments: [documentName as NSString, Int64(appliedCount)]
        )
        guard droppedCount > 0 else { return matched }
        let dropped = format(
            "%lld could not be found; scan again to check.",
            language: language,
            arguments: [Int64(droppedCount)]
        )
        return matched + " " + dropped
    }

    static func savedReplacementWarning(
        errorDescription: String,
        language: AppLanguage? = nil
    ) -> String {
        format(
            "The saved replacement for one value could not be restored. %@",
            language: language,
            arguments: [errorDescription as NSString]
        )
    }

    /// The one-line result of a failed open or save.
    static func failure(
        _ error: Error,
        action: String,
        language: AppLanguage? = nil
    ) -> String {
        let description = archiveErrorDescription(error, language: language)
            ?? DocumentErrorPresentation.describe(error, language: language)
            ?? error.localizedDescription
        return format(
            "%@ failed. %@",
            language: language,
            arguments: [
                L10n.string(action, language: language) as NSString,
                description as NSString
            ]
        )
    }

    private static func format(
        _ key: String,
        language: AppLanguage?,
        arguments: [CVarArg]
    ) -> String {
        String(
            format: L10n.string(key, language: language),
            locale: (language ?? AppLanguage.selected()).locale,
            arguments: arguments
        )
    }
}
