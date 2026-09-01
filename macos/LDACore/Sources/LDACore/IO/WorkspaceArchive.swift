//
//  WorkspaceArchive.swift
//  LDACore
//
//  The .ldawork container: one file that holds a matter's whole working state.
//
//  FORMAT, and the reason for it. A workspace file is ONE EncryptedContainer
//  (passphrase derivation only) whose decrypted payload is the bytes of an
//  inner zip. Package first, then encrypt. The reverse arrangement (a plain zip
//  of encrypted members) is not an option here: a zip's central directory
//  stores entry names in PLAINTEXT, and the entry names in this archive are
//  document file names. In PRC legal practice those file names carry the
//  parties' names, so an "encrypted" archive built that way would publish the
//  very thing the app exists to protect, to anyone holding the file.
//
//  Passphrase only, never the Keychain. The whole point of the format is
//  cross-machine handoff: opening one must need nothing but the file and the
//  passphrase, so a colleague's Mac (which has never seen this matter, this
//  Keychain, or this app's stores) can open it.
//
//  One KDF pass protects the whole archive, by construction: the container
//  derives one key and seals one payload. Members are not individually
//  encrypted, which would multiply the PBKDF2 cost by the document count for
//  no additional protection.
//
//  The session mapping travels as its plain Codable JSON INSIDE the zip rather
//  than as a nested MappingStore container. That choice is deliberate: a nested
//  container would either need the Keychain (breaking handoff) or a second
//  600k-iteration PBKDF2 pass (paying twice for one secret), and MappingStore's
//  own payload is exactly this JSON, so the round trip is byte identical
//  either way.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ZIPFoundation

/// Reads and writes the portable single-file workspace (.ldawork).
public enum WorkspaceArchive {

    // MARK: - Format constants

    /// The payload schema version this build WRITES and is the highest it can
    /// read. Bump only when the inner layout changes.
    public static let currentFormatVersion = 1

    /// Maximum documents in one workspace manifest. At two possible archive
    /// entries per document plus five fixed entries, 497 stays within the
    /// shared 1,000-entry archive ceiling.
    public static let maximumDocumentCount = 497

    /// The file extension and its exported uniform type identifier. Both are
    /// declared in packaging/Info.plist; the constants live here so the app,
    /// the save panel, and the packaging test agree on one spelling.
    public static let fileExtension = "ldawork"
    public static let uniformTypeIdentifier = "com.haotianyi.LDA.workspace"

    /// Inner zip entry paths.
    static let manifestEntryPath = "manifest.json"
    static let sessionEntryPath = "session.json"
    static let mappingEntryPath = "mapping.json"
    static let documentsPrefix = "documents/"
    static let reviewPrefix = "review/"
    static let matterLearnedTermsEntryPath = "matter/learnedTerms.json"
    static let matterCustomPatternsEntryPath = "matter/customPatterns.json"

    /// Fixed modification stamp for every entry. A wall-clock stamp per entry
    /// would make two archives of the same state differ byte for byte and
    /// would record when each document was packed, which is metadata the
    /// format has no reason to carry.
    private static let entryModificationDate = Date(timeIntervalSince1970: 0)

    /// The encrypted envelope. Its magic is distinct from the mapping
    /// sidecar's ("LDAMAP"), so feeding a sidecar to the workspace reader (or
    /// the reverse) fails immediately with a clear format error instead of a
    /// confusing decryption failure. The Keychain service is required by the
    /// initializer but never reached: this container is only ever used with
    /// .passphrase protection.
    static let container = EncryptedContainer(
        magic: Array("LDAWRK".utf8),
        keychainService: "ai.openclaw.lda.workspacekey",
        containerDescription: "Workspace file"
    )

    // MARK: - Writing

    /// Package and encrypt a workspace into `url`.
    ///
    /// The inner zip is assembled entirely in memory, so no plaintext copy of
    /// the archive ever touches the file system, and the only write to `url` is
    /// the finished ciphertext (atomic, so a failure cannot leave a truncated
    /// file where a previous workspace stood).
    ///
    /// - Throws: WorkspaceArchiveError.documentUnreadable naming the document
    ///   when a source file cannot be read, or .writeFailed.
    public static func write(
        _ payload: WorkspacePayload,
        to url: URL,
        passphrase: String
    ) throws {
        let zipBytes = try buildArchiveBytes(payload)
        do {
            try container.save(zipBytes, to: url, protection: .passphrase(passphrase))
        } catch {
            throw WorkspaceArchiveError.writeFailed(describe(error))
        }
    }

