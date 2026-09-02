//
//  MCPRestoreTools.swift
//  LDAMCP
//
//  The restore tool of the handle-first surface: handle to handle. The
//  redacted artifact's encrypted mapping sidecar stays inside the vault, the
//  restored artifact stays inside the vault (it contains real PII again), and
//  the response carries handles and aggregate counts only. See
//  MCPVaultTools.swift for the boundary rules every tool in this surface obeys.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import LDACore

extension MCPServer {

    // MARK: restore

    /// restore: handle to handle. The primary form takes editedText (redacted
    /// text coming FROM the model is fine inbound), writes it into the vault
    /// as its own redacted artifact, and restores that. Without editedText the
    /// redacted artifact restores as it stands. The restored artifact stays IN
    /// the vault; the human exports it through the export flow or the app.
    func callRestoreHandle(_ arguments: [String: Any]) throws -> [String: Any] {
        let redactedHandle = try requireStringArgument(arguments, key: "redactedHandle")
        let vault = openVault()
        let entry = try vault.entry(handle: redactedHandle)
        guard entry.kind == .redacted else {
            throw MCPVaultToolError.notRedacted(handle: redactedHandle, kind: entry.kind)
        }
        let mappingURL = try vault.mappingFileURL(forHandle: redactedHandle)
        let accountBase = entry.mappingAccountBase ?? entry.handle
        let protection = vaultMappingProtection(from: arguments, accountBase: accountBase)
        let stagedAt = MCPServer.iso8601Now()

        let editedText = (arguments["editedText"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }

        if let editedText {
            // Persist the inbound edited text as its own redacted artifact
            // first, so the exact text that was restored is on record and can
            // itself be exported or re-restored.
            let editedSlot = try vault.prepareDerived(kind: .redacted)
            let editedEntry: VaultEntry
            do {
                let editedURL = editedSlot.directory.appendingPathComponent("edited_redacted.txt")
                try CompanionWriter.writeText(editedText, to: editedURL)
                editedEntry = try vault.commit(
                    slot: editedSlot,
                    primaryFile: editedURL,
                    stagedAtISO8601: stagedAt,
                    sourceHandle: redactedHandle,
                    mappingFile: mappingURL,
                    mappingAccountBase: accountBase
                )
            } catch {
                vault.abort(slot: editedSlot)
                throw error
            }

            let restoredSlot = try vault.prepareDerived(kind: .restored)
            do {
                let result = try LDAService.restoreText(
                    editedText,
                    mapping: mappingURL,
                    protection: protection
                )
                let restoredURL = restoredSlot.directory.appendingPathComponent("restored.txt")
                try TextDocumentIO.exportText(result.text, to: restoredURL)
                let committed = try vault.commit(
                    slot: restoredSlot,
                    primaryFile: restoredURL,
                    stagedAtISO8601: stagedAt,
                    sourceHandle: editedEntry.handle,
                    mappingFile: nil,
                    mappingAccountBase: nil
                )
                return [
                    "restoredHandle": committed.handle,
                    "editedRedactedHandle": editedEntry.handle,
                    "restoredCount": result.restoredCount,
                    "orphanTokens": result.orphanTokens,
                    "suspectPlaceholders": result.suspectPlaceholders,
                    // Replacement strings that two or more entities share
                    // (asterisk masks can collide); restore refuses to guess
                    // at them. Replacement strings are boundary-safe: they are
                    // what the redacted text already shows.
                    "ambiguousReplacements": result.ambiguousReplacements
                ]
            } catch {
                vault.abort(slot: restoredSlot)
                throw error
            }
        }

        // No edited text: restore the stored redacted artifact directly.
        let restoredSlot = try vault.prepareDerived(kind: .restored)
        do {
            let outputExtension = entry.format == "docx" ? "docx" : "txt"
            let outputURL = restoredSlot.directory
                .appendingPathComponent("restored.\(outputExtension)")
            let report = try vault.withPlaintextFileURL(handle: redactedHandle) { redactedURL in
                try LDAService.restore(
                    editedRedacted: redactedURL,
                    mapping: mappingURL,
                    protection: protection,
                    output: outputURL
                )
            }
            let committed = try vault.commit(
                slot: restoredSlot,
                primaryFile: outputURL,
                stagedAtISO8601: stagedAt,
                sourceHandle: redactedHandle,
                mappingFile: nil,
                mappingAccountBase: nil
            )
            return [
                "restoredHandle": committed.handle,
                "restoredCount": report.restoredCount,
                "orphanTokens": report.orphanTokens,
                "suspectPlaceholders": report.suspectPlaceholders,
                "ambiguousReplacements": report.ambiguousReplacements
            ]
        } catch {
            vault.abort(slot: restoredSlot)
            throw error
        }
    }
}
