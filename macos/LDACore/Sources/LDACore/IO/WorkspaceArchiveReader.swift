//
//  WorkspaceArchiveReader.swift
//  LDACore
//
//  The open half of the .ldawork format: decrypt, then unpack.
//
//  Two invariants this file is responsible for.
//
//  1. THE VERSION CHECK RUNS FIRST. A file written by a newer LDA must say so,
//     not read as damaged. The manifest is therefore probed for nothing but
//     formatVersion before any other field is decoded, so a future schema
//     produces "created by a newer version" rather than a decode failure.
//
//  2. NOTHING IS LEFT BEHIND. Unpacking writes the user's original,
//     un-redacted documents into a temporary directory. Every failure path
//     after that directory exists removes it, and the successful path
//     registers it with ZipImporter so the app's existing cleanup boundaries
//     (tray emptied, window closed, app quit) delete it too.
//
//  The small JSON members (manifest, session state, mapping, review snapshots,
//  matter lists) are read into MEMORY, never unpacked to disk. The mapping in
//  particular is the re-identification key; writing it out as plaintext JSON
//  would undo the reason MappingStore encrypts it in the first place.
//
//  3. ONLY DOCUMENTS ARE UNPACKED. The manifest is attacker-authored text, and
//     unpacking used to write whatever it named. A workspace naming a nested
//     .zip therefore delivered an archive the tray would go on to expand, on a
//     second allowance, behind one user gesture. The manifest's documents are
//     now checked against the types this app actually opens, and a workspace
//     naming anything else is refused whole rather than partially opened: LDA's
//     own writer records nothing but tray documents, so such a file did not
//     come from LDA. The inflation ledger is passed in by the caller for the
//     same reason; see ArchiveBudget.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ZIPFoundation

extension WorkspaceArchive {

    // MARK: - Reading

    /// A workspace that has been decrypted and validated but not yet unpacked.
    ///
    /// The split exists for one reason: restoring a workspace REPLACES the
    /// current session, and a caller must be able to prove the passphrase and
    /// the format version before it discards live work. Everything here is in
    /// memory; nothing has touched the file system yet.
    public struct PreparedWorkspace {
        public let manifest: WorkspaceManifest
        fileprivate let reader: WorkspaceZipReader

        /// Unpack the documents and read the remaining members.
        public func unpack() throws -> OpenedWorkspace {
            try WorkspaceArchive.unpack(manifest: manifest, reader: reader)
        }
    }

    /// Decrypt a workspace file and validate its manifest, without unpacking.
    ///
    /// Requires nothing but the file and the passphrase: no Keychain item, no
    /// app store, no prior knowledge of the matter.
    ///
    /// - Parameter budget: the ledger for the whole user-initiated open. The
    ///   caller passes the SAME instance to anything else that import inflates,
    ///   so opening a workspace cannot spend the ceiling twice.
    /// - Throws: WorkspaceArchiveError.wrongPassphrase, .createdByNewerVersion,
    ///   .damagedFile, .unsupportedDocumentKind, or .tooLarge.
    public static func prepare(
        from url: URL,
        passphrase: String,
        budget: ArchiveBudget = ArchiveBudget()
    ) throws -> PreparedWorkspace {
        try prepare(from: url, protection: .passphrase(passphrase), budget: budget)
    }

    /// Decrypt a workspace file under an explicit protection and validate its
    /// manifest, without unpacking.
    ///
    /// The .keychain protection opens the LOCAL default workspace an export
    /// keeps its mapping in; see WorkspaceArchive's header for why the two
    /// forms exist. Everything after decryption is the same code path, so a
    /// default workspace is validated exactly as strictly as a handed-over one.
    public static func prepare(
        from url: URL,
        protection: MappingProtection,
        budget: ArchiveBudget = ArchiveBudget()
    ) throws -> PreparedWorkspace {
        let zipBytes = try decryptPayload(at: url, protection: protection)
        let reader = try WorkspaceZipReader(zipBytes: zipBytes, budget: budget)
        return PreparedWorkspace(manifest: try readManifest(from: reader), reader: reader)
    }