    /// Assemble the inner zip in memory.
    private static func buildArchiveBytes(_ payload: WorkspacePayload) throws -> Data {
        do {
            try payload.manifest.validateDocuments()
        } catch let error as WorkspaceManifestValidationError {
            throw writerError(for: error)
        }
        try validateSnapshots(
            payload.snapshots,
            for: payload.manifest
        )

        let archive: Archive
        do {
            archive = try Archive(data: Data(), accessMode: .create)
        } catch {
            throw WorkspaceArchiveError.writeFailed(describe(error))
        }

        var manifest = payload.manifest
        manifest.formatVersion = currentFormatVersion
        try add(json: manifest, at: manifestEntryPath, to: archive)
        try add(json: payload.sessionState, at: sessionEntryPath, to: archive)
        if let mapping = payload.mapping {
            try add(json: mapping, at: mappingEntryPath, to: archive)
        }
        for snapshot in payload.snapshots {
            try add(
                json: snapshot,
                at: reviewPrefix + snapshot.documentID.uuidString + ".json",
                to: archive
            )
        }
        if let terms = payload.matterLearnedTermsJSON {
            try add(data: terms, at: matterLearnedTermsEntryPath, to: archive)
        }
        if let patterns = payload.matterCustomPatternsJSON {
            try add(data: patterns, at: matterCustomPatternsEntryPath, to: archive)
        }
        try addDocuments(manifest: manifest, sources: payload.documentSources, to: archive)

        guard let bytes = archive.data else {
            throw WorkspaceArchiveError.writeFailed("The archive produced no data.")
        }
        return bytes
    }

    /// Add every manifest document's original bytes. A document the manifest
    /// promises but whose bytes cannot be read aborts the whole export: a
    /// workspace that silently omits a document is worse than no workspace.
    private static func addDocuments(
        manifest: WorkspaceManifest,
        sources: [UUID: URL],
        to archive: Archive
    ) throws {
        for record in manifest.documents {
            guard let source = sources[record.id] else {
                throw WorkspaceArchiveError.documentUnreadable(
                    name: record.name,
                    detail: "It is no longer part of this session."
                )
            }
            let bytes: Data
            do {
                try ImportLimits.enforceDocumentSize(at: source)
                // Path based on purpose. The URL-taking read is network
                // capable (a remote URL becomes a synchronous GET), and this
                // app publishes that it reaches the network for exactly one
                // thing. Reading by path makes that claim structural here
                // rather than a reviewed exemption. See NetworkChokepointTests.
                guard let contents = FileManager.default.contents(atPath: source.path) else {
                    throw DocumentIOError.unreadable("The file could not be read.")
                }
                bytes = contents
            } catch {
                throw WorkspaceArchiveError.documentUnreadable(
                    name: record.name,
                    detail: describe(error)
                )
            }
            try add(data: bytes, at: record.archivePath, to: archive)
        }
    }

    /// The inner zip path for one document. The display name is reduced to a
    /// single, safe path component; the id directory keeps two documents with
    /// the same name apart.
    public static func documentArchivePath(id: UUID, name: String) -> String {
        documentsPrefix + id.uuidString + "/" + safeEntryName(name)
    }

    /// A single path component that cannot traverse, hide, or nest.
    static func safeEntryName(_ name: String) -> String {
        let component = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return "document" }
        return trimmed.hasPrefix(".") ? "_" + trimmed : trimmed
    }

    private static func add<T: Encodable>(json value: T, at path: String, to archive: Archive) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try add(data: try encoder.encode(value), at: path, to: archive)
        } catch let error as WorkspaceArchiveError {
            throw error
        } catch {
            throw WorkspaceArchiveError.writeFailed(describe(error))
        }
    }

    private static func add(data: Data, at path: String, to archive: Archive) throws {
        do {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                modificationDate: entryModificationDate,
                compressionMethod: .deflate,
                provider: { position, size in
                    let start = Int(position)
                    return data.subdata(in: start ..< min(start + size, data.count))
                }
            )
        } catch {
            throw WorkspaceArchiveError.writeFailed(describe(error))
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    private static func writerError(
        for error: WorkspaceManifestValidationError
    ) -> WorkspaceArchiveError {
        switch error {
        case .tooManyDocuments:
            return .tooLarge(
                "A workspace can contain at most \(maximumDocumentCount) documents."
            )
        case .duplicateDocumentID:
            return .writeFailed("The workspace contains a duplicate document identifier.")
        case .duplicateArchivePath:
            return .writeFailed("The workspace contains a duplicate document archive path.")
        case .noncanonicalArchivePath:
            return .writeFailed("The workspace contains a noncanonical document archive path.")
        }
    }

    /// Keep review entries in a one-to-zero-or-one relation with manifest
    /// documents. Besides preventing ambiguous state, this is what makes the
    /// 497-document ceiling stay within the shared 1,000-entry archive limit.
    private static func validateSnapshots(
        _ snapshots: [WorkspaceReviewSnapshot],
        for manifest: WorkspaceManifest
    ) throws {
        guard snapshots.count <= manifest.documents.count else {
            throw WorkspaceArchiveError.writeFailed(
                "The workspace contains more review snapshots than manifest documents."
            )
        }
        let documentIDs = Set(manifest.documents.map(\.id))
        var snapshotIDs: Set<UUID> = []
        for snapshot in snapshots {
            guard snapshotIDs.insert(snapshot.documentID).inserted else {
                throw WorkspaceArchiveError.writeFailed(
                    "The workspace contains a duplicate review snapshot document identifier."
                )
            }
            guard documentIDs.contains(snapshot.documentID) else {
                throw WorkspaceArchiveError.writeFailed(
                    "A review snapshot does not belong to a manifest document."
                )
            }
        }
    }
}
