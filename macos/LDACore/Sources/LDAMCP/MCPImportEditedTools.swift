import Foundation
import LDACore

extension MCPServer {
    func callImportEditedDocument(_ arguments: [String: Any]) throws -> [String: Any] {
        guard Set(arguments.keys).isSubset(of: ["redactedHandle"]) else {
            throw MCPVaultToolError.invalidImportArguments
        }
        let handle = try requireStringArgument(arguments, key: "redactedHandle")
        let vault = openVault()
        let source = try vault.entry(handle: handle)
        guard source.kind == .redacted else { throw MCPVaultToolError.notRedacted(handle: handle, kind: source.kind) }
        _ = try vault.mappingFileURL(forHandle: handle)
        guard Self.editSurfaceFormats.contains(source.format) else {
            throw MCPVaultToolError.unsupportedEditFormat(handle: handle, format: source.format)
        }
        // These details are passed only to the local picker, never to the wire.
        let entries = try vault.list()
        var ancestor = source
        for _ in 0..<entries.count {
            guard let parent = ancestor.sourceHandle,
                  let found = entries.first(where: { $0.handle == parent }) else { break }
            ancestor = found
        }
        let selected: URL?
        #if DEBUG
        if let selectEditedDocumentForTesting { selected = try selectEditedDocumentForTesting(source) }
        else { selected = try MCPLocalHandoff.selectEditedDocument(source: source, filename: ancestor.originalFilename) }
        #else
        selected = try MCPLocalHandoff.selectEditedDocument(source: source, filename: ancestor.originalFilename)
        #endif
        guard let selected else { return ["status": "cancelled", "redactedHandle": handle] }
        guard selected.isFileURL, Self.editSurfaceFormats.contains(selected.pathExtension.lowercased()) else {
            throw MCPVaultToolError.unsupportedEditFormat(handle: handle, format: "unsupported")
        }
        // Word sources must stay Word so the picker cannot silently flatten the agreement.
        guard source.format != "docx" || selected.pathExtension.lowercased() == "docx" else {
            throw MCPVaultToolError.wordEditRequired
        }
        let accessing = selected.startAccessingSecurityScopedResource()
        defer { if accessing { selected.stopAccessingSecurityScopedResource() } }

        let operation: (@escaping (VaultStagingPhase) throws -> Void) throws -> VaultEntry = { progress in
            // Snapshot before validation. A user saving in Word while importing
            // cannot change the validated bytes before they are registered.
            let pending = vault.localPreparationVault()
            defer { try? FileManager.default.removeItem(at: pending.rootDirectory) }
            let snapshot = try pending.stage(fileURL: selected, stagedAtISO8601: Self.iso8601Now()) { phase in
                try progress(phase == .registering ? .encrypting : phase)
            }
            return try pending.withPlaintextFileURL(handle: snapshot.handle) { url in
                try progress(.reading)
                if snapshot.format == "docx" {
                    let changes = try DocxImporter().unresolvedTrackedChangeCount(url)
                    guard changes == 0 else { throw MCPVaultToolError.unresolvedTrackedChanges(changes) }
                } else {
                    _ = try TextDocumentIO().importDocument(url)
                }
                return try vault.stage(fileURL: url, stagedAtISO8601: Self.iso8601Now(),
                    originalFilename: selected.lastPathComponent, editingSourceHandle: handle, progress: progress)
            }
        }
        let edited: VaultEntry
        #if DEBUG
        if let runEditedImportForTesting { edited = try runEditedImportForTesting(operation) }
        else { edited = try MCPLocalHandoff.runImport(operation) }
        #else
        edited = try MCPLocalHandoff.runImport(operation)
        #endif
        return ["status": "completed", "editedHandle": edited.handle, "redactedHandle": handle,
                "format": edited.format, "kind": edited.kind.rawValue,
                "trackedChanges": edited.format == "docx" ? "none_detected" : "not_applicable",
                "trackedChangePolicy": "resolve_in_word_before_import", "localConfirmation": true]
    }
}
