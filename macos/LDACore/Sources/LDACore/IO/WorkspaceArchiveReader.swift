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
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ZIPFoundation

extension WorkspaceArchive {

    // MARK: - Reading

    /// Decrypt and unpack a workspace file.
    ///
    /// Requires nothing but the file and the passphrase: no Keychain item, no
    /// app store, no prior knowledge of the matter.
    ///
    /// - Throws: WorkspaceArchiveError.wrongPassphrase, .createdByNewerVersion,
    ///   .damagedFile, or .tooLarge.
    public static func read(from url: URL, passphrase: String) throws -> OpenedWorkspace {
        let zipBytes = try decryptPayload(at: url, passphrase: passphrase)
        let reader = try WorkspaceZipReader(zipBytes: zipBytes)
        let manifest = try readManifest(from: reader)

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
    private static func decryptPayload(at url: URL, passphrase: String) throws -> Data {
        do {
            return try container.load(from: url, protection: .passphrase(passphrase))
        } catch DocumentIOError.decryptionFailed {
            throw WorkspaceArchiveError.wrongPassphrase
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
            return try JSONDecoder().decode(WorkspaceManifest.self, from: bytes)
        } catch {
            throw WorkspaceArchiveError.damagedFile("Its manifest could not be read.")
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
    /// expansion directory (zip-slip) or that the manifest mislabels.
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
        return target
    }
}

// MARK: - WorkspaceZipReader

/// The inner zip, indexed and metered.
///
/// Every read charges one shared budget for bytes ACTUALLY inflated, using the
/// same machinery and the same ceiling as the session .zip import: an archive
/// that lies about its declared sizes is stopped mid-stream, not after.
final class WorkspaceZipReader {

    private let archive: Archive
    private let entries: [String: Entry]
    private var budget: UInt64
    private let budgetMessage: String

    init(zipBytes: Data) throws {
        do {
            archive = try Archive(data: zipBytes, accessMode: .read)
        } catch {
            throw WorkspaceArchiveError.damagedFile("Its contents are not a readable archive.")
        }
        budget = UInt64(ImportLimits.effectiveArchiveUncompressedBytes)
        budgetMessage = "This workspace expands to more than "
            + "\(ImportLimits.describe(bytes: ImportLimits.effectiveArchiveUncompressedBytes))."

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
            let result = try ZipExtraction.extractMeteredData(
                entry,
                from: archive,
                remainingBudget: budget,
                budgetMessage: budgetMessage
            )
            budget = result.remainingBudget
            return result.data
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
            budget = try ZipExtraction.extractMetered(
                entry,
                from: archive,
                to: target,
                remainingBudget: budget,
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
