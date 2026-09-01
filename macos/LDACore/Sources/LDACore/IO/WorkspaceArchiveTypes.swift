//
//  WorkspaceArchiveTypes.swift
//  LDACore
//
//  Value types for the portable single-file workspace (.ldawork): one file that
//  carries a matter's whole working state so it can be reopened by double-click
//  or handed to a colleague on another Mac.
//
//  Why these types live in LDACore and not in the UI layer: the archive is a
//  pure format, and keeping it here means the container, the inner zip, and the
//  schema can be tested without a window, a Keychain, or a model.
//
//  Two payloads deliberately stay OPAQUE (raw JSON Data): the matter layer's
//  learned rules and custom patterns. Their element types (LearnedTerm and
//  CustomPattern's store shape) belong to the UI layer's stores, and dragging
//  them down here would invert the dependency for no gain. The archive treats
//  them as bytes; the session layer owns their schema.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import CryptoKit

// MARK: - Errors

/// Every way opening or writing a workspace file can fail, as distinct cases a
/// caller can act on. A "damaged file" and a "wrong passphrase" must never be
/// reported as the same thing: one is recoverable by typing again, the other
/// is not.
public enum WorkspaceArchiveError: Error, LocalizedError, Sendable, Equatable {

    /// The passphrase did not open the file (AES-GCM authentication failed).
    case wrongPassphrase

    /// The file declares a payload schema this build cannot read.
    case createdByNewerVersion(found: Int, supported: Int)

    /// The file is not a workspace file, is truncated, or its payload is not
    /// a readable archive. The detail is safe to show: it never quotes content.
    case damagedFile(String)

    /// A source document could not be read while writing the archive. The
    /// export is abandoned so a workspace can never claim to hold a document
    /// whose bytes are missing.
    case documentUnreadable(name: String, detail: String)

    /// A ceiling was hit (inflated bytes or entry count). Same budget the
    /// session zip import enforces.
    case tooLarge(String)

    /// The manifest names a document whose type this app does not open.
    ///
    /// LDA's own writer only ever records the tray's document types, so a
    /// workspace naming anything else was not written by LDA. The one that
    /// matters is a nested archive: unpacking it would put a second, unmetered
    /// expansion behind a single user gesture. See WorkspaceArchiveReader.
    case unsupportedDocumentKind(name: String)

    /// The finished archive could not be written to the chosen location.
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .wrongPassphrase:
            return "That passphrase did not open this workspace file."
        case .createdByNewerVersion(let found, let supported):
            return "This workspace file was created by a newer version of LDA "
                + "(format \(found); this app reads format \(supported)). "
                + "Update LDA to open it."
        case .damagedFile(let detail):
            return "This workspace file could not be read. \(detail)"
        case .documentUnreadable(let name, let detail):
            return "Could not read \(name) while saving the workspace. \(detail)"
        case .tooLarge(let detail):
            return detail
        case .unsupportedDocumentKind(let name):
            return "This workspace file lists \(name), which is not a document "
                + "type LDA opens. It was not written by LDA and has not been opened."
        case .writeFailed(let detail):
            return "The workspace file could not be saved. \(detail)"
        }
    }
}

// MARK: - Manifest

/// One document recorded in a workspace archive.
public struct WorkspaceDocumentRecord: Codable, Equatable, Sendable {

    /// The session tray entry id this document had when the archive was
    /// written. Review snapshots and document bytes are keyed by it.
    public let id: UUID

    /// The document's display file name, as the tray showed it.
    public let name: String

    /// The lowercased file extension ("docx", "pdf", "txt", "png").
    public let contentKind: String

    /// Where the original bytes live inside the inner zip.
    public let archivePath: String

    public init(id: UUID, name: String, contentKind: String, archivePath: String) {
        self.id = id
        self.name = name
        self.contentKind = contentKind
        self.archivePath = archivePath
    }
}

