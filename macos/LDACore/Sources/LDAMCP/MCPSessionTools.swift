//
//  MCPSessionTools.swift
//  LDAMCP
//
//  Tool implementation for the multi-document session tool:
//  anonymize_session. Several staged documents run as ONE session sharing ONE
//  mapping (R12/R19): the same value keeps the same placeholder across the
//  set. Each document gets its own redacted artifact handle; the session
//  writes one encrypted sidecar, kept inside the vault, that restores the
//  whole set through any member's handle.
//
//  Handle-first: the arguments are vault handles, never paths, and the
//  response carries handles, aggregate counts, and the seam warning below. The
//  optional client label is INBOUND seeding data (it selects which stored
//  identities to reuse) and is never echoed back.
//
//  unresolvedSeams is the one non-aggregate thing that rides out: the sites
//  this session would restore to the WRONG party. It has to, because the
//  redacted artifacts and the sidecar are written and look ordinary, so an
//  agent has no other way to learn the set is unsafe. Its lines are rewritten
//  in the caller's own vocabulary first; see handleScopedSeamLines.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import LDACore

// MARK: - Testing seam

extension MCPServer {
#if DEBUG
    /// Debug-only injection of a custom client mapping root. Production uses
    /// ClientMappingStore's Application Support default. Tests point this at a
    /// hermetic temp directory before exercising anonymize_session with a
    /// client label, and clear it in defer.
    ///
    /// Compiled out of release builds and lock guarded; see TestSeam. Without
    /// it a test that seeds a carried-in matter would have to write into the
    /// real user's client store, which is the one place a test must never
    /// touch.
    internal static let clientStoreSeam = TestSeam<URL>()

    internal static var clientStoreRootForTesting: URL? {
        get { clientStoreSeam.value }
        set { clientStoreSeam.value = newValue }
    }
#endif

    /// The client mapping root the session tool should use: the debug seam when
    /// a test installed one, otherwise nil so ClientMappingStore picks its own
    /// Application Support default. Release builds always return nil.
    static var effectiveClientStoreRoot: URL? {
#if DEBUG
        return clientStoreRootForTesting
#else
        return nil
#endif
    }
}

// MARK: - Session tool handler (extension on MCPServer)

extension MCPServer {

