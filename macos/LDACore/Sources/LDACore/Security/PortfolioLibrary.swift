//
//  PortfolioLibrary.swift
//  LDACore
//
//  Encrypted portfolio directory backed by two distinct AES-GCM containers:
//
//    Portfolio files  -- LDAPROF magic, service "ai.openclaw.lda.profilekey",
//                        account "library". One file per portfolio:
//                        <root>/<uuid>.ldaprofile. Uses the shared ProfileStore
//                        encode/decode helpers (promoted to internal so they are
//                        reused here rather than duplicated).
//
//    Index file       -- LDAPIDX magic (NEW), service "ai.openclaw.lda.libraryindexkey"
//                        (NEW, distinct per the EncryptedContainer rule), account
//                        "index". Single file: <root>/index.ldapidx. Holds
//                        [PortfolioSummary] in JSON.
//
//  Atomicity: each write (portfolio file or index) goes through
//  EncryptedContainer.save, which calls Data.write(to:options:[.atomic]). On
//  Apple platforms that writes to a kernel-chosen temp file then renames it
//  atomically. "Atomicity" here means per-write atomicity (the file is either
//  the old version or the new version; no partial write is visible). It does NOT
//  mean that a portfolio-file write and the subsequent index write are atomic as
//  a unit. A crash between the two can leave the index with a stale summary for
//  an entry whose file was successfully written; reconciliation detects and heals
//  that drift on the next call to list(). See save() for details.
//
//  Purity: timestamps must be caller-supplied. PortfolioLibrary never reads the
//  clock.
//
//  Concurrency contract: use one PortfolioLibrary instance from one actor or
//  serial queue. Cross-process read-only listing (reading index bytes without
//  calling list()) is tolerated; if another process modifies the directory
//  concurrently, reconciliation on the next list() call will heal the drift.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - PortfolioSummary

/// A lightweight snapshot of a portfolio, held in the encrypted index.
/// list() returns these without decrypting any individual portfolio file.
///
/// Note: placeholder summaries (surfaced for undecryptable orphan files) have
/// empty strings for createdAtISO8601 and modifiedAtISO8601 and zero fieldCount.
/// Callers should treat empty timestamp strings as "unknown".
public struct PortfolioSummary: Equatable, Sendable, Codable {
    public var id: UUID
    public var label: String
    public var kind: PortfolioKind
    public var createdAtISO8601: String
    public var modifiedAtISO8601: String
    public var fieldCount: Int
    public var conflicted: Bool

    public init(
        id: UUID,
        label: String,
        kind: PortfolioKind,
        createdAtISO8601: String,
        modifiedAtISO8601: String,
        fieldCount: Int,
        conflicted: Bool
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.createdAtISO8601 = createdAtISO8601
        self.modifiedAtISO8601 = modifiedAtISO8601
        self.fieldCount = fieldCount
        self.conflicted = conflicted
    }
}

// MARK: - PortfolioResolutionError

/// Errors from portfolio name/id resolution. Defined in LDACore so both the
/// CLI edge (LDACLI) and the MCP edge (LDAMCP) can share the same resolution
/// logic without either edge depending on the other.
public enum PortfolioResolutionError: Error, CustomStringConvertible, Sendable {
    /// No portfolio with the given name or UUID was found.
    case notFound(String)
    /// The label matched more than one portfolio; lists candidate labels.
    case ambiguous(nameOrID: String, candidates: [String])

    public var description: String {
        switch self {
        case .notFound(let nameOrID):
            return "No portfolio found matching '\(nameOrID)'."
        case .ambiguous(let nameOrID, let candidates):
            let list = candidates.joined(separator: ", ")
            return "Multiple portfolios match '\(nameOrID)': \(list). Use the portfolio UUID for an exact match."
        }
    }
}

// MARK: - Portfolio resolution helper

