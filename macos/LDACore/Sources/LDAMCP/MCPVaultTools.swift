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
//  offsets stays on the machine. The per-entity ids and the detectionId it
//  also returns derive from type and offsets only (MCPDetectionIdentity), so
//  they add nothing to that disclosure.
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
    /// excludeEntityIds was given without the detectionId the ids came with.
    case detectionIdRequired
    /// Some excluded ids are not in the detection anonymize just ran: the
    /// caller reviewed a different detection, so nothing was written.
    case unknownEntityId(count: Int)
    /// anonymize_session received excludeEntityIds, which are single-document.
    case entityIdsNotSupportedForSessions
    /// restore's editedHandle named a restored artifact, which holds real
    /// values again and so cannot be an edit surface.
    case notAnEditSurface(String)
    /// restore's editedHandle named an artifact whose format cannot carry
    /// placeholders (an image or a PDF). The format string is the vault's own
    /// normalized vocabulary, never a filename.
    case unsupportedEditFormat(handle: String, format: String)

    var message: String {
        switch self {
        case .notAnOriginal(let handle):
            return "not_an_original: \(handle) does not refer to a staged source document"
        case .notRedacted(let handle, let kind):
            return "not_redacted: \(handle) refers to a \(kind.rawValue) artifact; "
                + "this tool accepts redacted artifacts only"
        case .unreadableArtifact(let handle):
            return "unreadable_artifact: \(handle) could not be decoded as text"
        case .detectionIdRequired:
            return "detection_id_required: pass the detectionId that came with these ids"
        case .unknownEntityId(let count):
            return "unknown_entity_id: count=\(count). Run detect_entities again and "
                + "re-review; no redacted artifact was written."
        case .entityIdsNotSupportedForSessions:
            return "entity_ids_not_supported: anonymize_session accepts excludeTypes only; "
                + "per-entity ids are single-document, so call anonymize per document "
                + "to exclude by id."
        case .notAnEditSurface(let handle):
            return "not_an_edit_surface: \(handle) refers to a restored artifact, which holds "
                + "real values again; pass the edited redacted document instead (a doc_... the "
                + "human staged, or a red_... artifact)"
        case .unsupportedEditFormat(let handle, let format):
            return "unsupported_format: \(handle) is a \(format) artifact and cannot be an edit "
                + "surface; editedHandle accepts docx, txt, or md"
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
    func callAnonymizeHandle(
        _ arguments: [String: Any],
        prepareDerived: (DocumentVault) throws -> DocumentVault.DerivedSlot = {
            try $0.prepareDerived(kind: .redacted)
        },
        withPlaintextSource: (
            DocumentVault,
            String,
            (URL) throws -> AnonymizeResult
        ) throws -> AnonymizeResult = { vault, handle, body in
            try vault.withPlaintextFileURL(handle: handle, body)
        }
    ) throws -> [String: Any] {
        let handle = try requireStringArgument(arguments, key: "handle")
        let modelPath = try allowedModelPath(arguments, key: "modelPath")
        // The review step's arguments are validated before any vault work so
        // a bad type or a missing detectionId costs no detection pass.
        let review = try MCPReviewArguments.parse(arguments, allowsEntityIds: true)
        let vault = openVault()
        let entry = try vault.entry(handle: handle)
        guard entry.kind == .original else {
            throw MCPVaultToolError.notAnOriginal(handle)
        }

        // Run the complete release-gated service operation before reserving a
        // derived slot. The original uses the vault's established scoped
        // plaintext helper, which supplies PID-tagged cleanup and dead-owner
        // recovery. The separate staging directory receives only redacted
        // output and an encrypted mapping. Its temporary passphrase avoids a
        // Keychain item that would outlive a refused run.
        let fileManager = FileManager.default
        let stagingDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "lda-mcp-anonymize-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let stagingOutput = stagingDirectory.appendingPathComponent("output", isDirectory: true)
        let stagingPassphrase = UUID().uuidString + UUID().uuidString
        let createdAt = MCPServer.iso8601Now()
        let style = try styleArgument(from: arguments)
        // The observer rides the engine's spanFilter seam: it sees every body
        // span the run detects (ids only are kept), excludes the ids the
        // caller named, and afterwards tells whether the caller reviewed the
        // detection that actually ran. Excluded TYPES are the engine's job on
        // every channel, including headers, footers, notes, and image text.
        let observer = MCPDetectionObserver(excludedIds: review.excludedIds)
        let stagedResult = try withPlaintextSource(vault, handle) { inputURL in
            try LDAService.anonymize(
                input: inputURL,
                outputDir: stagingOutput,
                protection: .passphrase(stagingPassphrase),
                createdAtISO8601: createdAt,
                llmModelPath: modelPath,
                style: style,
                spanFilter: observer.keep,
                excludedTypes: review.excludedTypes
            )
        }
        // An id the fresh detection does not know means the caller reviewed a
        // different detection. Refuse before any vault state exists: the
        // staging directory above is removed by the defer, so nothing is
        // written. A changed set whose excluded ids are all present proceeds
        // (over-redaction is the safe direction) and is reported below.
        let verdict = observer.verdict(
            handle: handle,
            modelPathPresent: modelPath != nil,
            review: review
        )
        guard verdict.unknownIdCount == 0 else {
            throw MCPVaultToolError.unknownEntityId(count: verdict.unknownIdCount)
        }
        let stagedMapping = try MappingStore.load(
            from: stagedResult.mappingFileURL,
            protection: .passphrase(stagingPassphrase)
        )

        // Only a fully successful, release-safe run may reserve vault state.
        let slot = try prepareDerived(vault)
        do {
            // The mapping key derives from the redacted handle: opaque,
            // deterministic, and per-document (one shared key would be a
            // single point of failure for every sidecar).
            let protection = vaultMappingProtection(from: arguments, accountBase: slot.handle)
            let redactedURL = slot.directory.appendingPathComponent(
                stagedResult.redactedFileURL.lastPathComponent
            )
            try fileManager.moveItem(at: stagedResult.redactedFileURL, to: redactedURL)
            let mappingURL = slot.directory.appendingPathComponent(
                stagedResult.mappingFileURL.lastPathComponent
            )
            try MappingStore.save(stagedMapping, to: mappingURL, protection: protection)
            let committed = try vault.commit(
                slot: slot,
                primaryFile: redactedURL,
                stagedAtISO8601: createdAt,
                sourceHandle: handle,
                mappingFile: mappingURL,
                mappingAccountBase: slot.handle
            )
            return [
                "redactedHandle": committed.handle,
                "entityCount": stagedResult.entityCount,
                "entityTypes": entityTypeStrings(stagedResult.entities),
                "perTypeCounts": MCPServer.perTypeCounts(stagedResult.entities),
                "imageRedactionCount": stagedResult.imageRedactionCount,
                "embeddedMediaCount": stagedResult.embeddedMediaCount,
                "unboxedTokenCount": stagedResult.unboxedTokenCount,
                // The review step's outcome: how many body values the caller
                // left visible, and whether the detection this run made
                // differs from the one the caller reviewed.
                "excludedCount": stagedResult.excludedEntityCount,
                "detectionChanged": verdict.detectionChanged
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

    /// detect_entities: types, counts, offsets, and ids only, never span text.
    /// Everything a tool returns enters the model context of whatever agent
    /// host launched this server, so returning the detected surface text
    /// would upload the exact bytes this product exists to keep local. The
    /// ids let a caller name entities to anonymize's excludeEntityIds; they
    /// derive from type and offsets only, so they disclose nothing new.
    func callDetectHandle(_ arguments: [String: Any]) throws -> [String: Any] {
        let handle = try requireStringArgument(arguments, key: "handle")
        let modelPath = try allowedModelPath(arguments, key: "modelPath")
        let spans = try openVault().withPlaintextFileURL(handle: handle) { url in
            try LDAService.detect(input: url, llmModelPath: modelPath)
        }

        let ids = spans.map { MCPDetectionIdentity.entityId(for: $0) }
        let entities: [[String: Any]] = zip(spans, ids).map { span, id in
            [
                "id": id,
                "type": span.type.rawValue,
                "start": span.start,
                "end": span.end
            ]
        }
        return [
            "detectionId": MCPDetectionIdentity.detectionId(
                handle: handle,
                modelPathPresent: modelPath != nil,
                ids: ids
            ),
            "entityCount": spans.count,
            "entityTypes": entityTypeStrings(spans),
            "entities": entities
        ]
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
        case let releaseError as OutboundReleaseError:
            return MCPServer.describeBoundarySafe(releaseError)
        case let ioError as DocumentIOError:
            return MCPServer.describeBoundarySafe(ioError)
        default:
            // The type name only. String(describing: error) can interpolate
            // associated values, and those regularly carry paths.
            return "unexpected_error: \(String(describing: type(of: error)))"
        }
    }

    /// Masks retain fragments of client values, so the wire response carries
    /// only the stable error code, aggregate count, and safe-style guidance.
    private static func describeBoundarySafe(_ error: OutboundReleaseError) -> String {
        switch error {
        case .ambiguousAsteriskMasks(let masks):
            return "ambiguous_asterisk_masks: count=\(masks.count). "
                + "Switch to Tokens or Pseudonyms before copying or exporting."
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
