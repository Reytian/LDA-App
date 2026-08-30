//
//  MCPVaultTools.swift
//  LDAMCP
//
//  The handle-first tool surface over the staging vault. Everything a tool
//  RETURNS enters the model context of the agent host and leaves the machine,
//  so this surface is built around a hard boundary:
//
//   ALLOWED out:  opaque handles, redacted text (read_redacted only),
//                 aggregate type and count stats, neutral metadata (format,
//                 byte count, page count, staged-at), placeholder tokens,
//                 error codes plus handles.
//   FORBIDDEN:    original text, detected entity surface text, filesystem
//                 paths and original filenames, client or matter labels,
//                 mapping contents, error messages that echo content or paths.
//
//  Paths never appear in these tools' arguments either, with one deliberate
//  exception: modelPath points at a GGUF the human configured, not at client
//  data, and stays gated by MCPPathPolicy.enforceModelPath.
//
//  Accepted disclosure, per the boundary spec's tool table: detect_entities
//  returns per-entity character OFFSETS, which reveal each original surface's
//  exact length and position (a weak side channel). The spec chose offsets so
//  a local caller can slice the text itself; anything finer than type plus
//  offsets stays on the machine.
//
//  Every error thrown here is rendered by describeBoundarySafe, which maps
//  each failure to error-code-plus-handle wording and never interpolates a
//  detail string that could carry a path.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import LDACore

// MARK: - Session metrics

/// Per-server-instance counters surfaced by the attest tool. A reference type
/// so the value-typed server can accumulate across calls; lock guarded because
/// nothing else serializes access.
final class MCPSessionMetrics: @unchecked Sendable {

    private let lock = NSLock()
    private var plaintextBytesReturned = 0
    private var redactedBytesReturned = 0
    private var toolCallCounts: [String: Int] = [:]

    /// Record that ORIGINAL-document bytes were emitted in a response. No tool
    /// calls this today, which is the point: the attest counter it feeds can
    /// only ever report zero, and a future tool that did emit original bytes
    /// would have to announce itself here to be counted at all.
    func notePlaintextBytesReturned(_ count: Int) {
        lock.withLock { plaintextBytesReturned += count }
    }

    /// Record redacted text bytes emitted by read_redacted.
    func noteRedactedBytesReturned(_ count: Int) {
        lock.withLock { redactedBytesReturned += count }
    }

    /// Count one dispatched tool call. Only known tool names are counted, so
    /// attest never echoes an arbitrary string a client sent as a name.
    func noteToolCall(_ name: String) {
        lock.withLock { toolCallCounts[name, default: 0] += 1 }
    }

    struct Snapshot {
        let plaintextBytesReturned: Int
        let redactedBytesReturned: Int
        let toolCallCounts: [String: Int]
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                plaintextBytesReturned: plaintextBytesReturned,
                redactedBytesReturned: redactedBytesReturned,
                toolCallCounts: toolCallCounts
            )
        }
    }
}

// MARK: - Vault tool errors

/// Kind mismatches raised at the MCP edge. Messages carry an error code and a
/// handle only.
enum MCPVaultToolError: Error {
    /// The tool needs a staged original and the handle is something else.
    case notAnOriginal(String)
    /// The tool needs a redacted artifact and the handle is something else.
    /// read_redacted refuses originals AND restored artifacts through this:
    /// both contain real PII.
    case notRedacted(handle: String, kind: VaultArtifactKind)
    /// The artifact's stored bytes are not UTF-8 text.
    case unreadableArtifact(String)

    var message: String {
        switch self {
        case .notAnOriginal(let handle):
            return "not_an_original: \(handle) does not refer to a staged source document"
        case .notRedacted(let handle, let kind):
            return "not_redacted: \(handle) refers to a \(kind.rawValue) artifact; "
                + "this tool accepts redacted artifacts only"
        case .unreadableArtifact(let handle):
            return "unreadable_artifact: \(handle) could not be decoded as text"
        }
    }
}

// MARK: - Vault tool handlers (extension on MCPServer)

extension MCPServer {

    /// The vault this server operates on: LDA_VAULT_DIR from the launch
    /// environment when set, else Application Support/LDA/Vault. The
    /// environment is the launcher's, never a request's.
    func openVault() -> DocumentVault {
        DocumentVault(environment: environment)
    }

    // MARK: list_pending

    /// list_pending: every staged document and derived artifact, as neutral
    /// metadata plus handles. NO filenames, NO paths.
    func callListPending() throws -> [String: Any] {
        let entries = try openVault().list()
        let documents: [[String: Any]] = entries.map { entry in
            var item: [String: Any] = [
                "handle": entry.handle,
                "kind": entry.kind.rawValue,
                "format": entry.format,
                "byteCount": entry.byteCount,
                "stagedAt": entry.stagedAtISO8601
            ]
            if let pages = entry.pageCount {
                item["pages"] = pages
            }
            if let source = entry.sourceHandle {
                item["sourceHandle"] = source
            }
            return item
        }
        return ["documents": documents]
    }

    // MARK: anonymize