/// The archive's root manifest.
///
/// formatVersion lives HERE, inside the ciphertext, rather than in the
/// container's plaintext header. A workspace file therefore reveals nothing
/// about itself to anyone who cannot open it, and the version check still runs
/// before any other field is trusted (see WorkspaceArchive's version probe).
public struct WorkspaceManifest: Codable, Equatable, Sendable {

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case createdAtISO8601
        case appVersion
        case matterLabel
        case matterScopeID
        case substitutionStyle
        case documents
    }

    /// Payload schema version. Distinct from EncryptedContainer.containerVersion,
    /// which versions the crypto envelope.
    public var formatVersion: Int

    /// When the archive was written. Supplied by the caller; no clock reads
    /// happen in this layer.
    public var createdAtISO8601: String

    /// The LDA build that wrote the archive, for support and diagnosis.
    public var appVersion: String?

    /// The matter this workspace belongs to, when one was selected.
    public var matterLabel: String?

    /// The matter's stable scope id (MatterMetadata.id) when the session was
    /// scoped to a matter. Lets a colleague's Mac reconstruct the matter layer
    /// even though its metadata store has never heard of the matter.
    public var matterScopeID: UUID?

    /// The substitution style the session was working in.
    public var substitutionStyle: SubstitutionStyle

    /// The documents in tray order.
    public var documents: [WorkspaceDocumentRecord]

    public init(
        formatVersion: Int,
        createdAtISO8601: String,
        appVersion: String?,
        matterLabel: String?,
        matterScopeID: UUID?,
        substitutionStyle: SubstitutionStyle,
        documents: [WorkspaceDocumentRecord]
    ) {
        self.formatVersion = formatVersion
        self.createdAtISO8601 = createdAtISO8601
        self.appVersion = appVersion
        self.matterLabel = matterLabel
        self.matterScopeID = matterScopeID
        self.substitutionStyle = substitutionStyle
        self.documents = documents
    }

    /// Decode the document list with its format ceiling enforced before an
    /// attacker-authored manifest can allocate an unbounded record array.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        createdAtISO8601 = try container.decode(String.self, forKey: .createdAtISO8601)
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        matterLabel = try container.decodeIfPresent(String.self, forKey: .matterLabel)
        matterScopeID = try container.decodeIfPresent(UUID.self, forKey: .matterScopeID)
        substitutionStyle = try container.decode(SubstitutionStyle.self, forKey: .substitutionStyle)

        var documentContainer = try container.nestedUnkeyedContainer(forKey: .documents)
        if let count = documentContainer.count,
           count > WorkspaceArchive.maximumDocumentCount {
            throw WorkspaceManifestValidationError.tooManyDocuments
        }
        var decoded: [WorkspaceDocumentRecord] = []
        decoded.reserveCapacity(
            min(documentContainer.count ?? 0, WorkspaceArchive.maximumDocumentCount)
        )
        while !documentContainer.isAtEnd {
            guard decoded.count < WorkspaceArchive.maximumDocumentCount else {
                throw WorkspaceManifestValidationError.tooManyDocuments
            }
            decoded.append(try documentContainer.decode(WorkspaceDocumentRecord.self))
        }
        documents = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(createdAtISO8601, forKey: .createdAtISO8601)
        try container.encodeIfPresent(appVersion, forKey: .appVersion)
        try container.encodeIfPresent(matterLabel, forKey: .matterLabel)
        try container.encodeIfPresent(matterScopeID, forKey: .matterScopeID)
        try container.encode(substitutionStyle, forKey: .substitutionStyle)
        try container.encode(documents, forKey: .documents)
    }

    /// Validate the relationships that make each manifest record distinct and
    /// bind it to the only archive path this format's writer emits.
    func validateDocuments() throws {
        guard documents.count <= WorkspaceArchive.maximumDocumentCount else {
            throw WorkspaceManifestValidationError.tooManyDocuments
        }
        var ids: Set<UUID> = []
        var paths: Set<String> = []
        for document in documents {
            guard ids.insert(document.id).inserted else {
                throw WorkspaceManifestValidationError.duplicateDocumentID
            }
            guard paths.insert(document.archivePath).inserted else {
                throw WorkspaceManifestValidationError.duplicateArchivePath
            }
            guard document.archivePath == WorkspaceArchive.documentArchivePath(
                id: document.id,
                name: document.name
            ) else {
                throw WorkspaceManifestValidationError.noncanonicalArchivePath
            }
        }
    }
}

enum WorkspaceManifestValidationError: Error {
    case tooManyDocuments
    case duplicateDocumentID
    case duplicateArchivePath
    case noncanonicalArchivePath
}

