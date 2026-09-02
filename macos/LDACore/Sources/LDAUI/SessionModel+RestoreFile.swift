//
//  SessionModel+RestoreFile.swift
//  LDAUI
//
//  The Restore mode's file flow: which mapping opens the file that came back,
//  how a sidecar is opened, and the restore itself. Restore asks no question
//  the app can answer: the .ldamap saved next to the file wins (Save Redacted
//  tokenizes without the session seed, so its tokens can differ from the
//  session's), then the session mapping (the parked round trip is resumed just
//  in time), then the matter's stored mapping, and only then does the shell
//  ask for a file. A passphrase is asked for only after a Keychain load fails.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

extension SessionModel {

    // MARK: - Which mapping opens the file

    /// Where the mapping for a file about to be restored comes from.
    public enum RestoreMappingSource: Equatable {
        /// The .ldamap saved next to the file, written for exactly that file.
        case sidecar(URL)
        /// The in-memory session mapping, possibly just resumed from the
        /// parked round trip.
        case session(Mapping)
        /// The matter's stored mapping, when nothing is in memory.
        case clientProfile(Mapping)
        /// Nothing found; the shell has to ask.
        case none
    }

    /// The order table, pure so it can be checked row by row.
    public static func resolveRestoreMappingSource(
        sidecar: URL?,
        sessionMapping: Mapping?,
        clientMapping: Mapping?
    ) -> RestoreMappingSource {
        if let sidecar { return .sidecar(sidecar) }
        if let sessionMapping { return .session(sessionMapping) }
        if let clientMapping { return .clientProfile(clientMapping) }
        return .none
    }

    /// Resolve the mapping source for `editedFile`. The sibling check comes
    /// first and touches nothing but the file system, so a file that brought
    /// its own key never costs a Keychain prompt for the parked round trip.
    public func restoreMappingSource(for editedFile: URL) throws -> RestoreMappingSource {
        let sibling = Self.sidecarURL(for: editedFile)
        if FileManager.default.fileExists(atPath: sibling.path) {
            return .sidecar(sibling)
        }
        // Just-in-time parked-session resume (no-op when a mapping is already
        // loaded or nothing is parked). Keeps Keychain access user-initiated.
        resumeParkedSession()
        var clientMapping: Mapping?
        if sessionMapping == nil, let clientLabel {
            clientMapping = try clientStore().load(
                label: clientLabel,
                protection: clientProtection(clientLabel)
            )
        }
        return Self.resolveRestoreMappingSource(
            sidecar: nil,
            sessionMapping: sessionMapping,
            clientMapping: clientMapping
        )
    }

    // MARK: - Opening a sidecar

    /// The Keychain account a sidecar was sealed under: its own base name.
    /// Save Redacted and Export for AI both write sidecars that way, so the
    /// name found next to the file is the whole key.
    public static func sidecarKeychainAccount(for sidecarURL: URL) -> String {
        sidecarURL.deletingPathExtension().lastPathComponent
    }

    /// Open a sidecar. Without a passphrase the Keychain account derived from
    /// the file name is used; with one, the passphrase is.
    public static func loadSidecarMapping(at sidecarURL: URL, passphrase: String? = nil) throws -> Mapping {
        let protection: MappingProtection = passphrase.map { .passphrase($0) }
            ?? .keychain(account: sidecarKeychainAccount(for: sidecarURL))
        return try MappingStore.load(from: sidecarURL, protection: protection)
    }

    /// Whether a failed Keychain load means "ask for the passphrase": the
    /// sidecar was sealed with one (the container tag does not match) or its
    /// key is not on this Mac. Anything else is a genuine failure to report.
    public static func sidecarLoadNeedsPassphrase(_ error: Error) -> Bool {
        guard let ioError = error as? DocumentIOError else { return false }
        switch ioError {
        case .decryptionFailed, .keychainError:
            return true
        case .unreadable, .unsupportedFormat, .corrupt, .ocrUnavailable, .tooLarge:
            return false
        }
    }

    // MARK: - The restore itself

    /// Restore `editedFile` with a resolved mapping and record the event.
    ///
    /// A Word document goes through LDAService and keeps its formatting.
    /// Markdown and text restore as text; when the chosen output is .docx they
    /// become a plain regenerated Word file (the agreed fidelity floor), never
    /// a merge into the original document's runs.
    public func restoreFile(_ editedFile: URL, mapping: Mapping, output: URL) throws -> RestoreReport {
        let report: RestoreReport
        if editedFile.pathExtension.lowercased() != "docx", output.pathExtension.lowercased() == "docx" {
            report = try Self.restoreTextIntoPlainWord(editedFile, mapping: mapping, output: output)
        } else {
            report = try LDAService.restore(editedRedacted: editedFile, mapping: mapping, output: output)
        }
        recordRestoreEvent(report)
        return report
    }

    /// Text in, a fresh minimal Word file out (one paragraph per line).
    private static func restoreTextIntoPlainWord(
        _ editedFile: URL,
        mapping: Mapping,
        output: URL
    ) throws -> RestoreReport {
        let imported = try TextDocumentIO().importDocument(editedFile)
        let result = Restorer.restore(text: imported.text, mapping: mapping)
        try SimpleDocxWriter.write(result.text, to: output)
        return RestoreReport(
            outputURL: output,
            restoredCount: result.restoredCount,
            orphanTokens: result.orphanTokens,
            suspectPlaceholders: result.suspectPlaceholders,
            ambiguousReplacements: result.ambiguousReplacements
        )
    }

    // MARK: - Session record (R18)

    /// Append one restore to the session record, so the Workspace restore
    /// count stays truthful whichever path restored. Best effort: a record
    /// failure must never block a restore, and a session without a record
    /// (nothing exported yet) records nothing.
    public func recordRestoreEvent(_ result: RestoreResult) {
        appendRestoreEvent(
            restoredCount: result.restoredCount,
            orphanCount: result.orphanTokens.count,
            suspectCount: result.suspectPlaceholders.count,
            ambiguousCount: result.ambiguousReplacements.count
        )
    }

    /// The file path's counterpart of recordRestoreEvent(_ result:).
    public func recordRestoreEvent(_ report: RestoreReport) {
        appendRestoreEvent(
            restoredCount: report.restoredCount,
            orphanCount: report.orphanTokens.count,
            suspectCount: report.suspectPlaceholders.count,
            ambiguousCount: report.ambiguousReplacements.count
        )
    }

    private func appendRestoreEvent(
        restoredCount: Int,
        orphanCount: Int,
        suspectCount: Int,
        ambiguousCount: Int
    ) {
        guard let recordID = currentRecordID, let store = try? recordStore() else { return }
        let event = SessionRestoreEvent(
            atISO8601: ISO8601DateFormatter().string(from: Date()),
            restoredCount: restoredCount,
            orphanCount: orphanCount,
            suspectCount: suspectCount,
            ambiguousCount: ambiguousCount
        )
        try? store.appendRestoreEvent(
            to: recordID,
            event: event,
            protection: recordProtection()
        )
    }
}
