//
//  MCPRestoreTools.swift
//  LDAMCP
//
//  The restore tool of the handle-first surface: handle to handle. Three
//  shapes, one mapping:
//
//   - no edit arguments: the stored redacted artifact restores as it stands
//     (a .docx keeps its formatting through DocxRedactor);
//   - editedText: redacted TEXT coming back from the model is written into
//     the vault as its own redacted artifact and restored as text. This is
//     the analysis round trip; Word formatting is not kept on this path;
//   - editedHandle: an EDITED redacted document the human staged back into
//     the vault (or another redacted artifact) is restored with the redacted
//     handle's mapping. A .docx keeps its formatting, so this is the .docx in,
//     .docx out path, with no intermediary text file.
//
//  The mapping sidecar stays inside the vault, the restored artifact stays
//  inside the vault (it contains real PII again), and every response carries
//  handles, the artifact format, and aggregate counts only. See
//  MCPVaultTools.swift for the boundary rules every tool in this surface obeys.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import LDACore

extension MCPServer {

    /// Formats an editedHandle may have. A .pdf or an image is not an edit
    /// surface: neither can carry placeholders back into a restore.
    static let editSurfaceFormats: Set<String> = ["docx", "txt", "md"]

    /// What every restore shape shares: the redacted artifact whose mapping is
    /// used, where that mapping lives, how it is protected, and the timestamp
    /// stamped on whatever the shape commits.
    struct RestoreContext {
        let vault: DocumentVault
        let redactedEntry: VaultEntry
        let mappingURL: URL
        let protection: MappingProtection
        let stagedAt: String
    }

    // MARK: restore

    /// restore: handle to handle. Dispatches on the edit arguments after the
    /// shared checks: the redacted handle must name a redacted artifact, and
    /// editedText and editedHandle are mutually exclusive.
    func callRestoreHandle(_ arguments: [String: Any]) throws -> [String: Any] {
        let redactedHandle = try requireStringArgument(arguments, key: "redactedHandle")
        let editedText = nonEmptyStringArgument(arguments, key: "editedText")
        let editedHandle = nonEmptyStringArgument(arguments, key: "editedHandle")
        if editedText != nil, editedHandle != nil {
            throw MCPToolError.mutuallyExclusiveArguments(["editedText", "editedHandle"])
        }

        let vault = openVault()
        let entry = try vault.entry(handle: redactedHandle)
        guard entry.kind == .redacted else {
            throw MCPVaultToolError.notRedacted(handle: redactedHandle, kind: entry.kind)
        }
        let context = RestoreContext(
            vault: vault,
            redactedEntry: entry,
            mappingURL: try vault.mappingFileURL(forHandle: redactedHandle),
            protection: vaultMappingProtection(
                from: arguments,
                accountBase: entry.mappingAccountBase ?? entry.handle
            ),
            stagedAt: MCPServer.iso8601Now()
        )

        if let editedText {
            return try restoreEditedText(editedText, in: context)
        }
        if let editedHandle {
            return try restoreEditedArtifact(handle: editedHandle, in: context)
        }
        return try restoreStoredArtifact(in: context)
    }

    // MARK: Shapes

    /// editedText: persist the inbound text as its own redacted artifact first,
    /// so the exact text that was restored is on record and can itself be
    /// exported or re-restored, then restore it as text.
    private func restoreEditedText(
        _ editedText: String,
        in context: RestoreContext
    ) throws -> [String: Any] {
        let vault = context.vault
        let editedSlot = try vault.prepareDerived(kind: .redacted)
        let editedEntry: VaultEntry
        do {
            let editedURL = editedSlot.directory.appendingPathComponent("edited_redacted.txt")
            try CompanionWriter.writeText(editedText, to: editedURL)
            editedEntry = try vault.commit(
                slot: editedSlot,
                primaryFile: editedURL,
                stagedAtISO8601: context.stagedAt,
                sourceHandle: context.redactedEntry.handle,
                mappingFile: context.mappingURL,
                mappingAccountBase: context.redactedEntry.mappingAccountBase ?? context.redactedEntry.handle,
                // The edited text still shows whatever its parent left visible.
                excludedEntityCount: context.redactedEntry.excludedEntityCount
            )
        } catch {
            vault.abort(slot: editedSlot)
            throw error
        }

        let restoredSlot = try vault.prepareDerived(kind: .restored)
        do {
            let result = try LDAService.restoreText(
                editedText,
                mapping: context.mappingURL,
                protection: context.protection
            )
            let restoredURL = restoredSlot.directory.appendingPathComponent("restored.txt")
            try TextDocumentIO.exportText(result.text, to: restoredURL)
            let committed = try vault.commit(
                slot: restoredSlot,
                primaryFile: restoredURL,
                stagedAtISO8601: context.stagedAt,
                sourceHandle: editedEntry.handle,
                mappingFile: nil,
                mappingAccountBase: nil
            )
            var response = MCPServer.restoreResponse(
                restoredHandle: committed.handle,
                format: "txt",
                restoredCount: result.restoredCount,
                orphanTokens: result.orphanTokens,
                suspectPlaceholders: result.suspectPlaceholders,
                ambiguousReplacements: result.ambiguousReplacements
            )
            response["editedRedactedHandle"] = editedEntry.handle
            return response
        } catch {
            vault.abort(slot: restoredSlot)
            throw error
        }
    }