extension PortfolioLibrary {
    /// Resolve a name-or-id string to a (UUID, PortfolioSummary) pair.
    ///
    /// Resolution order:
    ///   1. Exact UUID match (uuidString comparison).
    ///   2. Case-insensitive full-label match. Unique succeeds; multiple throws
    ///      PortfolioResolutionError.ambiguous; zero throws .notFound.
    ///
    /// This is a static helper so callers can resolve against a pre-fetched
    /// summaries array without creating a second PortfolioLibrary instance.
    public static func resolve(
        nameOrID: String,
        from summaries: [PortfolioSummary]
    ) throws -> (UUID, PortfolioSummary) {
        // 1. Exact UUID match.
        if let uuid = UUID(uuidString: nameOrID),
           let summary = summaries.first(where: { $0.id == uuid }) {
            return (uuid, summary)
        }

        // 2. Case-insensitive label match.
        let lower = nameOrID.lowercased()
        let matches = summaries.filter { $0.label.lowercased() == lower }
        switch matches.count {
        case 0:
            throw PortfolioResolutionError.notFound(nameOrID)
        case 1:
            return (matches[0].id, matches[0])
        default:
            let candidates = matches.map { $0.label }
            throw PortfolioResolutionError.ambiguous(nameOrID: nameOrID, candidates: candidates)
        }
    }
}

// MARK: - PortfolioLibrary errors

/// Errors specific to the PortfolioLibrary layer.
public enum PortfolioLibraryError: Error, LocalizedError, Sendable {
    /// The caller attempted to export a portfolio to a path inside the library directory.
    case exportDestinationInsideLibrary

    public var errorDescription: String? {
        switch self {
        case .exportDestinationInsideLibrary:
            return "Export destination must be outside the portfolio library directory."
        }
    }
}

// MARK: - PortfolioLibrary

/// A directory-backed encrypted portfolio store.
///
/// All on-disk bytes are encrypted with AES-GCM. Portfolio files use the LDAPROF
/// container (same magic and Keychain service as ProfileStore) under a fixed
/// account "library". The index uses a new LDAPIDX container with its own
/// distinct Keychain service (per the EncryptedContainer RULE: distinct magic
/// AND service per store kind).
///
/// list() is efficient: it decrypts only the index, not the portfolio files.
/// Individual portfolio data is decrypted only by load(id:).
///
/// Concurrency: one instance from one actor or serial queue. See file header.
public final class PortfolioLibrary {

    // MARK: - Containers
    //
    // Portfolio container reuses the ProfileStore magic and Keychain service.
    // A fixed account "library" is used for all portfolio files (as opposed to
    // per-file accounts), because the library manages UUID-named files and the
    // caller never needs to derive the account from a file URL.
    //
    // The index container uses a NEW magic ("LDAPIDX") and a NEW Keychain service
    // ("ai.openclaw.lda.libraryindexkey") so that an index file is cryptographically
    // rejected by the portfolio loader and vice versa, enforcing store-level isolation.

    private let portfolioContainer = EncryptedContainer(
        magic: Array("LDAPROF".utf8),
        keychainService: "ai.openclaw.lda.profilekey",
        containerDescription: "Profile file"
    )

    private let indexContainer = EncryptedContainer(
        magic: Array("LDAPIDX".utf8),
        keychainService: "ai.openclaw.lda.libraryindexkey",
        containerDescription: "Portfolio index"
    )

    // MARK: - Root directory

    private let root: URL

    // MARK: - Reconciliation flag

    /// True when the most recent call to list() had to rebuild or prune the index
    /// (due to a missing or corrupt index file, or a mismatch between the index
    /// entries and the files on disk). False after a clean list() that found no
    /// drift. This is the one-time-notice channel: callers should check this flag
    /// immediately after list() and clear their notice state; the next call to
    /// list() will set or clear it again.
    public private(set) var lastListReconciled: Bool = false

    // MARK: - Index persist failure flag

    /// True when the most recent attempt to write the index inside
    /// readIndexOrRebuild (the swallowed try? writeIndex) threw. Cleared on the
    /// next successful index write (save, delete, appendToIndex, or a successful
    /// reconciliation rewrite).
    ///
    /// UI guidance: a persistently true value after repeated list() calls indicates
    /// that the Keychain key for the index container is unavailable or that the
    /// library directory has become unwritable. The in-memory summaries returned by
    /// list() are still correct; only the on-disk index is stale, meaning every
    /// future list() will re-reconcile. Surface a non-blocking advisory to the user
    /// if this flag remains set across multiple sessions.
    public private(set) var lastIndexPersistFailed: Bool = false

    // MARK: - Keychain accounts (fixed)

    private static let portfolioAccount = "library"
    private static let indexAccount = "index"

    // MARK: - File naming

    private static let portfolioExtension = "ldaprofile"
    private static let indexFilename = "index.ldapidx"

    // MARK: - Initializer

