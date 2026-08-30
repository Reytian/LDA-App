//
//  CLISession.swift
//  LDACLI
//
//  The session half of the anonymize subcommand: several --input documents
//  (and any .zip, which expands into the session) run as ONE session sharing
//  ONE mapping. Each document writes a redacted Markdown intermediate
//  (<base>_redacted.md); the session writes a single encrypted sidecar
//  (<firstBase>_session.ldamap) that restores every document in the set.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import LDACore

// MARK: - JSON summary

/// The JSON summary printed by the anonymize subcommand in session mode.
public struct SessionSummaryJSON: Codable, Equatable {
    public struct DocumentJSON: Codable, Equatable {
        public let sourceFile: String
        public let redactedFile: String
        public let entityCount: Int
    }

    public let documents: [DocumentJSON]
    public let mappingFile: String
    public let totalEntityCount: Int
}

// MARK: - Session helpers

extension LDACLI {

    /// Resolve the raw --input URLs into session inputs: every .zip expands
    /// into its supported documents; everything else must exist and passes
    /// through unchanged.
    public static func resolveSessionInputs(_ raw: [URL]) throws -> [URL] {
        var resolved: [URL] = []
        for url in raw {
            try requireExists(url)
            if ZipImporter.isZip(url) {
                resolved.append(contentsOf: try ZipImporter.expand(url))
            } else {
                resolved.append(url)
            }
        }
        return resolved
    }

    /// Session anonymize core: run the whole set against one shared mapping,
    /// write per-document Markdown intermediates plus the single session
    /// sidecar, and return the printable summary.
    ///
    /// When clientLabel is given, the session seeds from that client's stored
    /// mapping and saves the union back (R10): the same client's entities keep
    /// the same placeholders across sessions. The client file uses the same
    /// protection choice as the session sidecar (the given passphrase, or its
    /// own derived Keychain account).
    public static func runAnonymizeSession(
        inputs: [URL],
        outputDir: URL,
        passphrase: String?,
        llmModelPath: String? = nil,
        clientLabel: String? = nil,
        clientStore: ClientMappingStore? = nil,
        style: SubstitutionStyle = .token,
        timestamp: TimestampProvider = defaultTimestampProvider
    ) throws -> SessionSummaryJSON {
        guard let first = inputs.first else {
            throw CLIError.inputNotFound("no readable session inputs")
        }
        for input in inputs {
            try requireExists(input)
        }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // Client seeding (R10): load the client's stored mapping, if any.
        var store: ClientMappingStore?
        var clientProtection: MappingProtection?
        var seed: Mapping?
        if let clientLabel {
            let resolved = try clientStore ?? ClientMappingStore()
            let protection: MappingProtection = passphrase.flatMap {
                $0.isEmpty ? nil : .passphrase($0)
            } ?? ClientMappingStore.defaultProtection(label: clientLabel)
            seed = try resolved.load(label: clientLabel, protection: protection)
            store = resolved
            clientProtection = protection
        }

        let session = try LDAService.anonymizeSession(
            inputs: inputs,
            createdAtISO8601: timestamp(),
            llmModelPath: llmModelPath,
            seedMapping: seed,
            style: style
        )

        // Save the union back so the client's next session keeps these
        // identities.
        if let clientLabel, let store, let clientProtection {
            try store.save(session.mapping, label: clientLabel, protection: clientProtection)
        }

        // Write each document's redacted Markdown intermediate. Duplicate base
        // names get a numeric suffix instead of overwriting.
        var documents: [SessionSummaryJSON.DocumentJSON] = []
        var usedNames = Set<String>()
        for output in session.documents {
            let base = output.sourceURL.deletingPathExtension().lastPathComponent
            let url = uniqueOutputURL(
                in: outputDir,
                base: "\(base)_redacted",
                ext: "md",
                used: &usedNames
            )
            try CompanionWriter.writeText(output.redactedMarkdown, to: url)
            documents.append(
                SessionSummaryJSON.DocumentJSON(
                    sourceFile: output.sourceURL.path,
                    redactedFile: url.path,
                    entityCount: output.entityCount
                )
            )
        }

        // One encrypted sidecar restores the whole session. The Keychain
        // account derives from the sidecar base name with the usual prefix.
        let mappingBase = "\(first.deletingPathExtension().lastPathComponent)_session"
        var mappingNames = Set<String>()
        let mappingURL = uniqueOutputURL(
            in: outputDir,
            base: mappingBase,
            ext: "ldamap",
            used: &mappingNames
        )
        let protection = protectionFor(
            passphrase: passphrase,
            derivedAccount: mappingURL.deletingPathExtension().lastPathComponent
        )
        try MappingStore.save(session.mapping, to: mappingURL, protection: protection)

        return SessionSummaryJSON(
            documents: documents,
            mappingFile: mappingURL.path,
            totalEntityCount: session.documents.reduce(0) { $0 + $1.entityCount }
        )
    }

    /// The first free URL of the form base.ext, base-2.ext, base-3.ext in the
    /// directory, also honoring names already taken during this session run.
    private static func uniqueOutputURL(
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