    /// Decrypt and unpack a workspace file in one step.
    public static func read(
        from url: URL,
        passphrase: String,
        budget: ArchiveBudget = ArchiveBudget()
    ) throws -> OpenedWorkspace {
        try prepare(from: url, passphrase: passphrase, budget: budget).unpack()
    }

    /// Decrypt and unpack a workspace file in one step, under an explicit
    /// protection.
    public static func read(
        from url: URL,
        protection: MappingProtection,
        budget: ArchiveBudget = ArchiveBudget()
    ) throws -> OpenedWorkspace {
        try prepare(from: url, protection: protection, budget: budget).unpack()
    }

    /// The session mapping a workspace carries, WITHOUT unpacking any
    /// document.
    ///
    /// Restore needs the key and nothing else, and unpacking would write the
    /// user's original, un-redacted documents into a temporary directory for
    /// no reason at all. The small JSON members are read into memory only, so
    /// this path never puts a plaintext original on disk.
    ///
    /// Returns nil when the file carries no mapping (a workspace saved before
    /// any export has none).
    public static func readMapping(
        from url: URL,
        protection: MappingProtection,
        budget: ArchiveBudget = ArchiveBudget()
    ) throws -> Mapping? {
        let zipBytes = try decryptPayload(at: url, protection: protection)
        let reader = try WorkspaceZipReader(zipBytes: zipBytes, budget: budget)
        // The version check still runs first: a workspace from a newer LDA
        // must say so rather than read as damaged, exactly as on the open path.
        _ = try readManifest(from: reader)
        return try reader.decode(Mapping.self, at: mappingEntryPath)
    }

    /// Unpack a prepared workspace. Any failure removes the expansion first.
    fileprivate static func unpack(
        manifest: WorkspaceManifest,
        reader: WorkspaceZipReader
    ) throws -> OpenedWorkspace {
        let expansion = try unpackDocuments(manifest: manifest, reader: reader)
        do {
            return OpenedWorkspace(
                manifest: manifest,
                expansion: expansion.archive,
                documentURLs: expansion.urlsByID,
                mapping: try reader.decode(Mapping.self, at: mappingEntryPath),
                sessionState: try reader.decode(WorkspaceSessionState.self, at: sessionEntryPath)
                    ?? WorkspaceSessionState(),
                snapshots: try readSnapshots(from: reader),
                matterLearnedTermsJSON: try reader.data(at: matterLearnedTermsEntryPath),
                matterCustomPatternsJSON: try reader.data(at: matterCustomPatternsEntryPath)
            )
        } catch {
            expansion.archive.cleanUp()
            throw error
        }
    }

    /// Open the encrypted envelope, translating the container's generic
    /// failures into the workspace vocabulary.
    ///
    /// Note on the one distinction AES-GCM cannot make: a file truncated in its
    /// CIPHERTEXT fails authentication exactly as a wrong passphrase does, and
    /// is reported as .wrongPassphrase. Truncation that reaches the container
    /// header is caught structurally and reported as .damagedFile.
    ///
    /// A .keychain protected file has no passphrase to be wrong, so the same
    /// authentication failure is reported as a damaged file naming the real
    /// cause: this Mac's key no longer opens it. Reusing .wrongPassphrase
    /// there would tell the user to retype something they never typed.
    private static func decryptPayload(
        at url: URL,
        protection: MappingProtection
    ) throws -> Data {
        do {
            return try container.load(from: url, protection: protection)
        } catch DocumentIOError.decryptionFailed {
            switch protection {
            case .passphrase:
                throw WorkspaceArchiveError.wrongPassphrase
            case .keychain:
                throw WorkspaceArchiveError.damagedFile(
                    "This Mac's key no longer opens it."
                )
            }
        } catch let error as DocumentIOError {
            throw WorkspaceArchiveError.damagedFile(
                error.errorDescription ?? "The file could not be opened."
            )
        }
    }

