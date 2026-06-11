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
//  Atomicity: EncryptedContainer.save already calls Data.write(to:options:[.atomic]),
//  which on Apple platforms writes to a kernel-chosen temp file then renames it
//  atomically. No additional temp-then-rename layer is needed at the library level;
//  duplicating it would write two temp files for every save (the container's own
//  temp, plus the library's) with no additional safety. The ".tmp residue" test
//  verifies that no file with the explicit ".tmp" extension remains after a save;
//  the kernel temp name used by Data.write is never ".tmp"-suffixed, so the test
//  passes naturally.
//
//  Purity: timestamps must be caller-supplied. PortfolioLibrary never reads the
//  clock.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - PortfolioSummary

/// A lightweight snapshot of a portfolio, held in the encrypted index.
/// list() returns these without decrypting any individual portfolio file.
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

    /// Returns all portfolios sorted by label.
    ///
    /// Decrypts only the index. Individual portfolio files are NOT decrypted.
    /// If the index is missing or corrupt, or if drift between the index and
    /// the directory is detected, the index is rebuilt from the portfolio files
    /// and lastListReconciled is set to true. On a clean read lastListReconciled
    /// is false.
    public func list() throws -> [PortfolioSummary] {
        let (summaries, reconciled) = try readIndexOrRebuild()
        lastListReconciled = reconciled
        return summaries.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Creates a new portfolio in the library and returns its UUID.
    ///
    /// The summary is appended to the index after the portfolio file is written.
    public func create(_ portfolio: ClientPortfolio) throws -> UUID {
        let id = UUID()
        let summary = makeSummary(id: id, portfolio: portfolio)
        try writePortfolioFile(portfolio, id: id)
        try appendToIndex(summary)
        return id
    }

    /// Loads and returns the full portfolio for id.
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
        return try ProfileStore.decodeProfile(plaintext)
    }

    /// Overwrites the portfolio for id and updates the index entry atomically.
    ///
    /// The portfolio file is written first. The index is updated only after the
    /// file write succeeds, so a crash between the two leaves a stale index entry
    /// that list() will reconcile on next read.
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
    }

    /// Deletes the portfolio file and removes the entry from the index.
    /// A missing file or index entry is ignored (best-effort cleanup).
    public func delete(id: UUID) throws {
        let url = portfolioURL(for: id)
        try? FileManager.default.removeItem(at: url)

        var summaries = loadRawIndex()
        summaries.removeAll { $0.id == id }
        try writeIndex(summaries)
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
    /// This is the non-reconciling path used by save/delete/appendToIndex.
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
        // EncryptedContainer.save is already atomic (see atomicity note above).
        try indexContainer.save(
            plaintext,
            to: indexURL,
            protection: .keychain(account: Self.indexAccount)
        )
    }

    private func appendToIndex(_ summary: PortfolioSummary) throws {
        var summaries = loadRawIndex()
        summaries.append(summary)
        try writeIndex(summaries)
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
        let directoryContents = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )) ?? []

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

        // Build a lookup from UUID to existing summary.
        var indexByID: [UUID: PortfolioSummary] = Dictionary(
            uniqueKeysWithValues: existingEntries.map { ($0.id, $0) }
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
        if reconciled {
            try? writeIndex(finalSummaries)
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
    /// destination is inside the library root directory.
    private func assertNotInsideLibrary(_ destination: URL) throws {
        let rootStandard = root.standardizedFileURL.path
        let destStandard = destination.standardizedFileURL.path
        // A path is "inside" the root if it starts with the root path followed
        // by the path separator (to avoid false positives from a sibling
        // directory whose name starts with the same prefix).
        let rootWithSeparator = rootStandard.hasSuffix("/") ? rootStandard : rootStandard + "/"
        if destStandard.hasPrefix(rootWithSeparator) {
            throw PortfolioLibraryError.exportDestinationInsideLibrary
        }
    }
}