    /// anonymize: run the pipeline over a staged original and register the
    /// redacted artifact (plus its encrypted mapping sidecar) in the vault.
    /// The response carries the new handle and aggregate counts only.
    func callAnonymizeHandle(_ arguments: [String: Any]) throws -> [String: Any] {
        let handle = try requireStringArgument(arguments, key: "handle")
        let modelPath = try allowedModelPath(arguments, key: "modelPath")
        let vault = openVault()
        let entry = try vault.entry(handle: handle)
        guard entry.kind == .original else {
            throw MCPVaultToolError.notAnOriginal(handle)
        }

        let slot = try vault.prepareDerived(kind: .redacted)
        do {
            // The mapping key derives from the redacted handle: opaque,
            // deterministic, and per-document (one shared key would be a
            // single point of failure for every sidecar).
            let protection = vaultMappingProtection(from: arguments, accountBase: slot.handle)
            let createdAt = MCPServer.iso8601Now()
            let style = try styleArgument(from: arguments)
            let result = try vault.withPlaintextFileURL(handle: handle) { inputURL in
                try LDAService.anonymize(
                    input: inputURL,
                    outputDir: slot.directory,
                    protection: protection,
                    createdAtISO8601: createdAt,
                    llmModelPath: modelPath,
                    style: style
                )
            }
            let committed = try vault.commit(
                slot: slot,
                primaryFile: result.redactedFileURL,
                stagedAtISO8601: createdAt,
                sourceHandle: handle,
                mappingFile: result.mappingFileURL,
                mappingAccountBase: slot.handle
            )
            return [
                "redactedHandle": committed.handle,
                "entityCount": result.entityCount,
                "entityTypes": entityTypeStrings(result.entities),
                "perTypeCounts": MCPServer.perTypeCounts(result.entities),
                "imageRedactionCount": result.imageRedactionCount,
                "embeddedMediaCount": result.embeddedMediaCount,
                "unboxedTokenCount": result.unboxedTokenCount
            ]
        } catch {
            vault.abort(slot: slot)
            throw error
        }
    }

    // MARK: read_redacted

    /// read_redacted: the ONE tool allowed to return body text, and only for
    /// redacted artifacts. Originals and restored artifacts are refused: both
    /// contain real PII. The returned byte count feeds the attest counter.
    func callReadRedacted(_ arguments: [String: Any]) throws -> [String: Any] {
        let handle = try requireStringArgument(arguments, key: "handle")
        let vault = openVault()
        let entry = try vault.entry(handle: handle)
        guard entry.kind == .redacted else {
            throw MCPVaultToolError.notRedacted(handle: handle, kind: entry.kind)
        }

        let text: String
        if entry.format == "docx" {
            // The redacted docx is an edit surface; its imported text is the
            // tokenized body, which is exactly what the caller may see.
            text = try vault.withPlaintextFileURL(handle: handle) { url in
                try DocxImporter().importDocument(url).text
            }
        } else {
            let bytes = try vault.readDocumentBytes(handle: handle)
            guard let decoded = String(data: bytes, encoding: .utf8) else {
                throw MCPVaultToolError.unreadableArtifact(handle)
            }
            text = decoded
        }

        metrics.noteRedactedBytesReturned(Data(text.utf8).count)
        return ["handle": handle, "text": text]
    }

    // MARK: detect_entities

    /// detect_entities: types, counts, and offsets only, never span text.
    /// Everything a tool returns enters the model context of whatever agent
    /// host launched this server, so returning the detected surface text
    /// would upload the exact bytes this product exists to keep local.
    func callDetectHandle(_ arguments: [String: Any]) throws -> [String: Any] {
        let handle = try requireStringArgument(arguments, key: "handle")
        let modelPath = try allowedModelPath(arguments, key: "modelPath")
        let spans = try openVault().withPlaintextFileURL(handle: handle) { url in
            try LDAService.detect(input: url, llmModelPath: modelPath)
        }

        let entities: [[String: Any]] = spans.map { span in
            [
                "type": span.type.rawValue,
                "start": span.start,
                "end": span.end
            ]
        }
        return [
            "entityCount": spans.count,
            "entityTypes": entityTypeStrings(spans),
            "entities": entities
        ]
    }

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

    // MARK: export

    /// export: copy a redacted or restored artifact to the vault's outbox, a
    /// fixed human-known location. The MODEL never chooses a destination; the
    /// response says only that it happened.
    func callExport(_ arguments: [String: Any]) throws -> [String: Any] {
        let handle = try requireStringArgument(arguments, key: "handle")
        // The returned outbox URL is for human-facing edges; it must not
        // enter this response.
        _ = try openVault().exportToOutbox(handle: handle)
        return ["ok": true]
    }

    // MARK: attest