    /// Creates or opens the library at rootDirectory.
    ///
    /// - Parameter rootDirectory: The directory that holds portfolio files and the
    ///   index. When nil the production default
    ///   (<applicationSupport>/LDA/Portfolios) is used. The directory is created
    ///   on first use if it does not exist.
    public init(rootDirectory: URL? = nil) throws {
        if let provided = rootDirectory {
            self.root = provided
        } else {
            let appSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.root = appSupport
                .appendingPathComponent("LDA", isDirectory: true)
                .appendingPathComponent("Portfolios", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Returns all portfolios sorted by label (stable tiebreak by UUID string).
    ///
    /// Decrypts only the index. Individual portfolio files are NOT decrypted.
    /// If the index is missing or corrupt, or if drift between the index and
    /// the directory is detected, the index is rebuilt from the portfolio files
    /// and lastListReconciled is set to true. On a clean read lastListReconciled
    /// is false.
    ///
    /// Throws when the directory cannot be enumerated (an unreadable library is
    /// an error, not an empty list).
    public func list() throws -> [PortfolioSummary] {
        let (summaries, reconciled) = try readIndexOrRebuild()
        lastListReconciled = reconciled
        return summaries.sorted {
            let cmp = $0.label.localizedCaseInsensitiveCompare($1.label)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Creates a new portfolio in the library and returns its UUID.
    ///
    /// The portfolio file is written first. The index is updated (upsert by id)
    /// only after the file write succeeds.
    public func create(_ portfolio: ClientPortfolio) throws -> UUID {
        let id = UUID()
        let summary = makeSummary(id: id, portfolio: portfolio)
        try writePortfolioFile(portfolio, id: id)
        try appendToIndex(summary)
        return id
    }

    /// Loads and returns the full portfolio for id.
    ///
    /// On a successful load, the index entry is healed if its summary is stale
    /// (e.g. a crash between file write and index write left a mismatched label or
    /// timestamp). This is the cheap heal path: the file is already decrypted, so
    /// comparing and rewriting costs little.
    ///
    /// Throws DocumentIOError.unreadable when the file does not exist, or
    /// DocumentIOError.decryptionFailed / .corrupt for a tampered or
    /// undecryptable file.
    public func load(id: UUID) throws -> ClientPortfolio {
        let url = portfolioURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DocumentIOError.unreadable("Portfolio \(id.uuidString) not found in library")
        }
        let plaintext = try portfolioContainer.load(
            from: url,
            protection: .keychain(account: Self.portfolioAccount)
        )
        let portfolio = try ProfileStore.decodeProfile(plaintext)

        // Cheap heal: if the index entry for this id does not match the file
        // content (e.g. a crash between file write and index write left a stale
        // summary), rewrite the index now. The file is already decrypted so this
        // adds minimal overhead. The full reconcile path (readIndexOrRebuild) also
        // heals this case on the next list(), but healing eagerly avoids surfacing
        // stale data to callers between the crash and the next list().
        healIndexEntry(id: id, portfolio: portfolio)

        return portfolio
    }

    /// Saves (upserts) the portfolio for id and updates the index.
    ///
    /// Upsert semantics: if id already has an entry in the index it is replaced;
    /// if not, a new entry is appended. This means save() is safe to call for
    /// both updates and creates (e.g. after importPortfolio assigns a new UUID).
    ///
    /// The portfolio file is written first using per-write atomic I/O
    /// (EncryptedContainer.save calls Data.write with .atomic). The index is
    /// updated only after the file write succeeds. A crash between the two leaves
    /// a stale index entry; the next successful load(id:) or list() heals it.
    public func save(_ portfolio: ClientPortfolio, id: UUID) throws {
        try writePortfolioFile(portfolio, id: id)
        let summary = makeSummary(id: id, portfolio: portfolio)
        var summaries = loadRawIndex()
        if let idx = summaries.firstIndex(where: { $0.id == id }) {
            summaries[idx] = summary
        } else {
            summaries.append(summary)
        }
        try writeIndex(summaries)
        lastIndexPersistFailed = false
    }

    /// Deletes the portfolio file for id and removes the entry from the index.
    ///
    /// A missing file for the given id is ignored (the index entry is still
    /// cleaned up). Any other file-removal failure (permission error, I/O error,
    /// etc.) is propagated BEFORE the index is touched, so a failed delete never
    /// orphans the file into the "dangling file, no index entry" state.
    ///
    /// The index entry is always removed when the file removal succeeds or the
    /// file was already absent.
    public func delete(id: UUID) throws {
        let url = portfolioURL(for: id)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            // Ignore "file not found" -- the index cleanup below still runs.
            let isNotFound = (error as? CocoaError)?.code == .fileNoSuchFile
                || (error as NSError).code == NSFileNoSuchFileError
            if !isNotFound {
                // Propagate real removal failures before touching the index.
                // This prevents the file from being silently resurrected on the
                // next reconciliation (file present, no index entry -> re-added).
                throw error
            }
        }

        var summaries = loadRawIndex()
        summaries.removeAll { $0.id == id }
        try writeIndex(summaries)
        lastIndexPersistFailed = false
    }

    /// Exports the portfolio at id to url, re-encrypting under the given protection.
    ///
    /// Throws PortfolioLibraryError.exportDestinationInsideLibrary when url is
    /// inside the library root directory (including any subdirectory of the root).
    public func exportPortfolio(id: UUID, to url: URL, protection: MappingProtection) throws {
        try assertNotInsideLibrary(url)
        let portfolio = try load(id: id)
        let plaintext = try ProfileStore.encodeProfile(portfolio)
        try portfolioContainer.save(plaintext, to: url, protection: protection)
    }

    /// Imports a portfolio from url (decrypting under protection) and stores it
    /// in the library. Returns the new UUID assigned to the imported portfolio.
    ///
    /// Legacy JSON payloads without "kind" or "modifiedAtISO8601" are decoded
    /// with kind = .company and modifiedAt = createdAt (see ClientPortfolio.init
    /// from decoder for the backward-compatible defaults).
    public func importPortfolio(from url: URL, protection: MappingProtection) throws -> UUID {
        let plaintext = try portfolioContainer.load(from: url, protection: protection)
        let portfolio = try ProfileStore.decodeProfile(plaintext)
        return try create(portfolio)
    }

    /// Imports a portfolio from url using the ProfileStore keychain fallback chain,
    /// then stores it in the library re-encrypted under the library key.
    ///
    /// Use this for Keychain-protected imports when the file may have been saved by
    /// any prior UI edge (pre-portal UI stored the account as the file name WITH
    /// extension; the portal UI uses the name WITHOUT extension; the CLI and MCP had
    /// their own prefixes). ProfileStore.loadWithAccountFallback tries all four
    /// account formats in priority order so legacy .ldaprofile files that fail a
    /// simple standardAccount lookup are still importable.
    ///
    /// Passphrase-protected imports do not need the fallback and should continue
    /// to call importPortfolio(from:protection:) directly.
    public func importPortfolioWithKeychainFallback(from url: URL) throws -> UUID {
        let portfolio = try ProfileStore.loadWithAccountFallback(from: url)
        return try create(portfolio)
    }

    // MARK: - Private helpers: file layout

    private func portfolioURL(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).\(Self.portfolioExtension)")
    }

    private var indexURL: URL {
        root.appendingPathComponent(Self.indexFilename)
    }

    // MARK: - Private helpers: summary construction

    private func makeSummary(id: UUID, portfolio: ClientPortfolio) -> PortfolioSummary {
        PortfolioSummary(
            id: id,
            label: portfolio.label,
            kind: portfolio.kind,
            createdAtISO8601: portfolio.createdAtISO8601,
            modifiedAtISO8601: portfolio.modifiedAtISO8601,
            fieldCount: portfolio.fields.count,
            conflicted: !portfolio.conflictedKeys.isEmpty
        )
    }

    // MARK: - Private helpers: portfolio file I/O

    private func writePortfolioFile(_ portfolio: ClientPortfolio, id: UUID) throws {
        let plaintext = try ProfileStore.encodeProfile(portfolio)
        // EncryptedContainer.save uses Data.write(to:options:[.atomic]), which on
        // Apple platforms atomically replaces the destination via a kernel-managed
        // temp file. No additional temp-then-rename is needed at this layer.
        try portfolioContainer.save(
            plaintext,
            to: portfolioURL(for: id),
            protection: .keychain(account: Self.portfolioAccount)
        )
    }

    // MARK: - Private helpers: index I/O

    /// Loads the raw index entries, returning an empty array on any failure.
    ///
    /// Missing file: returns []. The caller (save/delete/appendToIndex) will
    /// write a fresh index.
    ///
    /// Read or decrypt failure: also returns []. This is intentional; the index
    /// is a performance cache and reconciliation (readIndexOrRebuild) heals it on
    /// the next list(). Throwing here would break save/delete for a caller who has
    /// valid data in hand.
    private func loadRawIndex() -> [PortfolioSummary] {
        guard let plaintext = try? indexContainer.load(
            from: indexURL,
            protection: .keychain(account: Self.indexAccount)
        ) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([PortfolioSummary].self, from: plaintext)) ?? []
    }

    private func writeIndex(_ summaries: [PortfolioSummary]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext: Data
        do {
            plaintext = try encoder.encode(summaries)
        } catch {
            throw DocumentIOError.corrupt("Failed to encode portfolio index: \(error)")
        }
        // EncryptedContainer.save is already atomic (see atomicity note in file header).
        try indexContainer.save(
            plaintext,
            to: indexURL,
            protection: .keychain(account: Self.indexAccount)
        )
    }

    /// Upserts summary into the index (replaces an existing entry with the same id,
    /// or appends if not found). Used by create().
    private func appendToIndex(_ summary: PortfolioSummary) throws {
        var summaries = loadRawIndex()
        if let idx = summaries.firstIndex(where: { $0.id == summary.id }) {
            // Upsert: replace the existing entry rather than duplicating it.
            // This can happen if create() is called for an id that somehow already
            // appears in the index (e.g. a prior create() crashed after the file
            // write but before the index write, then the caller retried with the
            // same UUID -- unlikely but safe to handle).
            summaries[idx] = summary
        } else {
            summaries.append(summary)
        }
        try writeIndex(summaries)
        lastIndexPersistFailed = false
    }

    // MARK: - Private helpers: summary heal

    /// Compares the current index entry for id against a freshly built summary
    /// from the given portfolio and rewrites the index if they differ.
    ///
    /// Called by load(id:) after a successful decrypt. Because the file is already
    /// in memory at that point, the comparison and optional rewrite cost little.
    /// This heals the "stale summary" case that arises when a crash occurs between
    /// a file write and the subsequent index write inside save().
    private func healIndexEntry(id: UUID, portfolio: ClientPortfolio) {
        let fresh = makeSummary(id: id, portfolio: portfolio)
        var summaries = loadRawIndex()
        guard let idx = summaries.firstIndex(where: { $0.id == id }) else {
            // No index entry at all; reconciliation on the next list() will add it.
            return
        }
        guard summaries[idx] != fresh else {
            // Entry is already up to date.
            return
        }
        summaries[idx] = fresh
        if (try? writeIndex(summaries)) != nil {
            lastIndexPersistFailed = false
        }
    }

    // MARK: - Private helpers: reconciling list

    /// Reads and reconciles the index against the directory.
    ///
    /// Returns the (possibly rebuilt) summaries and a flag indicating whether
    /// reconciliation was needed. This is the only path that writes the index;
    /// all other writes go through writeIndex directly.
    ///
    /// Reconciliation rules:
    /// 1. If the index is missing or corrupt, rebuild from files.
    /// 2. If an index entry has no corresponding file, drop it (reconcile = true).
    /// 3. If a decryptable file has no index entry, re-add it with its real label
    ///    (reconcile = true).
    /// 4. If an undecryptable file has no index entry, surface it with a
    ///    placeholder label; load(id:) for that entry will throw (reconcile = true
    ///    because an orphan was found).
    private func readIndexOrRebuild() throws -> (summaries: [PortfolioSummary], reconciled: Bool) {
        // Enumerate .ldaprofile files in the directory (non-recursive; ignore
        // .tmp files and non-.ldaprofile files such as index.ldapidx).
        // Propagate enumeration failure: an unreadable library is an error, not
        // an empty list.
        let directoryContents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )

        let portfolioFiles: [URL] = directoryContents.filter { url in
            // Accept only UUID-named .ldaprofile files. Exclude .tmp files and
            // the index file. A valid portfolio filename is exactly
            // "<UUID>.ldaprofile" (36-char UUID string + ".ldaprofile").
            guard url.pathExtension == Self.portfolioExtension else { return false }
            let stem = url.deletingPathExtension().lastPathComponent
            return UUID(uuidString: stem) != nil
        }

        let filesOnDisk: Set<UUID> = Set(portfolioFiles.compactMap {
            UUID(uuidString: $0.deletingPathExtension().lastPathComponent)
        })

        // Attempt to load the index.
        let indexPlaintext: Data?
        if FileManager.default.fileExists(atPath: indexURL.path) {
            indexPlaintext = try? indexContainer.load(
                from: indexURL,
                protection: .keychain(account: Self.indexAccount)
            )
        } else {
            indexPlaintext = nil
        }

        let existingEntries: [PortfolioSummary]
        let indexMissingOrCorrupt: Bool

        if let plaintext = indexPlaintext,
           let decoded = try? JSONDecoder().decode([PortfolioSummary].self, from: plaintext) {
            existingEntries = decoded
            indexMissingOrCorrupt = false
        } else {
            existingEntries = []
            indexMissingOrCorrupt = true
        }

        // Build a lookup from UUID to existing summary. Use uniquingKeysWith to
        // tolerate a corrupt index that contains duplicate ids (last writer wins).
        var indexByID: [UUID: PortfolioSummary] = Dictionary(
            existingEntries.map { ($0.id, $0) },
            uniquingKeysWith: { _, new in new }
        )
        let indexIDs = Set(indexByID.keys)

        var reconciled = indexMissingOrCorrupt

        // Rule 2: prune index entries whose files are gone.
        let missingFromDisk = indexIDs.subtracting(filesOnDisk)
        if !missingFromDisk.isEmpty {
            reconciled = true
            for id in missingFromDisk {
                indexByID.removeValue(forKey: id)
            }
        }

        // Rule 3 and 4: handle files with no index entry.
        let missingFromIndex = filesOnDisk.subtracting(indexIDs)
        if !missingFromIndex.isEmpty {
            reconciled = true
            for id in missingFromIndex {
                if let summary = tryBuildSummary(for: id) {
                    // Rule 3: decryptable orphan rejoins with its real label.
                    indexByID[id] = summary
                } else {
                    // Rule 4: undecryptable orphan surfaces with a placeholder label.
                    // load(id:) for this entry will throw; delete(id:) will clean it up.
                    let shortID = String(id.uuidString.prefix(8))
                    let placeholder = PortfolioSummary(
                        id: id,
                        label: "Recovered portfolio \(shortID)",
                        kind: .general,
                        createdAtISO8601: "",
                        modifiedAtISO8601: "",
                        fieldCount: 0,
                        conflicted: false
                    )
                    indexByID[id] = placeholder
                }
            }
        }

        let finalSummaries = Array(indexByID.values)

        // Rewrite the index when drift was found so subsequent calls are clean.
        // We swallow the write error here rather than propagating it, because:
        //   (1) The read result is valid; throwing would fail the caller while
        //       correct data is already in memory.
        //   (2) lastListReconciled being true on repeated calls is the observable
        //       signal of persistent drift -- the UI can act on lastIndexPersistFailed
        //       to surface a non-blocking advisory.
        if reconciled {
            if (try? writeIndex(finalSummaries)) != nil {
                lastIndexPersistFailed = false
            } else {
                lastIndexPersistFailed = true
            }
        }

        return (finalSummaries, reconciled)
    }