    /// Read the manifest, checking the format version before anything else.
    private static func readManifest(from reader: WorkspaceZipReader) throws -> WorkspaceManifest {
        guard let bytes = try reader.data(at: manifestEntryPath) else {
            throw WorkspaceArchiveError.damagedFile("It has no workspace manifest.")
        }
        guard let probe = try? JSONDecoder().decode(WorkspaceFormatProbe.self, from: bytes) else {
            throw WorkspaceArchiveError.damagedFile("Its manifest could not be read.")
        }
        guard probe.formatVersion <= currentFormatVersion else {
            throw WorkspaceArchiveError.createdByNewerVersion(
                found: probe.formatVersion,
                supported: currentFormatVersion
            )
        }
        do {
            let manifest = try JSONDecoder().decode(WorkspaceManifest.self, from: bytes)
            try manifest.validateDocuments()
            return manifest
        } catch let error as WorkspaceManifestValidationError {
            throw readerError(for: error)
        } catch {
            throw WorkspaceArchiveError.damagedFile("Its manifest could not be read.")
        }
    }

    private static func readerError(
        for error: WorkspaceManifestValidationError
    ) -> WorkspaceArchiveError {
        switch error {
        case .tooManyDocuments:
            return .tooLarge(
                "A workspace can contain at most \(maximumDocumentCount) documents."
            )
        case .duplicateDocumentID:
            return .damagedFile("Its manifest repeats a document identifier.")
        case .duplicateArchivePath:
            return .damagedFile("Its manifest repeats a document archive path.")
        case .noncanonicalArchivePath:
            return .damagedFile("Its manifest names a noncanonical document archive path.")
        }
    }

    /// Read every per-document review snapshot the archive carries.
    private static func readSnapshots(
        from reader: WorkspaceZipReader
    ) throws -> [UUID: WorkspaceReviewSnapshot] {
        var snapshots: [UUID: WorkspaceReviewSnapshot] = [:]
        for path in reader.paths(withPrefix: reviewPrefix) {
            guard let snapshot = try reader.decode(WorkspaceReviewSnapshot.self, at: path) else {
                continue
            }
            snapshots[snapshot.documentID] = snapshot
        }
        return snapshots
    }

    /// One unpacked document set: the registered expansion plus a lookup by
    /// tray entry id.
    private struct UnpackedDocuments {
        let archive: ZipImporter.ExpandedArchive
        let urlsByID: [UUID: URL]
    }

    /// Unpack the manifest's documents into a fresh, registered temporary
    /// directory. Any failure removes the directory before rethrowing.
    private static func unpackDocuments(
        manifest: WorkspaceManifest,
        reader: WorkspaceZipReader
    ) throws -> UnpackedDocuments {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ZipImporter.register(directory)
        let placeholder = ZipImporter.ExpandedArchive(directory: directory, documents: [])

        var urlsByID: [UUID: URL] = [:]
        var ordered: [URL] = []
        do {
            for record in manifest.documents {
                let target = try destination(for: record, under: directory)
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try reader.extract(at: record.archivePath, to: target)
                urlsByID[record.id] = target
                ordered.append(target)
            }
        } catch {
            placeholder.cleanUp()
            throw error
        }
        return UnpackedDocuments(
            archive: ZipImporter.ExpandedArchive(directory: directory, documents: ordered),
            urlsByID: urlsByID
        )
    }

    /// Where one document unpacks to, refusing any path that would escape the
    /// expansion directory (zip-slip), that the manifest mislabels, or that
    /// names a type this app does not open.
    private static func destination(
        for record: WorkspaceDocumentRecord,
        under directory: URL
    ) throws -> URL {
        let components = record.archivePath.split(separator: "/").map(String.init)
        guard record.archivePath.hasPrefix(documentsPrefix),
              !components.contains("..") else {
            throw WorkspaceArchiveError.damagedFile("It names a document outside the archive.")
        }
        let target = directory.appendingPathComponent(record.archivePath)
        let root = directory.standardizedFileURL.path
        guard target.standardizedFileURL.path.hasPrefix(root + "/") else {
            throw WorkspaceArchiveError.damagedFile("It names a document outside the archive.")
        }
        try requireOpenableKind(target.lastPathComponent, declaredName: record.name)
        return target
    }

