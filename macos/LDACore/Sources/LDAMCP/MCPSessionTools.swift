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
//  response carries handles and aggregate counts only. The optional client
//  label is INBOUND seeding data (it selects which stored identities to reuse)
//  and is never echoed back.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import LDACore

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
            let store = try ClientMappingStore()
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
        let session = try vault.withPlaintextFileURLs(handles: handles) { inputs in
            try LDAService.anonymizeSession(
                inputs: inputs,
                createdAtISO8601: createdAt,
                llmModelPath: modelPath,
                seedMapping: seed
            )
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
                    mappingAccountBase: firstSlot.handle
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
                "perTypeCounts": MCPServer.perTypeCounts(allSpans)
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
