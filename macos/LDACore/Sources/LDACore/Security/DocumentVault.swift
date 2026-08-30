//
//  DocumentVault.swift
//  LDACore
//
//  The staging vault: documents enter it once (human-driven intake), receive
//  an opaque handle, and every later operation refers to the handle. This is
//  the storage half of the MCP context boundary: file paths are themselves PII
//  (legal folders and files are named after the parties), so the paths must
//  stop at the vault and only handles may travel onward.
//
//  Layout under the vault root:
//
//    registry.json                 the handle registry (atomic writes)
//    objects/<handle>/...          one directory per staged or derived artifact
//    outbox/                       where exported artifacts land for the human
//
//  Naming rule: nothing inside objects/ may derive from the original filename.
//  A staged original is stored as "original.<format>"; derived artifacts are
//  named by their producers from that neutral base. The original filename
//  survives ONLY in the registry, reserved for human-facing export naming,
//  and must never be returned through any MCP tool.
//
//  Encryption posture (honest): vault contents are plaintext on disk today.
//  Roadmap phase 5 adds encryption at rest and phase 6 moves key holding into
//  an XPC service. To let those slot in without changing this public API, all
//  reads of stored document bytes go through ONE internal chokepoint
//  (plaintextFileURL(for:)); phase 5 will decrypt there and nowhere else.
//
//  Concurrency: the registry is a single JSON file written atomically, so a
//  crash never leaves a torn registry. Writers in ONE process are serialized
//  by a lock; two processes writing at the same instant are last-writer-wins,
//  which is acceptable for a human-paced intake flow and noted in the roadmap.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import PDFKit
import Security

// MARK: - Artifact kinds

/// What a vault entry holds. The kind decides the handle prefix, what may be
/// read back through MCP tools, and what may be exported.
public enum VaultArtifactKind: String, Codable, Sendable, CaseIterable {
    /// A staged source document. Contains PII; never leaves the vault through
    /// a tool response, and cannot be exported.
    case original
    /// A redacted artifact produced by anonymize. The only kind whose TEXT a
    /// tool (read_redacted) may return.
    case redacted
    /// A restored artifact. Contains PII again; export-only.
    case restored

    /// The opaque handle prefix for this kind.
    public var handlePrefix: String {
        switch self {
        case .original: return "doc_"
        case .redacted: return "red_"
        case .restored: return "res_"
        }
    }

    /// The suffix used when exporting to the outbox under the original's
    /// human-facing name.
    var exportSuffix: String {
        switch self {
        case .original: return ""
        case .redacted: return "_redacted"
        case .restored: return "_restored"
        }
    }
}

// MARK: - Registry entry

/// One vault entry. The wire-safe subset (handle, kind, format, byteCount,
/// pageCount, stagedAtISO8601, sourceHandle) is what MCP tools may surface;
/// originalFilename and the relative paths are vault-internal.
public struct VaultEntry: Codable, Sendable, Equatable {
    /// The opaque handle: kind prefix plus random hex, no relation to the
    /// document's name or staging time.
    public let handle: String
    /// What this entry holds.
    public let kind: VaultArtifactKind
    /// Normalized format: "docx", "pdf", "md", or "txt".
    public let format: String
    /// Size of the stored file in bytes.
    public let byteCount: Int
    /// Page count, recorded only for PDFs where it is cheap to read.
    public let pageCount: Int?
    /// When the entry was created, ISO-8601, supplied by the caller (the vault
    /// itself never reads the clock, matching the service facade's contract).
    public let stagedAtISO8601: String
    /// Vault-relative location of the stored file. Internal; never surfaced.
    public let relativePath: String
    /// The original filename, kept ONLY for human-facing export naming.
    /// Present for originals; nil for derived artifacts.
    public let originalFilename: String?
    /// For derived artifacts: the handle this one was produced from.
    public let sourceHandle: String?
    /// For redacted artifacts: vault-relative location of the encrypted
    /// mapping sidecar that restores this artifact. Internal; never surfaced.
    public let mappingRelativePath: String?
    /// For redacted artifacts: the base name from which the mapping sidecar's
    /// Keychain account derives when no passphrase protects it. Opaque (it is
    /// a handle), deterministic, and shared by every member of one session.
    public let mappingAccountBase: String?
}

