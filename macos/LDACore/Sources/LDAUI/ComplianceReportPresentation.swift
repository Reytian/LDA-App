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
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation

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
    static func message(for issue: WorkspacePresentation.PassphraseIssue) -> String {
        switch issue {
        case .empty:
            return "Enter a passphrase for this report file."
        case .tooShort, .mismatch:
            return WorkspacePresentation.message(for: issue)
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
    static func summary(_ result: ComplianceReportExportResult) -> String {
        switch result {
        case .encrypted(let url):
            return "Report saved as \(url.lastPathComponent). Opening it needs "
                + "LDA and this passphrase."
        case .readable(let markdown, let pdf):
            return "Report saved: \(markdown.lastPathComponent) and "
                + "\(pdf.lastPathComponent). Both carry the matter and document "
                + "names in the clear."
        }
    }

    /// The one-line result of a failed export or open.
    static func failure(_ error: Error, action: String) -> String {
        "\(action) failed. \(error.localizedDescription)"
    }
}
