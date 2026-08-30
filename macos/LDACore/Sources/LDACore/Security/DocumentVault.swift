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
//    registry.sealed               the encrypted handle registry (atomic writes)
//    objects/<handle>/...          one directory per staged or derived artifact
//    outbox/                       where exported artifacts land for the human
//    scratch/                      short-lived decrypted copies, removed after use
//
//  Naming rule: nothing inside objects/ may derive from the original filename.
//  A staged original is stored as "original.<format>"; derived artifacts are
//  named by their producers from that neutral base. The original filename
//  survives ONLY in the registry, reserved for human-facing export naming,
//  and must never be returned through any MCP tool.
//
//  Encryption posture (phase 5): every stored object and the registry are
//  AES-256-GCM EncryptedContainer blobs; cat on any file under the vault
//  returns ciphertext. The one deliberate exit is the outbox, where export
//  writes the DECRYPTED artifact for the human. Mapping sidecars are already
//  containers of their own kind and are stored as their producers wrote them.
//  Key handling lives entirely in DocumentVaultEncryption.swift so phase 6
//  (XPC key holding) changes one file. A vault written by the plaintext phase
//  4 layout (registry.json plus plaintext objects) migrates in place on first
//  open. The outbox is exempt from encryption; nothing else is.
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
    /// A decrypted scratch copy could not be created inside the vault.
    case scratchWriteFailed

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
        case .scratchWriteFailed:
            return "scratch_write_failed: a temporary decrypted copy could not be created"
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

    /// File and directory names inside the vault root. registry.json is the
    /// pre-encryption plaintext registry, kept as a name ONLY so its presence
    /// can be detected and migrated; the live registry is registry.sealed.
    public static let registryFileName = "registry.json"
    public static let sealedRegistryFileName = "registry.sealed"
    public static let objectsDirectoryName = "objects"
    public static let outboxDirectoryName = "outbox"
    public static let scratchDirectoryName = "scratch"

    /// Where the vault lives.
    public let rootDirectory: URL

    /// How the vault master key is held. Injectable so tests run on a
    /// passphrase and never touch the real Keychain; the default resolves to
    /// the Keychain master key account (see DocumentVaultEncryption.swift).
    let protection: MappingProtection

    /// Serializes registry read-modify-write cycles within this process.
    private static let registryLock = NSLock()

    public init(
        rootDirectory: URL,
        protection: MappingProtection = DocumentVault.defaultProtection()
    ) {
        self.rootDirectory = rootDirectory
        self.protection = protection
    }

    /// Open the vault the environment selects: LDA_VAULT_DIR for the root
    /// (else Application Support/LDA/Vault, the same app-support base the
    /// other stores use) and LDA_VAULT_PASSPHRASE for the key protection
    /// (else the Keychain master key).
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(
            rootDirectory: DocumentVault.rootDirectory(environment: environment),
            protection: DocumentVault.defaultProtection(environment: environment)
        )
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

    /// The live, encrypted registry.
    private var sealedRegistryURL: URL {
        rootDirectory.appendingPathComponent(DocumentVault.sealedRegistryFileName)
    }

    /// The pre-encryption plaintext registry. Its presence means the vault was
    /// written by the plaintext phase and must migrate before any operation.
    private var plaintextRegistryURL: URL {
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
            !isDirectory.boolValue,
            let plaintext = FileManager.default.contents(atPath: fileURL.path)
        else {
            throw DocumentVaultError.sourceUnreadable
        }

        let format = DocumentVault.normalizedFormat(forExtension: fileURL.pathExtension)
        // Neutral metadata comes from the plaintext BEFORE sealing: byteCount
        // records the document size (not the container size) and the PDF page
        // count is read from the in-memory bytes.
        let pageCount = format == "pdf" ? PDFDocument(data: plaintext)?.pageCount : nil

        let entry: VaultEntry = try DocumentVault.registryLock.withLock {
            var registry = try loadRegistryLocked()
            let handle = try allocateHandleLocked(kind: .original, registry: registry)

            let directory = objectsDirectory.appendingPathComponent(handle, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let storedName = "original.\(format)"
            let storedURL = directory.appendingPathComponent(storedName)
            try sealObjectData(plaintext, to: storedURL)

            let entry = VaultEntry(
                handle: handle,
                kind: .original,
                format: format,
                byteCount: plaintext.count,
                pageCount: pageCount,
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
    /// vault-relative locations plus neutral metadata. The primary file is
    /// sealed in place (producers write plaintext; the vault owns encryption),
    /// while the mapping file is recorded untouched: it is already an
    /// encrypted container of its own kind with its own key.
    ///
    /// The mapping file may live in ANOTHER entry's directory: a session
    /// shares one sidecar across all of its redacted artifacts.
    ///
    /// Any OTHER file the producer left in the slot directory is removed: it
    /// is not registered, so nothing could ever read it back, and leaving it
    /// would keep producer plaintext (a review PDF, a companion) in the vault
    /// forever.
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
        guard let plaintext = FileManager.default.contents(atPath: primaryFile.path) else {
            throw DocumentVaultError.sourceUnreadable
        }
        let pageCount = format == "pdf" ? PDFDocument(data: plaintext)?.pageCount : nil

        try sealObjectData(plaintext, to: primaryFile)
        sweepUncommittedFiles(
            in: slot.directory,
            keeping: [primaryFile, mappingFile].compactMap { $0 }
        )

        let entry = VaultEntry(
            handle: slot.handle,
            kind: slot.kind,
            format: format,
            byteCount: plaintext.count,
            pageCount: pageCount,
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

    /// Remove everything in a slot directory except the files being committed.
    /// Best-effort: a failure to remove a stray never fails the commit, and
    /// the boundary regression test scans the tree afterwards anyway.
    private func sweepUncommittedFiles(in directory: URL, keeping keep: [URL]) {
        let keptPaths = Set(keep.map {
            $0.standardizedFileURL.resolvingSymlinksInPath().path
        })
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for child in children {
            let path = child.standardizedFileURL.resolvingSymlinksInPath().path
            if !keptPaths.contains(path) {
                try? FileManager.default.removeItem(at: child)
            }
        }
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

    /// Read and decrypt the stored bytes of an entry, entirely in memory: no
    /// plaintext touches the disk on this path.
    public func readDocumentBytes(handle: String) throws -> Data {
        try openObjectData(for: entry(handle: handle))
    }

    /// Decrypt the entry to a short-lived scratch file INSIDE the vault root
    /// (owner-only permissions), run body over its URL, and remove the file
    /// afterward, throw or return. Callers must not retain the URL past body.
    public func withPlaintextFileURL<T>(
        handle: String,
        _ body: (URL) throws -> T
    ) throws -> T {
        let found = try entry(handle: handle)
        return try withScratchPlaintext(entries: [found]) { urls in
            try body(urls[0])
        }
    }

    /// The plural form for pipelines that consume several documents at once
    /// (a session). Same contract as withPlaintextFileURL.
    public func withPlaintextFileURLs<T>(
        handles: [String],
        _ body: ([URL]) throws -> T
    ) throws -> T {
        let found = try handles.map { try entry(handle: $0) }
        return try withScratchPlaintext(entries: found, body)
    }

    /// The mapping sidecar location for a redacted entry. The sidecar is an
    /// encrypted container of its own kind (LDAMAP), so its raw URL is safe to
    /// hand to MappingStore without a scratch decryption step.
    public func mappingFileURL(forHandle handle: String) throws -> URL {
        let found = try entry(handle: handle)
        guard let relative = found.mappingRelativePath else {
            throw DocumentVaultError.missingMapping(handle)
        }
        return rootDirectory.appendingPathComponent(relative)
    }

    // MARK: - Export

    /// Write the DECRYPTED bytes of a redacted or restored artifact into the
    /// outbox, named after the original document it derives from (the one
    /// place the original filename is used). The outbox is the deliberate
    /// human-facing exit and the only place the vault emits plaintext.
    /// Originals are refused: the vault never re-emits a source document.
    /// Returns the outbox file URL for HUMAN-facing edges (CLI, GUI); MCP
    /// responses must not include it.
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

        let plaintext = try openObjectData(for: found)
        try FileManager.default.createDirectory(
            at: outboxDirectory,
            withIntermediateDirectories: true
        )

        let baseName = exportBaseName(for: found)
        let destination = firstFreeOutboxURL(base: baseName, ext: found.format)
        try plaintext.write(to: destination, options: [.atomic])
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

    /// Load the registry, treating a missing file as empty. A plaintext
    /// registry.json on disk means the vault was written by the pre-encryption
    /// phase; it is migrated in place FIRST, so no operation ever runs over an
    /// unencrypted store. Called with the registry lock held.
    /// FileManager.contents is deliberate: unlike Data(contentsOf:) it has no
    /// remote-URL capability, so the network chokepoint scan stays clean.
    private func loadRegistryLocked() throws -> Registry {
        if FileManager.default.fileExists(atPath: plaintextRegistryURL.path) {
            return try migrateFromPlaintextFormLocked()
        }
        guard FileManager.default.fileExists(atPath: sealedRegistryURL.path) else {
            return .empty
        }
        let data = try DocumentVault.registryContainer.load(
            from: sealedRegistryURL,
            protection: protection
        )
        guard let registry = try? JSONDecoder().decode(Registry.self, from: data) else {
            throw DocumentVaultError.corruptRegistry
        }
        return registry
    }

    /// Encrypt and write the registry. The container writes atomically, so a
    /// crash never leaves a torn file. Called with the registry lock held.
    private func saveRegistryLocked(_ registry: Registry) throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(registry)
        try DocumentVault.registryContainer.save(
            data,
            to: sealedRegistryURL,
            protection: protection
        )
    }

    /// Migrate a plaintext-form vault (registry.json plus plaintext objects)
    /// to the encrypted form, in place and without losing entries: seal every
    /// object the registry names, write the sealed registry, then remove the
    /// plaintext registry LAST. The steps are idempotent, so a crash mid-way
    /// resumes on the next open (an object already carrying the container
    /// magic is skipped rather than double-wrapped). Mapping sidecars are
    /// containers of their own kind already and are left untouched. Called
    /// with the registry lock held.
    private func migrateFromPlaintextFormLocked() throws -> Registry {
        guard
            let data = FileManager.default.contents(atPath: plaintextRegistryURL.path),
            let registry = try? JSONDecoder().decode(Registry.self, from: data)
        else {
            throw DocumentVaultError.corruptRegistry
        }

        for entry in registry.entries {
            let url = rootDirectory.appendingPathComponent(entry.relativePath)
            guard let bytes = FileManager.default.contents(atPath: url.path) else {
                // A missing object cannot be sealed; the entry survives and a
                // later read of it fails exactly as it would have before.
                continue
            }
            if bytes.starts(with: DocumentVault.objectMagic) {
                // Already sealed by an interrupted earlier migration run. (A
                // plaintext document beginning with the magic bytes would be
                // skipped too and then fail closed on read; a real document
                // starting with "LDAVOBJ" does not occur in practice.)
                continue
            }
            try sealObjectData(bytes, to: url)
        }

        try saveRegistryLocked(registry)
        try FileManager.default.removeItem(at: plaintextRegistryURL)
        SecurityEventLog.shared.record(
            kind: .vaultMigratedToEncryptedForm,
            scope: DocumentVault.auditScope
        )
        return registry
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