/// The smallest thing that can be decoded from any manifest, of any version.
/// Read first so a future-format file produces a "newer version" error rather
/// than a decode failure reported as corruption.
struct WorkspaceFormatProbe: Decodable {
    let formatVersion: Int
}

// MARK: - Review state

/// One reviewed entity: the located span plus the user's decision.
///
/// Restoring these is what lets a colleague WITHOUT the detection model see
/// the reviewed state: the decisions travel with the archive and are re-applied
/// directly, never recomputed.
public struct WorkspaceEntityRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let span: Span
    public let accepted: Bool
    public let token: String?

    public init(id: UUID, span: Span, accepted: Bool, token: String?) {
        self.id = id
        self.span = span
        self.accepted = accepted
        self.token = token
    }
}

/// One document's review state.
public struct WorkspaceReviewSnapshot: Codable, Equatable, Sendable {

    /// The tray entry the snapshot belongs to.
    public let documentID: UUID

    /// Digest of the document text the spans were measured against. Spans are
    /// UTF-16 offsets, so applying them to text that imported differently
    /// would attribute one value's decision to another's characters. The
    /// digest turns that from a silent corruption into a detectable one.
    public let textDigest: String

    /// Entities in the order the review list held them.
    public let entities: [WorkspaceEntityRecord]

    public init(documentID: UUID, textDigest: String, entities: [WorkspaceEntityRecord]) {
        self.documentID = documentID
        self.textDigest = textDigest
        self.entities = entities
    }

    /// SHA-256 (hex) of a document's imported text.
    public static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Review state that belongs to the session rather than to one document.
///
/// Explicitly NOT UI state: no scroll positions, no selection, no window
/// geometry. A workspace restores decisions, not a desktop.
public struct WorkspaceSessionState: Codable, Equatable, Sendable {

    /// User-forced replacement text keyed by the exact surface (F5).
    public var pseudonymOverrides: [String: String]

    public init(pseudonymOverrides: [String: String] = [:]) {
        self.pseudonymOverrides = pseudonymOverrides
    }
}

// MARK: - Write payload

/// Everything an archive is built from. Document bytes are named by URL and
/// read during the write, so the caller keeps its sandbox scopes open across
/// the call rather than buffering whole documents in memory.
public struct WorkspacePayload {
    public var manifest: WorkspaceManifest
    public var documentSources: [UUID: URL]
    public var mapping: Mapping?
    public var sessionState: WorkspaceSessionState
    public var snapshots: [WorkspaceReviewSnapshot]
    public var matterLearnedTermsJSON: Data?
    public var matterCustomPatternsJSON: Data?

    public init(
        manifest: WorkspaceManifest,
        documentSources: [UUID: URL],
        mapping: Mapping? = nil,
        sessionState: WorkspaceSessionState = WorkspaceSessionState(),
        snapshots: [WorkspaceReviewSnapshot] = [],
        matterLearnedTermsJSON: Data? = nil,
        matterCustomPatternsJSON: Data? = nil
    ) {
        self.manifest = manifest
        self.documentSources = documentSources
        self.mapping = mapping
        self.sessionState = sessionState
        self.snapshots = snapshots
        self.matterLearnedTermsJSON = matterLearnedTermsJSON
        self.matterCustomPatternsJSON = matterCustomPatternsJSON
    }
}

// MARK: - Read result

/// An opened workspace: its metadata in memory and its documents unpacked into
/// a registered temporary directory.
///
/// The documents are the user's ORIGINAL, un-redacted files. The expansion is
/// registered with ZipImporter, so the existing cleanup boundaries (the tray
/// emptying, the window closing, app termination) delete them exactly as they
/// delete a dropped .zip's contents.
public struct OpenedWorkspace {
    public let manifest: WorkspaceManifest
    public let expansion: ZipImporter.ExpandedArchive
    public let documentURLs: [UUID: URL]
    public let mapping: Mapping?
    public let sessionState: WorkspaceSessionState
    public let snapshots: [UUID: WorkspaceReviewSnapshot]
    public let matterLearnedTermsJSON: Data?
    public let matterCustomPatternsJSON: Data?

    /// The unpacked documents in manifest (tray) order.
    public var orderedDocumentURLs: [URL] {
        manifest.documents.compactMap { documentURLs[$0.id] }
    }
}