    /// attest: the server's honest self-description. Every field is derived
    /// from actual state, never hardcoded: vaultEncryptionAtRest reads the
    /// on-disk form (false while an unmigrated plaintext registry exists) and
    /// vaultKeyProtection names how the vault master key is actually held
    /// (the XPC phase will introduce a new value there).
    func callAttest() -> [String: Any] {
        let vault = openVault()
        let snapshot = metrics.snapshot()
        return [
            "vaultEncryptionAtRest": vault.isEncryptionAtRestActive(),
            "vaultKeyProtection": vault.keyProtectionDescription,
            "keyACLMode": KeychainAccessPolicy.requireUserPresence ? "userPresence" : "silent",
            "plaintextBytesReturnedThisSession": snapshot.plaintextBytesReturned,
            "redactedBytesReturnedThisSession": snapshot.redactedBytesReturned,
            "toolCallCounts": snapshot.toolCallCounts
        ]
    }

    // MARK: Shared helpers

    /// Protection for a vault mapping sidecar: an explicit passphrase from the
    /// request, else a Keychain key under an account derived from the given
    /// opaque handle base.
    func vaultMappingProtection(
        from arguments: [String: Any],
        accountBase: String
    ) -> MappingProtection {
        if let passphrase = arguments["passphrase"] as? String, !passphrase.isEmpty {
            return .passphrase(passphrase)
        }
        return .keychain(account: MCPServer.keychainAccount(forMappingBaseName: accountBase))
    }

    /// Count spans per entity type for the aggregate stats the boundary allows.
    static func perTypeCounts(_ spans: [Span]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for span in spans {
            counts[span.type.rawValue, default: 0] += 1
        }
        return counts
    }

    // MARK: Boundary-safe error rendering

    /// Render any error from the handle-first tools as error kind plus handle
    /// only. This is the leak-channel-5 gate: DocumentIOError details, path
    /// policy messages, and String(describing:) fallbacks can all embed
    /// filesystem paths, so none of them pass through verbatim.
    func describeBoundarySafe(_ error: Error) -> String {
        switch error {
        case let vaultToolError as MCPVaultToolError:
            return vaultToolError.message
        case let vaultError as DocumentVaultError:
            return vaultError.message
        case let toolError as MCPToolError:
            return toolError.message
        case let fillToolError as MCPFillToolError:
            // Only the missing-argument case is reachable from this surface;
            // its message names an argument key, never a path.
            return fillToolError.message
        case let pathError as MCPPathPolicyError:
            return MCPServer.describeBoundarySafe(pathError)
        case let serviceError as LDAServiceError:
            return MCPServer.describeBoundarySafe(serviceError)
        case let ioError as DocumentIOError:
            return MCPServer.describeBoundarySafe(ioError)
        default:
            // The type name only. String(describing: error) can interpolate
            // associated values, and those regularly carry paths.
            return "unexpected_error: \(String(describing: type(of: error)))"
        }
    }

    /// Path policy refusals without echoing the offending path. The path came
    /// from the request, so the client already has it; repeating it back adds
    /// nothing and would fail the no-paths-on-the-wire rule.
    private static func describeBoundarySafe(_ error: MCPPathPolicyError) -> String {
        switch error {
        case .outsideAllowedRoots(let argumentKey, _):
            return "Argument \(argumentKey) points outside the allowed directories. "
                + "Set \(MCPPathPolicy.extraRootsEnvironmentKey) when launching the "
                + "server to allow additional locations."
        case .modelOutsideAllowedRoots(let argumentKey, _):
            return "Argument \(argumentKey) points outside the allowed directories "
                + "for GGUF models. Model files are read from your home directory, "
                + "the system temporary directory, or the app bundle's Resources "
                + "directory. Set \(MCPPathPolicy.extraRootsEnvironmentKey) when "
                + "launching the server to allow additional locations."
        }
    }

    /// Service failures reworded without any caller-supplied detail string.
    private static func describeBoundarySafe(_ error: LDAServiceError) -> String {
        switch error {
        case .incompleteExtraction(let count):
            return "incomplete_extraction: \(count) segment(s) could not be fully "
                + "scanned, so no redacted artifact was written (a partial scan "
                + "must not be presented as clean)."
        case .unanchoredEntities(let count):
            return "unanchored_entities: \(count) detected value(s) could not be "
                + "matched exactly in the text, so no redacted artifact was "
                + "written (it would still contain them)."
        case .outputEqualsInput:
            return "output_equals_input: the output would overwrite the input."
        case .noReadableSources:
            return "no_readable_sources: the document could not be read as text."
        case .staleTarget:
            return "stale_target: the target changed since the plan was produced."
        }
    }

    /// IO failures with every detail payload dropped: the details regularly
    /// name files and paths.
    private static func describeBoundarySafe(_ error: DocumentIOError) -> String {
        switch error {
        case .unreadable:
            return "unreadable: the document could not be read."
        case .unsupportedFormat:
            return "unsupported_format: the document format is not supported."
        case .corrupt:
            return "corrupt: the document is structurally corrupt."
        case .ocrUnavailable:
            return "ocr_unavailable: OCR is unavailable on this system."
        case .decryptionFailed:
            return "decryption_failed: wrong passphrase or tampered mapping."
        case .keychainError(let status):
            return "keychain_error: status \(status)."
        case .tooLarge:
            return "too_large: the input exceeds the import size limits."
        }
    }
}
