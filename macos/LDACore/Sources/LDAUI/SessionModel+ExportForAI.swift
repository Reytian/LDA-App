//
//  SessionModel+ExportForAI.swift
//  LDAUI
//
//  Export for AI: the whole session as ONE redacted Markdown file plus its
//  encrypted .ldamap sidecar. Built on buildHandToAI unchanged, so the shared
//  session mapping, the R18 record, the parked round trip, the sealed token
//  chips, the cross-document rescan warnings, and the outbound preflight are
//  inherited by construction rather than re-implemented here.
//
//  The shell asks for the destination BEFORE calling exportForAI: nothing in
//  this file runs until the user has confirmed the save panel, so cancelling
//  the panel leaves the session exactly as it was.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

extension SessionModel {

    /// What one Export for AI wrote, and what the completion card reports.
    public struct ExportForAIResult: Equatable {
        /// The Markdown file the user uploads to the AI tool.
        public let markdownURL: URL
        /// The encrypted sidecar next to it; the key Restore uses when the
        /// session is gone.
        public let mappingURL: URL
        /// How many documents were included.
        public let documentCount: Int
        /// How many documents were skipped because they were not scanned yet.
        public let skippedCount: Int
        /// The tray ids of the included documents, for the Share step gate.
        public let includedDocumentIDs: Set<UUID>
        /// Included documents that still carry a party another document
        /// confirmed; see HandToAIResult.rescanWarnings.
        public let rescanWarnings: [RescanWarning]
        /// Sites that would restore to the wrong entity; see
        /// HandToAIResult.seamIssues.
        public let seamIssues: [SessionSeamIssue]
    }

    /// The sidecar path for a Markdown export: same folder, same base name,
    /// the .ldamap extension. Pure, so the export and the restore side agree
    /// on the name without touching the disk.
    nonisolated public static func sidecarURL(for markdownURL: URL) -> URL {
        markdownURL.deletingPathExtension().appendingPathExtension(MappingStore.fileExtension)
    }

    /// Export the session for an AI tool into `url`, which the user has
    /// already chosen in a save panel.
    ///
    /// Returns nil when no document is ready; nothing is written and nothing
    /// changes. Throws when the handoff cannot be built (the session is left
    /// as buildHandToAI left it) or when a file cannot be written.
    @discardableResult
    public func exportForAI(to url: URL, createdAtISO8601: String) throws -> ExportForAIResult? {
        guard let handoff = try buildHandToAI(createdAtISO8601: createdAtISO8601) else {
            return nil
        }
        guard let mapping = sessionMapping else {
            throw DocumentIOError.unreadable("The handoff produced no session mapping.")
        }

        let markdown = MarkdownHandoffWriter.render(combined: handoff.combined, style: mapping.style)
        try MarkdownHandoffWriter.write(markdown, to: url)

        // THIS sidecar is written unconditionally, unlike the Save Redacted
        // one, and the difference is deliberate rather than an oversight.
        //
        // Save Redacted's sidecar exists to TRAVEL, so it is passphrase sealed
        // and only written when asked: it would otherwise sit in the folder
        // the user is about to send from. This one exists to STAY. It is the
        // only home the hand-to-AI mapping has, because this path keeps no
        // workspace copy, so declining to write it would make every AI round
        // trip unrestorable, which is the exact defect the export guard in
        // ReviewModel.export exists to prevent. Keychain protection is right
        // for the same reason: the file is not meant to open anywhere else.
        //
        // Keyed by the file's own base name, exactly like a Save Redacted
        // sidecar, so Restore derives the Keychain account from the name it
        // finds next to the file. No passphrase prompt: the contents are
        // sealed to this Mac, so uploading it by mistake leaks no values.
        // The FILE NAME still carries the document's name; see the note on
        // DefaultWorkspace.fileName for that trade.
        // Written as the related item of the chosen file, which is what the
        // sandbox's save-panel grant covers.
        let sidecarURL = Self.sidecarURL(for: url)
        let base = url.deletingPathExtension().lastPathComponent
        let protection = exportSidecarProtection(base)
        try RelatedSidecarAccess.write(sidecar: sidecarURL, primary: url) { destination in
            try MappingStore.save(mapping, to: destination, protection: protection)
        }

        return ExportForAIResult(
            markdownURL: url,
            mappingURL: sidecarURL,
            documentCount: handoff.documentCount,
            skippedCount: handoff.skippedCount,
            includedDocumentIDs: Set(handoff.perDocument.keys),
            rescanWarnings: handoff.rescanWarnings,
            seamIssues: handoff.seamIssues
        )
    }
}
