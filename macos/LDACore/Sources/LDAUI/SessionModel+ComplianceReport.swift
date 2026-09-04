//
//  SessionModel+ComplianceReport.swift
//  LDAUI
//
//  The session's half of the exportable compliance report (F6): render the
//  session record, then write the shape the user chose.
//
//  The default shape is ONE encrypted file (report.ldareport) holding both
//  deliverables. The report names the matter and every document it processed,
//  and in PRC legal practice those names are the parties, which is why the
//  record it is rendered from is encrypted at rest in the first place. See
//  ComplianceReportArchive for the format and the full reasoning.
//
//  The readable pair (report.md and report.pdf) is still reachable, because a
//  regulator or a client may have no copy of LDA. It is a separate case the
//  caller has to name, never a default, and the sheet that offers it says in
//  plain words what will be readable.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import LDACore

// MARK: - Choice and outcome

/// How one report export is protected on disk.
public enum ComplianceReportProtection: Equatable, Sendable {

    /// One encrypted file, opened with this passphrase and nothing else.
    case passphrase(String)

    /// The readable pair, in the clear. Chosen explicitly, never by default.
    case readable
}

/// What an export actually wrote.
public enum ComplianceReportExportResult: Equatable, Sendable {

    /// The single encrypted file.
    case encrypted(URL)

    /// The readable Markdown and its PDF twin.
    case readable(markdown: URL, pdf: URL)

    /// Every file the export produced, in the order it wrote them.
    public var writtenURLs: [URL] {
        switch self {
        case .encrypted(let url):
            return [url]
        case .readable(let markdown, let pdf):
            return [markdown, pdf]
        }
    }
}

// MARK: - Export

@MainActor
extension SessionModel {

    /// Whether the session has a record to report on, and why not when it does
    /// not. Set by the hand-to-AI build; cleared when the matter boundary
    /// changes.
    ///
    /// Routed through the shared availability type for the same reason the two
    /// save gates are: this button sits beside them in the toolbar and used to
    /// swallow its click just as silently.
    public var complianceReportAvailability: SaveAvailability {
        SaveAvailabilityRules.exportReport(hasHandoffRecord: currentRecordID != nil)
    }

    /// Render the current session's record as the compliance report and write
    /// it into the chosen directory in the chosen shape. The caller supplies
    /// the generation timestamp so the Markdown render stays deterministic.
    ///
    /// - Throws: DocumentIOError.unreadable when there is no readable record,
    ///   or ComplianceReportArchiveError from the format layer.
    @discardableResult
    public func exportComplianceReport(
        to directory: URL,
        generatedAtISO8601: String,
        protection: ComplianceReportProtection
    ) throws -> ComplianceReportExportResult {
        let bundle = try renderComplianceReport(generatedAtISO8601: generatedAtISO8601)
        switch protection {
        case .passphrase(let passphrase):
            let url = directory.appendingPathComponent(
                ComplianceReportArchive.encryptedFileName
            )
            try ComplianceReportArchive.write(bundle, to: url, passphrase: passphrase)
            return .encrypted(url)
        case .readable:
            let written = try ComplianceReportArchive.writeReadable(bundle, into: directory)
            return .readable(markdown: written.markdown, pdf: written.pdf)
        }
    }

    /// Render the current record as both deliverables, without writing.
    ///
    /// - Throws: DocumentIOError.unreadable when the session has no record, or
    ///   when the record it has cannot be read back.
    func renderComplianceReport(
        generatedAtISO8601: String
    ) throws -> ComplianceReportBundle {
        guard let recordID = currentRecordID else {
            throw DocumentIOError.unreadable(
                "No session record exists yet. Use Export for AI first."
            )
        }
        guard let record = try recordStore().load(
            id: recordID,
            protection: recordProtection()
        ) else {
            throw DocumentIOError.unreadable("The session record could not be read.")
        }
        let markdown = ComplianceReport.markdown(
            record: record,
            generatedAtISO8601: generatedAtISO8601
        )
        return ComplianceReportBundle(
            markdown: markdown,
            pdf: ComplianceReportPDF.render(markdown: markdown)
        )
    }

    /// Decrypt a report file and write its readable pair into a directory the
    /// user chose. This is how a recipient reads an encrypted report.
    ///
    /// - Throws: ComplianceReportArchiveError.wrongPassphrase when the
    ///   passphrase does not open the file.
    @discardableResult
    public func openComplianceReport(
        at url: URL,
        passphrase: String,
        writingInto directory: URL
    ) throws -> ComplianceReportExportResult {
        let bundle = try ComplianceReportArchive.read(from: url, passphrase: passphrase)
        let written = try ComplianceReportArchive.writeReadable(bundle, into: directory)
        return .readable(markdown: written.markdown, pdf: written.pdf)
    }
}