    /// editedHandle: the edited document already sits in the vault (staged by
    /// the human, or produced by an earlier tool call). Its lineage to the
    /// redacted artifact is checked first (see EditSurfaceLineage), then it is
    /// decrypted to a scratch file for exactly this call and restored with the
    /// redacted handle's mapping; a .docx goes through the run-preserving
    /// restore, so its formatting survives.
    private func restoreEditedArtifact(
        handle editedHandle: String,
        in context: RestoreContext
    ) throws -> [String: Any] {
        let vault = context.vault
        let edited = try vault.entry(handle: editedHandle)
        let lineage = try MCPServer.editSurfaceLineage(of: edited, for: context.redactedEntry)

        let restoredSlot = try vault.prepareDerived(kind: .restored)
        do {
            let outputURL = restoredSlot.directory.appendingPathComponent("restored.\(edited.format)")
            let report = try vault.withPlaintextFileURL(handle: editedHandle) { editedURL in
                try LDAService.restore(
                    editedRedacted: editedURL,
                    mapping: context.mappingURL,
                    protection: context.protection,
                    output: outputURL
                )
            }
            // An original proves it belongs to this round trip by holding at
            // least one placeholder of the mapping. Without that, "restoring"
            // it would only copy an unrelated document into a restored
            // artifact that export accepts, and its text could ride out as a
            // suspect placeholder. Refuse before anything is committed; the
            // catch below removes the slot.
            if lineage == .stagedOriginal, report.restoredCount == 0 {
                throw MCPVaultToolError.noPlaceholdersFound(
                    editedHandle: editedHandle,
                    redactedHandle: context.redactedEntry.handle,
                    suspectPlaceholderCount: report.suspectPlaceholders.count
                )
            }
            let committed = try vault.commit(
                slot: restoredSlot,
                primaryFile: outputURL,
                stagedAtISO8601: context.stagedAt,
                sourceHandle: editedHandle,
                mappingFile: nil,
                mappingAccountBase: nil,
                workspaceFallbackHandle: context.redactedEntry.handle
            )
            return MCPServer.restoreResponse(
                restoredHandle: committed.handle,
                format: edited.format,
                restoredCount: report.restoredCount,
                orphanTokens: report.orphanTokens,
                suspectPlaceholders: report.suspectPlaceholders,
                ambiguousReplacements: report.ambiguousReplacements,
                disclosesSuspectStrings: lineage == .redactedSharingMapping
            )
        } catch {
            vault.abort(slot: restoredSlot)
            throw error
        }
    }

    // MARK: Lineage of an edit surface

    /// How an editedHandle relates to the redacted artifact whose mapping
    /// restores it. Only two relations are accepted; everything else is
    /// refused before any vault state exists.
    enum EditSurfaceLineage {
        /// A redacted artifact that carries this very mapping: the artifact
        /// itself, a session member sharing its sidecar, or the artifact
        /// restore wrote for edited text. Its text is already known to the
        /// caller through read_redacted or editedText, so suspect placeholder
        /// strings may be disclosed, and zero restored placeholders is a
        /// legitimate outcome (an AI may have mangled every one).
        case redactedSharingMapping
        /// An original the human staged (the edited .docx that came back). It
        /// must prove it belongs to this round trip by restoring at least one
        /// placeholder, and its edits are text the caller has never seen, so
        /// suspect placeholders are reported as a count only.
        case stagedOriginal
    }