    /// anonymize_session: run LDAService.anonymizeSession over the staged
    /// documents and register one redacted artifact per input plus one shared
    /// session sidecar.
    func callAnonymizeSessionHandles(_ arguments: [String: Any]) throws -> [String: Any] {
        guard
            let handles = arguments["handles"] as? [String],
            !handles.isEmpty
        else {
            throw MCPToolError.missingArgument("handles")
        }
        let modelPath = try allowedModelPath(arguments, key: "modelPath")
        // excludeTypes only: per-entity ids are single-document by
        // construction, and the parser refuses them here explicitly.
        let review = try MCPReviewArguments.parse(arguments, allowsEntityIds: false)
        let vault = openVault()

        // Validate every handle up front so no work happens on a bad set.
        for handle in handles {
            let entry = try vault.entry(handle: handle)
            guard entry.kind == .original else {
                throw MCPVaultToolError.notAnOriginal(handle)
            }
        }

        // Client seeding (R10): when a client label is given, reuse and extend
        // that client's stored identities. The client file uses the same
        // protection choice as the session sidecar.
        let clientLabel = (arguments["client"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var clientStore: ClientMappingStore?
        var clientProtection: MappingProtection?
        var seed: Mapping?
        if let clientLabel {
            let store = try ClientMappingStore(
                rootDirectory: MCPServer.effectiveClientStoreRoot
            )
            let protection: MappingProtection
            if let passphrase = arguments["passphrase"] as? String, !passphrase.isEmpty {
                protection = .passphrase(passphrase)
            } else {
                protection = ClientMappingStore.defaultProtection(label: clientLabel)
            }
            seed = try store.load(label: clientLabel, protection: protection)
            clientStore = store
            clientProtection = protection
        }

        let createdAt = MCPServer.iso8601Now()
        let style = try styleArgument(from: arguments)
        // The scratch filenames are captured INSIDE the closure: the URLs must
        // not outlive it, and only the opaque names are kept, purely so the
        // seam lines can be rewritten in terms of the caller's handles below.
        let (session, scratchNames) = try vault.withPlaintextFileURLs(handles: handles) { inputs in
            let result = try LDAService.anonymizeSession(
                inputs: inputs,
                createdAtISO8601: createdAt,
                llmModelPath: modelPath,
                seedMapping: seed,
                style: style,
                excludedTypes: review.excludedTypes
            )
            return (result, inputs.map { $0.lastPathComponent })
        }

        if let clientLabel, let clientStore, let clientProtection {
            try clientStore.save(session.mapping, label: clientLabel, protection: clientProtection)
        }

        // One redacted slot per document; the shared sidecar lives in the
        // FIRST slot's directory and every session entry points at it. The
        // Keychain account (when no passphrase protects the sidecar) derives
        // from the first slot's opaque handle for all members.
        var slots: [DocumentVault.DerivedSlot] = []
        var committedHandles = Set<String>()
        do {
            for _ in session.documents {
                slots.append(try vault.prepareDerived(kind: .redacted))
            }
            guard let firstSlot = slots.first else {
                throw MCPToolError.missingArgument("handles")
            }
            let mappingURL = firstSlot.directory.appendingPathComponent("session.ldamap")
            let protection = vaultMappingProtection(from: arguments, accountBase: firstSlot.handle)
            try MappingStore.save(session.mapping, to: mappingURL, protection: protection)

            var documents: [[String: Any]] = []
            var allSpans: [Span] = []
            for (index, output) in session.documents.enumerated() {
                let slot = slots[index]
                let redactedURL = slot.directory.appendingPathComponent("original_redacted.md")
                try CompanionWriter.writeText(output.redactedMarkdown, to: redactedURL)
                let committed = try vault.commit(
                    slot: slot,
                    primaryFile: redactedURL,
                    stagedAtISO8601: createdAt,
                    sourceHandle: handles[index],
                    mappingFile: mappingURL,
                    mappingAccountBase: firstSlot.handle,
                    excludedEntityCount: output.excludedEntityCount
                )
                committedHandles.insert(slot.handle)
                documents.append([
                    "handle": handles[index],
                    "redactedHandle": committed.handle,
                    "entityCount": output.entityCount
                ])
                allSpans.append(contentsOf: output.entities)
            }

            return [
                "documents": documents,
                "totalEntityCount": allSpans.count,
                "entityTypes": entityTypeStrings(allSpans),
                "perTypeCounts": MCPServer.perTypeCounts(allSpans),
                // How many detected OCCURRENCES excludeTypes left visible
                // across the whole session. An excluded type is visible in
                // every document and every part, so this is the blast radius.
                "excludedCount": session.documents.reduce(0) { $0 + $1.excludedEntityCount },
                // Sites this session would restore to a DIFFERENT party's real
                // name. Empty in the ordinary case. Non-empty means the
                // artifacts above are written, look finished, and must not be
                // relied on: nothing later in the round trip catches this.
                "unresolvedSeams": MCPServer.handleScopedSeamLines(
                    session.unresolvedSeams,
                    scratchNames: scratchNames,
                    handles: handles
                )
            ]
        } catch {
            // Discard only the slots that never made it into the registry; a
            // committed entry stays valid and keeps its files (including the
            // shared sidecar in the first slot, which committed entries may
            // reference).
            for slot in slots where !committedHandles.contains(slot.handle) {
                vault.abort(slot: slot)
            }
            throw error
        }
    }
}

// MARK: - Seam lines at the boundary

extension MCPServer {

    /// Rewrite the engine's seam lines so they name the caller's handles.
    ///
    /// Each line begins with SessionDocument.name, which on this path is the
    /// lastPathComponent of a vault scratch plaintext file
    /// (pt_<pid>_<hex>.<ext>, see DocumentVaultEncryption.withScratchPlaintext).
    /// That name derives nothing from the user's own filename, so no document
    /// name can leak through it, which matters because a PRC legal filename is
    /// itself PII. It is still the wrong word to hand back: it carries the host
    /// PID, and it names a file the caller can neither see nor act on.
    ///
    /// So every occurrence is replaced by the handle the caller passed for that
    /// document, the identifier already sitting in the response's documents
    /// array. Replacing every occurrence rather than only the leading one keeps
    /// this total: whatever the engine's line format becomes, no scratch name
    /// survives it. Scratch names are long random strings, so there is no
    /// realistic collision with the rest of a line.
    ///
    /// What remains in a line is replacement strings, which are boundary-safe
    /// for the same reason restore's ambiguousReplacements are: they are what
    /// the redacted text already shows.
    static func handleScopedSeamLines(
        _ seams: [String],
        scratchNames: [String],
        handles: [String]
    ) -> [String] {
        guard !seams.isEmpty else { return [] }
        let renames = Array(zip(scratchNames, handles))
        return seams.map { line in
            renames.reduce(line) { partial, rename in
                partial.replacingOccurrences(of: rename.0, with: rename.1)
            }
        }
    }
}