    /// Refuse a manifest document whose file name is not one of the types the
    /// tray opens.
    ///
    /// The check is on the name that reaches DISK, not on the manifest's
    /// contentKind field: contentKind is a label, and what a later importer or
    /// expansion acts on is the extension of the unpacked file. The whitelist
    /// is ZipImporter's own supported set, so the workspace and the .zip import
    /// agree on what a session document is by construction rather than by two
    /// lists kept in step by hand.
    private static func requireOpenableKind(
        _ unpackedName: String,
        declaredName: String
    ) throws {
        let ext = (unpackedName as NSString).pathExtension.lowercased()
        guard ZipImporter.supportedExtensions.contains(ext) else {
            throw WorkspaceArchiveError.unsupportedDocumentKind(name: declaredName)
        }
    }
}

// MARK: - WorkspaceZipReader

/// The inner zip, indexed and metered.
///
/// Every read charges the IMPORT's ledger for bytes ACTUALLY inflated, using
/// the same machinery and the same ceiling as the session .zip import: an
/// archive that lies about its declared sizes is stopped mid-stream, not after,
/// and an open that also expands something else spends one allowance between
/// them.
final class WorkspaceZipReader {

    private let archive: Archive
    private let entries: [String: Entry]
    private let budget: ArchiveBudget
    private let budgetMessage: String

    init(zipBytes: Data, budget: ArchiveBudget) throws {
        do {
            archive = try Archive(data: zipBytes, accessMode: .read)
        } catch {
            throw WorkspaceArchiveError.damagedFile("Its contents are not a readable archive.")
        }
        self.budget = budget
        budgetMessage = budget.refusalMessage(for: "This workspace")

        var index: [String: Entry] = [:]
        var examined = 0
        for entry in archive {
            examined += 1
            guard examined <= ImportLimits.maxArchiveEntries else {
                throw WorkspaceArchiveError.tooLarge(
                    "This workspace declares more than "
                        + "\(ImportLimits.maxArchiveEntries) entries."
                )
            }
            guard entry.type == .file else { continue }
            index[entry.path] = entry
        }
        entries = index
    }

    /// Entry paths under a prefix, in a stable order.
    func paths(withPrefix prefix: String) -> [String] {
        entries.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// One member's bytes, or nil when the archive does not carry it.
    func data(at path: String) throws -> Data? {
        guard let entry = entries[path] else { return nil }
        do {
            return try ZipExtraction.extractMeteredData(
                entry,
                from: archive,
                budget: budget,
                budgetMessage: budgetMessage
            )
        } catch {
            throw WorkspaceZipReader.translate(error, path: path)
        }
    }

    /// One member decoded from JSON, or nil when the archive does not carry it.
    func decode<T: Decodable>(_ type: T.Type, at path: String) throws -> T? {
        guard let bytes = try data(at: path) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: bytes)
        } catch {
            throw WorkspaceArchiveError.damagedFile("One of its records could not be read.")
        }
    }

    /// Unpack one member to a file.
    func extract(at path: String, to target: URL) throws {
        guard let entry = entries[path] else {
            throw WorkspaceArchiveError.damagedFile("A document listed in the manifest is missing.")
        }
        do {
            try ZipExtraction.extractMetered(
                entry,
                from: archive,
                to: target,
                budget: budget,
                budgetMessage: budgetMessage
            )
        } catch {
            throw WorkspaceZipReader.translate(error, path: path)
        }
    }

    /// Turn an extraction failure into the workspace vocabulary.
    private static func translate(_ error: Error, path: String) -> Error {
        switch error {
        case let workspaceError as WorkspaceArchiveError:
            return workspaceError
        case DocumentIOError.tooLarge(let detail):
            return WorkspaceArchiveError.tooLarge(detail)
        default:
            return WorkspaceArchiveError.damagedFile("Part of it could not be unpacked.")
        }
    }
}