    /// Classify an edit surface, refusing restored artifacts (they hold real
    /// values again), formats that cannot carry placeholders, and redacted
    /// artifacts of another mapping (they would restore silently with the
    /// wrong values and export under the other document's name).
    static func editSurfaceLineage(
        of edited: VaultEntry,
        for redacted: VaultEntry
    ) throws -> EditSurfaceLineage {
        guard edited.kind != .restored else {
            throw MCPVaultToolError.notAnEditSurface(edited.handle)
        }
        guard editSurfaceFormats.contains(edited.format) else {
            throw MCPVaultToolError.unsupportedEditFormat(handle: edited.handle, format: edited.format)
        }
        if edited.kind == .original {
            return .stagedOriginal
        }
        // Session members share one sidecar and an edited-text artifact
        // carries its parent's, so the sidecar path is the lineage; the
        // source link covers a derived artifact whose sidecar moved.
        let sharesSidecar = edited.mappingRelativePath != nil
            && edited.mappingRelativePath == redacted.mappingRelativePath
        guard sharesSidecar || edited.sourceHandle == redacted.handle else {
            throw MCPVaultToolError.mappingMismatch(edited.handle)
        }
        return .redactedSharingMapping
    }

    /// No edit arguments: restore the stored redacted artifact directly.
    private func restoreStoredArtifact(in context: RestoreContext) throws -> [String: Any] {
        let vault = context.vault
        let format = MCPServer.restoredFormat(forRedactedFormat: context.redactedEntry.format)
        let restoredSlot = try vault.prepareDerived(kind: .restored)
        do {
            let outputURL = restoredSlot.directory.appendingPathComponent("restored.\(format)")
            let report = try vault.withPlaintextFileURL(handle: context.redactedEntry.handle) { redactedURL in
                try LDAService.restore(
                    editedRedacted: redactedURL,
                    mapping: context.mappingURL,
                    protection: context.protection,
                    output: outputURL
                )
            }
            let committed = try vault.commit(
                slot: restoredSlot,
                primaryFile: outputURL,
                stagedAtISO8601: context.stagedAt,
                sourceHandle: context.redactedEntry.handle,
                mappingFile: nil,
                mappingAccountBase: nil
            )
            return MCPServer.restoreResponse(
                restoredHandle: committed.handle,
                format: format,
                restoredCount: report.restoredCount,
                orphanTokens: report.orphanTokens,
                suspectPlaceholders: report.suspectPlaceholders,
                ambiguousReplacements: report.ambiguousReplacements
            )
        } catch {
            vault.abort(slot: restoredSlot)
            throw error
        }
    }

    // MARK: Helpers

    /// The format a stored redacted artifact restores to: a .docx stays a
    /// .docx and a Markdown intermediate stays Markdown; every other redacted
    /// artifact is a text edit surface and restores as text.
    static func restoredFormat(forRedactedFormat format: String) -> String {
        switch format {
        case "docx", "md":
            return format
        default:
            return "txt"
        }
    }

    /// The response every restore shape shares. orphanTokens and
    /// ambiguousReplacements are boundary-safe: placeholder shapes, or what
    /// the redacted text already shows. Suspect placeholders are verbatim
    /// substrings of the scanned text, so their strings are disclosed only
    /// when that text is already known to the caller; the count always is.
    /// The handle names an artifact that stays in the vault.
    static func restoreResponse(
        restoredHandle: String,
        format: String,
        restoredCount: Int,
        orphanTokens: [String],
        suspectPlaceholders: [String],
        ambiguousReplacements: [String],
        disclosesSuspectStrings: Bool = true
    ) -> [String: Any] {
        var response: [String: Any] = [
            "restoredHandle": restoredHandle,
            "format": format,
            "restoredCount": restoredCount,
            "orphanTokens": orphanTokens,
            "suspectPlaceholderCount": suspectPlaceholders.count,
            "ambiguousReplacements": ambiguousReplacements
        ]
        if disclosesSuspectStrings {
            response["suspectPlaceholders"] = suspectPlaceholders
        }
        return response
    }

    /// An optional string argument, with an empty string treated as absent.
    func nonEmptyStringArgument(_ arguments: [String: Any], key: String) -> String? {
        (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