    /// Attempts to decrypt and build a PortfolioSummary from a portfolio file.
    /// Returns nil when the file is undecryptable or cannot be parsed.
    private func tryBuildSummary(for id: UUID) -> PortfolioSummary? {
        let url = portfolioURL(for: id)
        guard let plaintext = try? portfolioContainer.load(
            from: url,
            protection: .keychain(account: Self.portfolioAccount)
        ),
        let portfolio = try? ProfileStore.decodeProfile(plaintext) else {
            return nil
        }
        return makeSummary(id: id, portfolio: portfolio)
    }

    // MARK: - Private helpers: export guard

    /// Throws PortfolioLibraryError.exportDestinationInsideLibrary when the
    /// destination is inside the library root directory. Uses
    /// resolvingSymlinksInPath on both sides so that symlinks into the library
    /// directory are also rejected.
    private func assertNotInsideLibrary(_ destination: URL) throws {
        let rootResolved = root.resolvingSymlinksInPath().path
        let destResolved = destination.resolvingSymlinksInPath().path
        // A path is "inside" the root if it starts with the root path followed
        // by the path separator (to avoid false positives from a sibling
        // directory whose name starts with the same prefix).
        let rootWithSeparator = rootResolved.hasSuffix("/") ? rootResolved : rootResolved + "/"
        if destResolved.hasPrefix(rootWithSeparator) {
            throw PortfolioLibraryError.exportDestinationInsideLibrary
        }
    }
}
