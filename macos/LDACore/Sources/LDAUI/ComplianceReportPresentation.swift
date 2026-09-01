//
//  ComplianceReportPresentation.swift
//  LDAUI
//
//  Pure presentation decisions for the compliance report export: which shape
//  the sheet opens on, when the confirming button is allowed, and the
//  sentences the user reads.
//
//  The passphrase RULE is not restated here. It is WorkspacePresentation's,
//  reached through this file, so the two travelling formats can never drift
//  into two different minimum lengths. Only the noun in one message differs.
//
//  Kept free of SwiftUI on purpose so the gating and the wording are tested
//  directly rather than through a window.
//
//  House rules: user-facing copy is localized. No prohibited dash separators.
//

import Foundation
import LDACore

enum ComplianceReportPresentation {

    // MARK: - Shape

    /// The two shapes an export can take.
    enum Shape: Equatable, Hashable, CaseIterable {

        /// One encrypted file the recipient opens in LDA with the passphrase.
        case encrypted

        /// report.md and report.pdf, readable by anyone holding them.
        case readable
    }

    /// What the sheet opens on. The report names the matter and every
    /// document, so the shape a distracted user gets by pressing Return has to
    /// be the protected one.
    static let defaultShape: Shape = .encrypted

    /// Map a sheet shape and the typed passphrase onto the model's choice.
    static func protection(
        for shape: Shape,
        passphrase: String
    ) -> ComplianceReportProtection {
        switch shape {
        case .encrypted: return .passphrase(passphrase)
        case .readable: return .readable
        }
    }

    // MARK: - Passphrase

    /// The workspace file's rule, reused rather than restated.
    static let minimumPassphraseLength = WorkspacePresentation.minimumPassphraseLength

    static func passphraseIssue(
        passphrase: String,
        confirmation: String
    ) -> WorkspacePresentation.PassphraseIssue? {
        WorkspacePresentation.passphraseIssue(
            passphrase: passphrase,
            confirmation: confirmation
        )
    }

    /// The workspace wording, with the report's noun where the noun shows.
    static func message(
        for issue: WorkspacePresentation.PassphraseIssue,
        language: AppLanguage? = nil
    ) -> String {
        switch issue {
        case .empty:
            return L10n.string(
                "Enter a passphrase for this report file.",
                language: language
            )
        case .tooShort, .mismatch:
            return WorkspacePresentation.message(for: issue, language: language)
        }
    }

    /// Whether the confirming button may fire. The readable shape needs no
    /// passphrase, which is exactly why it has to be chosen deliberately.
    static func canConfirmExport(
        shape: Shape,
        passphrase: String,
        confirmation: String
    ) -> Bool {
        switch shape {
        case .readable:
            return true
        case .encrypted:
            return passphraseIssue(passphrase: passphrase, confirmation: confirmation) == nil
        }
    }

    // MARK: - Copy

    static let exportHeadline = "Protect this report"

    static let exportExplanation = "The report lists this matter's label, every "
        + "document name, and what was protected in each one. Choose how to "
        + "save it."

    static let encryptedOptionTitle = "Encrypted report file (report.ldareport)"

    static let encryptedOptionNote = "One file. The recipient opens it in LDA "
        + "with the passphrase you choose."

    static let readableOptionTitle = "Readable files (report.md and report.pdf)"

    /// The sentence beside the readable choice. It names what becomes
    /// readable, because that is the whole decision the user is making.
    static let readableWarning = "Not protected. The files carry the matter's "
        + "party names and every document name in the clear, so anyone who "
        + "receives them can read them. Choose this only when the recipient "
        + "cannot use LDA."

    /// Reused from the workspace flow: the app's position on lost passphrases
    /// is one position, not two.
    static let irrecoverabilityNote = WorkspacePresentation.irrecoverabilityNote

    static let openHeadline = "Open report"

    static let openExplanation = "Enter the passphrase this report file was "
        + "saved with. LDA will write report.md and report.pdf into the folder "
        + "you chose, and those copies carry the names in the clear."

    static let exportHelp = "Save a processing report of what this session's "
        + "record holds, encrypted or as readable files"

    // MARK: - Outcome

    /// The one-line result of a successful export or open.
    static func summary(
        _ result: ComplianceReportExportResult,
        language: AppLanguage? = nil
    ) -> String {
        let locale = (language ?? AppLanguage.selected()).locale
        switch result {
        case .encrypted(let url):
            return String(
                format: L10n.string(
                    "Report saved as %@. Opening it needs LDA and this passphrase.",
                    language: language
                ),
                locale: locale,
                url.lastPathComponent as NSString
            )
        case .readable(let markdown, let pdf):
            return String(
                format: L10n.string(
                    "Report saved: %@ and %@. Both carry the matter and document names in the clear.",
                    language: language
                ),
                locale: locale,
                markdown.lastPathComponent as NSString,
                pdf.lastPathComponent as NSString
            )
        }
    }

    /// Translate encrypted-report errors at the UI boundary. Lower-level
    /// details remain verbatim format arguments.
    static func archiveErrorDescription(
        _ error: Error,
        language: AppLanguage? = nil
    ) -> String? {
        guard let archiveError = error as? ComplianceReportArchiveError else {
            return nil
        }
        let locale = (language ?? AppLanguage.selected()).locale
        func format(_ key: String, _ arguments: [CVarArg]) -> String {
            String(
                format: L10n.string(key, language: language),
                locale: locale,
                arguments: arguments
            )
        }
        switch archiveError {
        case .wrongPassphrase:
            return L10n.string(
                "That passphrase did not open this report file.",
                language: language
            )
        case .createdByNewerVersion(let found, let supported):
            return format(
                "This report file was created by a newer version of LDA "
                    + "(format %lld; this app reads format %lld). Update LDA to open it.",
                [Int64(found), Int64(supported)]
            )
        case .damagedFile(let detail):
            return format(
                "This report file could not be read. %@",
                [detail as NSString]
            )
        case .writeFailed(let detail):
            return format(
                "The report file could not be saved. %@",
                [detail as NSString]
            )
        }
    }

    /// The one-line result of a failed export or open.
    static func failure(
        _ error: Error,
        action: String,
        language: AppLanguage? = nil
    ) -> String {
        if let description = archiveErrorDescription(error, language: language) {
            let localizedError = PresentationError(description: description)
            return WorkspacePresentation.failure(
                localizedError,
                action: action,
                language: language
            )
        }
        return WorkspacePresentation.failure(
            error,
            action: action,
            language: language
        )
    }

    private struct PresentationError: LocalizedError {
        let description: String

        var errorDescription: String? { description }
    }
}
