//
//  MCPSessionTools.swift
//  LDAMCP
//
//  Tool implementation for the multi-document session tool:
//  anonymize_session. Several inputs (and any .zip, which expands into the
//  session) run as ONE session sharing ONE mapping (R12/R19). Each document
//  writes a redacted Markdown intermediate; the session writes one encrypted
//  sidecar that restores the whole set.
//
//  Follows the MCPFillTools precedent: summaries are [String: Any]
//  dictionaries, and argument validation is self-contained.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import LDACore

// MARK: - Session tool handler (extension on MCPServer)

extension MCPServer {

    /// anonymize_session: run LDAService.anonymizeSession over the inputs and
    /// write per-document Markdown intermediates plus one session sidecar.
    func callAnonymizeSession(_ arguments: [String: Any]) throws -> [String: Any] {
        guard
            let rawInputs = arguments["inputs"] as? [String],
            !rawInputs.isEmpty
        else {
            throw MCPFillToolError.missingOrEmptyArgument("inputs")
        }
        let outputDirPath = try requireStringArgument(arguments, key: "outputDir")
        let outputDir = try allowedURL(outputDirPath, key: "outputDir")

        // Expand any .zip inputs into the session. The expansion holds the
        // user's original documents in a temp directory; it is removed at the
        // end of this request, once the session has been written out.
        defer { ZipImporter.cleanUpAllExpansions() }
        var inputs: [URL] = []
        for raw in rawInputs {
            let url = try allowedURL(raw, key: "inputs")
            if ZipImporter.isZip(url) {
                inputs.append(contentsOf: try ZipImporter.expand(url).documents)
            } else {
                inputs.append(url)
            }
        }

        let modelPath = (arguments["modelPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let createdAt = MCPServer.iso8601Now()

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

        let session = try LDAService.anonymizeSession(
            inputs: inputs,
            createdAtISO8601: createdAt,
            llmModelPath: modelPath,
            seedMapping: seed
        )

        if let clientLabel, let clientStore, let clientProtection {
            try clientStore.save(session.mapping, label: clientLabel, protection: clientProtection)
        }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Per-document Markdown intermediates; duplicate base names get a
        // numeric suffix instead of overwriting.
        var documents: [[String: Any]] = []
        var usedNames = Set<String>()
        for output in session.documents {
            let base = output.sourceURL.deletingPathExtension().lastPathComponent
            let url = uniqueSessionURL(in: outputDir, base: "\(base)_redacted", ext: "md", used: &usedNames)
            try CompanionWriter.writeText(output.redactedMarkdown, to: url)
            documents.append([
                "sourceFile": output.sourceURL.path,
                "redactedFile": url.path,
                "entityCount": output.entityCount
            ])
        }

        // One encrypted sidecar restores the whole session.
        guard let first = inputs.first else {
            throw MCPFillToolError.missingOrEmptyArgument("inputs")
        }
        let mappingBase = "\(first.deletingPathExtension().lastPathComponent)_session"
        let mappingURL = uniqueSessionURL(in: outputDir, base: mappingBase, ext: "ldamap", used: &usedNames)
        let protection: MappingProtection
        if let passphrase = arguments["passphrase"] as? String, !passphrase.isEmpty {
            protection = .passphrase(passphrase)
        } else {
            let account = MCPServer.keychainAccount(
                forMappingBaseName: mappingURL.deletingPathExtension().lastPathComponent
            )
            protection = .keychain(account: account)
        }
        try MappingStore.save(session.mapping, to: mappingURL, protection: protection)

        return [
            "documents": documents,
            "mappingFile": mappingURL.path,
            "totalEntityCount": session.documents.reduce(0) { $0 + $1.entityCount }
        ]
    }

    /// The first free URL of the form base.ext, base-2.ext in the directory,
    /// also honoring names taken earlier in this call.
    private func uniqueSessionURL(
        in directory: URL,
        base: String,
        ext: String,
        used: inout Set<String>
    ) -> URL {
        var candidateBase = base
        var counter = 1
        while true {
            let name = "\(candidateBase).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !used.contains(name) && !FileManager.default.fileExists(atPath: url.path) {
                used.insert(name)
                return url
            }
            counter += 1
            candidateBase = "\(base)-\(counter)"
        }
    }
}