// MARK: - Errors

/// Vault failures. Messages are boundary-safe by construction: they carry an
/// error code and a handle, never a path or a filename.
public enum DocumentVaultError: Error, Equatable {
    /// No entry exists for the handle.
    case unknownHandle(String)
    /// The file to stage does not exist or is not a regular file.
    case sourceUnreadable
    /// A commit named a file that is not inside the vault.
    case artifactOutsideVault
    /// prepareDerived was asked for the .original kind, which only stage may
    /// create.
    case notADerivedKind
    /// Export was asked for an original, which never leaves the vault.
    case notExportable(String)
    /// The entry has no mapping sidecar recorded.
    case missingMapping(String)
    /// The registry file exists but cannot be decoded.
    case corruptRegistry
    /// The system random source failed while allocating a handle.
    case randomnessUnavailable

    /// A short, boundary-safe description: code plus handle only.
    public var message: String {
        switch self {
        case .unknownHandle(let handle):
            return "unknown_handle: no vault entry for \(handle)"
        case .sourceUnreadable:
            return "source_unreadable: the file to stage does not exist or cannot be read"
        case .artifactOutsideVault:
            return "artifact_outside_vault: a produced file was not inside the vault"
        case .notADerivedKind:
            return "not_a_derived_kind: only stage may create originals"
        case .notExportable(let handle):
            return "not_exportable: \(handle) is an original and never leaves the vault"
        case .missingMapping(let handle):
            return "missing_mapping: \(handle) has no mapping sidecar recorded"
        case .corruptRegistry:
            return "corrupt_registry: the vault registry could not be decoded"
        case .randomnessUnavailable:
            return "randomness_unavailable: could not allocate a handle"
        }
    }
}

// MARK: - DocumentVault

/// The staging vault over one root directory. Stateless in memory: every
/// operation reads the registry from disk and writes it back atomically.
public struct DocumentVault {

    /// Environment variable overriding the vault root. Set by whoever launches
    /// the process (never by a request), like LDA_MCP_ALLOWED_ROOTS.
    public static let environmentKey = "LDA_VAULT_DIR"

    /// File and directory names inside the vault root.
    public static let registryFileName = "registry.json"
    public static let objectsDirectoryName = "objects"
    public static let outboxDirectoryName = "outbox"

    /// Where the vault lives.
    public let rootDirectory: URL

