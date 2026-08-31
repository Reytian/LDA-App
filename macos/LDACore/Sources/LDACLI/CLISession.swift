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
    /// Sites that would restore to the WRONG entity, one readable line each.
    ///
    /// Empty in every normal run. Non-empty means the redacted files and the
    /// sidecar were still written, but restoring them puts a different
    /// party's name at one of these sites. Reported, never repaired here:
    /// the engine already tried every remint available to it.
    public let unresolvedSeams: [String]
}

// MARK: - Session helpers

extension LDACLI {

    /// Resolve the raw --input URLs into session inputs: every .zip expands
    /// into its supported documents; everything else must exist and passes
    /// through unchanged.
    /// Expanded archives are registered with ZipImporter, so the CALLER must
    /// call ZipImporter.cleanUpAllExpansions() once the session has finished
    /// with the returned URLs. The expansion holds the user's original,
    /// un-redacted documents; it cannot be cleaned here because the caller has
    /// not read them yet.
    public static func resolveSessionInputs(_ raw: [URL]) throws -> [URL] {
        var resolved: [URL] = []
        for url in raw {
            try requireExists(url)
            if ZipImporter.isZip(url) {
                resolved.append(contentsOf: try ZipImporter.expand(url).documents)
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
            totalEntityCount: session.documents.reduce(0) { $0 + $1.entityCount },
            unresolvedSeams: session.unresolvedSeams
        )
    }

    /// The stderr advisory for a session the seam pass could not clean up.
    ///
    /// The JSON summary already carries these lines, but a field in a JSON
    /// blob is exactly how this defect stayed invisible, so the terminal gets
    /// it in plain words too. Says the consequence first: the files look
    /// finished and nothing downstream can tell a mis-restore from a correct
    /// one, so the only place this can be caught is here.
    ///
    /// Returns nil when the session is clean, which is the ordinary case.
    public static func unresolvedSeamNotice(for seams: [String]) -> String? {
        guard !seams.isEmpty else { return nil }
        let subject = seams.count == 1
            ? "1 redacted site"
            : "\(seams.count) redacted sites"
        let sites = seams.count == 1 ? "that site" : "those sites"
        let detail = seams.map { "  \($0)" }.joined(separator: "\n")
        return "Warning: \(subject) in this session would restore to the WRONG party.\n"
            + detail + "\n"
            + "The redacted files and the mapping sidecar were still written and "
            + "look ordinary, so nothing later in the round trip will catch this: "
            + "restoring puts a different party's name at \(sites). Most often the "
            + "cause is a --client profile whose saved identities were minted under "
            + "a different --style; re-run with that style, or without --client, and "
            + "read the restored text before you rely on it.\n"
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