    /// Serializes registry read-modify-write cycles within this process.
    private static let registryLock = NSLock()

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// Open the vault at the root the environment selects: LDA_VAULT_DIR when
    /// set, else Application Support/LDA/Vault (the same app-support base the
    /// other stores use).
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(rootDirectory: DocumentVault.rootDirectory(environment: environment))
    }

    /// The vault root for an environment. LDA_VAULT_DIR wins; the default is
    /// Application Support/LDA/Vault.
    public static func rootDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[environmentKey],
           !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("LDA", isDirectory: true)
            .appendingPathComponent("Vault", isDirectory: true)
    }

    /// The fixed, human-known directory exported artifacts land in. The model
    /// never chooses an export destination; this is the only one.
    public var outboxDirectory: URL {
        rootDirectory.appendingPathComponent(DocumentVault.outboxDirectoryName, isDirectory: true)
    }

    private var objectsDirectory: URL {
        rootDirectory.appendingPathComponent(DocumentVault.objectsDirectoryName, isDirectory: true)
    }

    private var registryURL: URL {
        rootDirectory.appendingPathComponent(DocumentVault.registryFileName)
    }

    // MARK: - Staging

    /// Copy a document INTO the vault and register it under a fresh opaque
    /// handle. Records neutral metadata only; the original filename is kept in
    /// the registry solely for later human-facing export naming.
    ///
    /// - Parameters:
    ///   - fileURL: the document to stage. Copied, never moved.
    ///   - stagedAtISO8601: caller-supplied timestamp (the edge owns the clock).
    @discardableResult
    public func stage(fileURL: URL, stagedAtISO8601: String) throws -> VaultEntry {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            throw DocumentVaultError.sourceUnreadable
        }

        let format = DocumentVault.normalizedFormat(forExtension: fileURL.pathExtension)

        let entry: VaultEntry = try DocumentVault.registryLock.withLock {
            var registry = try loadRegistryLocked()
            let handle = try allocateHandleLocked(kind: .original, registry: registry)

            let directory = objectsDirectory.appendingPathComponent(handle, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let storedName = "original.\(format)"
            let storedURL = directory.appendingPathComponent(storedName)
            try FileManager.default.copyItem(at: fileURL, to: storedURL)

            let byteCount = try DocumentVault.fileByteCount(storedURL)
            let entry = VaultEntry(
                handle: handle,
                kind: .original,
                format: format,
                byteCount: byteCount,
                pageCount: format == "pdf" ? PDFDocument(url: storedURL)?.pageCount : nil,
                stagedAtISO8601: stagedAtISO8601,
                relativePath: "\(DocumentVault.objectsDirectoryName)/\(handle)/\(storedName)",
                originalFilename: fileURL.lastPathComponent,
                sourceHandle: nil,
                mappingRelativePath: nil,
                mappingAccountBase: nil
            )
            registry.entries.append(entry)
            try saveRegistryLocked(registry)
            return entry
        }

        SecurityEventLog.shared.record(kind: .vaultDocumentStaged, scope: DocumentVault.auditScope)
        return entry
    }

    // MARK: - Derived artifacts

    /// A reserved handle plus a directory a producer may write files into
    /// before committing. Not yet in the registry; abort(slot:) discards it.
    public struct DerivedSlot: Sendable {
        public let handle: String
        public let kind: VaultArtifactKind
        public let directory: URL
    }

    /// Reserve a handle and create its object directory so a producer (the
    /// anonymize or restore pipeline) can write its files there directly.
    public func prepareDerived(kind: VaultArtifactKind) throws -> DerivedSlot {
        guard kind != .original else {
            throw DocumentVaultError.notADerivedKind
        }
        return try DocumentVault.registryLock.withLock {
            let registry = try loadRegistryLocked()
            let handle = try allocateHandleLocked(kind: kind, registry: registry)
            let directory = objectsDirectory.appendingPathComponent(handle, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return DerivedSlot(handle: handle, kind: kind, directory: directory)
        }
    }

    /// Register a produced artifact. The primary file (and the mapping file,
    /// when given) must already sit inside the vault; the entry records their
    /// vault-relative locations plus neutral metadata.
    ///
    /// The mapping file may live in ANOTHER entry's directory: a session
    /// shares one sidecar across all of its redacted artifacts.
    @discardableResult
    public func commit(
        slot: DerivedSlot,
        primaryFile: URL,
        stagedAtISO8601: String,
        sourceHandle: String?,
        mappingFile: URL?,
        mappingAccountBase: String?
    ) throws -> VaultEntry {
        let relativePath = try vaultRelativePath(of: primaryFile)
        let mappingRelativePath = try mappingFile.map { try vaultRelativePath(of: $0) }
        let format = DocumentVault.normalizedFormat(forExtension: primaryFile.pathExtension)
        let byteCount = try DocumentVault.fileByteCount(primaryFile)

        let entry = VaultEntry(
            handle: slot.handle,
            kind: slot.kind,
            format: format,
            byteCount: byteCount,
            pageCount: format == "pdf" ? PDFDocument(url: primaryFile)?.pageCount : nil,
            stagedAtISO8601: stagedAtISO8601,
            relativePath: relativePath,
            originalFilename: nil,
            sourceHandle: sourceHandle,
            mappingRelativePath: mappingRelativePath,
            mappingAccountBase: mappingAccountBase
        )

        try DocumentVault.registryLock.withLock {
            var registry = try loadRegistryLocked()
            registry.entries.append(entry)
            try saveRegistryLocked(registry)
        }

        SecurityEventLog.shared.record(kind: .vaultArtifactStored, scope: DocumentVault.auditScope)
        return entry
    }

    /// Discard a prepared slot: remove its directory and register nothing.
    /// Best-effort cleanup for a failed pipeline run.
    public func abort(slot: DerivedSlot) {
        try? FileManager.default.removeItem(at: slot.directory)
    }

    // MARK: - Lookup

    /// Every entry, oldest staging timestamp first (ties keep insertion order).
    public func list() throws -> [VaultEntry] {
        try DocumentVault.registryLock.withLock {
            try loadRegistryLocked().entries
        }
        .enumerated()
        .sorted { left, right in
            if left.element.stagedAtISO8601 != right.element.stagedAtISO8601 {
                return left.element.stagedAtISO8601 < right.element.stagedAtISO8601
            }
            return left.offset < right.offset
        }
        .map(\.element)
    }

    /// The entry for a handle, or DocumentVaultError.unknownHandle.
    public func entry(handle: String) throws -> VaultEntry {
        let entries = try DocumentVault.registryLock.withLock {
            try loadRegistryLocked().entries
        }
        guard let match = entries.first(where: { $0.handle == handle }) else {
            throw DocumentVaultError.unknownHandle(handle)
        }
        return match
    }

    // MARK: - Reading (the chokepoint)

    /// Read the stored bytes of an entry. Routed through the plaintext
    /// chokepoint so phase 5 (encryption at rest) changes one function.
    /// FileManager.contents is deliberate: unlike Data(contentsOf:) it has no
    /// remote-URL capability, so the network chokepoint scan stays clean.
    public func readDocumentBytes(handle: String) throws -> Data {
        let found = try entry(handle: handle)
        guard let data = FileManager.default.contents(atPath: plaintextFileURL(for: found).path) else {
            throw DocumentVaultError.unknownHandle(handle)
        }
        return data
    }

    /// Run body with a URL from which the entry's plaintext can be read.
    /// Today that is the stored file itself; when phase 5 encrypts the store,
    /// this will decrypt to a private temporary file, hand it to body, and
    /// destroy it afterward. Callers must not retain the URL past body.
    public func withPlaintextFileURL<T>(
        handle: String,
        _ body: (URL) throws -> T
    ) throws -> T {
        let found = try entry(handle: handle)
        return try body(plaintextFileURL(for: found))
    }

    /// The plural form for pipelines that consume several documents at once
    /// (a session). Same contract as withPlaintextFileURL.
    public func withPlaintextFileURLs<T>(
        handles: [String],
        _ body: ([URL]) throws -> T
    ) throws -> T {
        let urls = try handles.map { try plaintextFileURL(for: entry(handle: $0)) }
        return try body(urls)
    }

    /// The mapping sidecar location for a redacted entry.
    public func mappingFileURL(forHandle handle: String) throws -> URL {
        let found = try entry(handle: handle)
        guard let relative = found.mappingRelativePath else {
            throw DocumentVaultError.missingMapping(handle)
        }
        return rootDirectory.appendingPathComponent(relative)
    }

    /// THE internal chokepoint every read of stored document bytes goes
    /// through. Phase 5 (encryption at rest) will decrypt here; phase 6 (XPC
    /// key holding) will fetch the key here. Nothing else may resolve an
    /// entry's stored file.
    private func plaintextFileURL(for entry: VaultEntry) -> URL {
        rootDirectory.appendingPathComponent(entry.relativePath)
    }

    // MARK: - Export

    /// Copy a redacted or restored artifact into the outbox, named after the
    /// original document it derives from (the one place the original filename
    /// is used). Originals are refused: the vault never re-emits a source
    /// document. Returns the outbox file URL for HUMAN-facing edges (CLI,
    /// GUI); MCP responses must not include it.
    @discardableResult
    public func exportToOutbox(handle: String) throws -> URL {
        let found = try entry(handle: handle)
        guard found.kind == .redacted || found.kind == .restored else {
            SecurityEventLog.shared.record(
                kind: .vaultArtifactExported,
                scope: DocumentVault.auditScope,
                succeeded: false,
                detail: "originalRefused"
            )
            throw DocumentVaultError.notExportable(handle)
        }

        try FileManager.default.createDirectory(
            at: outboxDirectory,
            withIntermediateDirectories: true
        )

        let baseName = exportBaseName(for: found)
        let destination = firstFreeOutboxURL(base: baseName, ext: found.format)
        try FileManager.default.copyItem(
            at: plaintextFileURL(for: found),
            to: destination
        )
        SecurityEventLog.shared.record(kind: .vaultArtifactExported, scope: DocumentVault.auditScope)
        return destination
    }

    /// The human-facing outbox base name: the root original's filename base
    /// plus the kind suffix, falling back to the handle when no original
    /// ancestor is on record.
    private func exportBaseName(for entry: VaultEntry) -> String {
        if let originalName = originalAncestorFilename(of: entry) {
            let base = (originalName as NSString).deletingPathExtension
            return base + entry.kind.exportSuffix
        }
        return entry.handle
    }

    /// Walk sourceHandle links up to the staged original and return its
    /// recorded filename, or nil when the chain breaks.
    private func originalAncestorFilename(of entry: VaultEntry) -> String? {
        var current = entry
        var hops = 0
        while hops < 16 {
            if current.kind == .original {
                return current.originalFilename
            }
            guard
                let sourceHandle = current.sourceHandle,
                let parent = try? self.entry(handle: sourceHandle)
            else {
                return nil
            }
            current = parent
            hops += 1
        }
        return nil
    }

    /// The first free outbox URL of the form base.ext, base-2.ext, and so on.
    private func firstFreeOutboxURL(base: String, ext: String) -> URL {
        var candidateBase = base
        var counter = 1
        while true {
            let url = outboxDirectory.appendingPathComponent("\(candidateBase).\(ext)")
            if !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            counter += 1
            candidateBase = "\(base)-\(counter)"
        }
    }

    // MARK: - Registry persistence

    /// The registry file payload. Versioned so phase 5 can migrate it.
    private struct Registry: Codable {
        var version: Int
        var entries: [VaultEntry]

        static let currentVersion = 1
        static let empty = Registry(version: currentVersion, entries: [])
    }

    /// Load the registry, treating a missing file as empty. Called with the
    /// registry lock held. FileManager.contents is deliberate: unlike
    /// Data(contentsOf:) it has no remote-URL capability, so the network
    /// chokepoint scan stays clean.
    private func loadRegistryLocked() throws -> Registry {
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            return .empty
        }
        guard
            let data = FileManager.default.contents(atPath: registryURL.path),
            let registry = try? JSONDecoder().decode(Registry.self, from: data)
        else {
            throw DocumentVaultError.corruptRegistry
        }
        return registry
    }

    /// Write the registry atomically so a crash never leaves a torn file.
    /// Called with the registry lock held.
    private func saveRegistryLocked(_ registry: Registry) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(registry)
        try data.write(to: registryURL, options: [.atomic])
    }

    // MARK: - Handles

    /// Bytes of randomness per handle: 12 hex characters.
    private static let handleRandomByteCount = 6

    /// Allocate a fresh handle for the kind: prefix plus cryptographically
    /// random hex, retried on the (astronomically unlikely) collision. Called
    /// with the registry lock held.
    private func allocateHandleLocked(
        kind: VaultArtifactKind,
        registry: Registry
    ) throws -> String {
        let taken = Set(registry.entries.map(\.handle))
        for _ in 0 ..< 8 {
            let handle = try DocumentVault.randomHandle(prefix: kind.handlePrefix)
            let directory = objectsDirectory.appendingPathComponent(handle)
            if !taken.contains(handle),
               !FileManager.default.fileExists(atPath: directory.path) {
                return handle
            }
        }
        throw DocumentVaultError.randomnessUnavailable
    }

    /// prefix plus 12 random hex characters from the system CSPRNG.
    static func randomHandle(prefix: String) throws -> String {
        var bytes = [UInt8](repeating: 0, count: handleRandomByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw DocumentVaultError.randomnessUnavailable
        }
        return prefix + bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    /// The scope noun vault operations use in the security event log.
    static let auditScope = "Document vault"

    /// Normalize a filename extension to the vault's format vocabulary. The
    /// extension itself can carry matter information, so anything outside the
    /// known set collapses to "txt" (the importer treats unknown extensions as
    /// text anyway, so this is behavior-preserving).
    static func normalizedFormat(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "docx": return "docx"
        case "pdf": return "pdf"
        case "md", "markdown": return "md"
        default: return "txt"
        }
    }

    /// The size of a file in bytes.
    private static func fileByteCount(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int) ?? 0
    }

    /// The vault-relative path of a URL, throwing when it is not inside the
    /// vault (a produced artifact must never point outside).
    private func vaultRelativePath(of url: URL) throws -> String {
        let rootPath = rootDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidate.hasPrefix(prefix) else {
            throw DocumentVaultError.artifactOutsideVault
        }
        return String(candidate.dropFirst(prefix.count))
    }
}
