//
//  ClientMappingStore.swift
//  LDACore
//
//  Client-profile identity persistence (R10): one encrypted Mapping per client
//  label, stored under <ApplicationSupport>/LDA/Clients. A session run under a
//  client seeds its tokenization from the stored mapping and saves the union
//  back, so the same client's entities keep the same placeholders across every
//  session and document.
//
//  Storage format: each client is one MappingStore container file with a
//  random UUID filename (LDAMAP magic, AES-GCM). The exact label exists only
//  inside the encrypted payload. Legacy slug-named files are read and migrated
//  on access.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Exact client labels that could be recovered for the workspace, plus the
/// number of stored mappings that could not be unlocked or validated.
public struct ClientLabelResolution: Equatable, Sendable {
    public let labels: [String]
    public let unreadableCount: Int

    public init(labels: [String], unreadableCount: Int) {
        self.labels = labels
        self.unreadableCount = unreadableCount
    }
}

/// Encrypted per-client mapping directory.
public struct ClientMappingStore {

    /// The directory holding one .ldaclient file per client.
    public let root: URL

    private static let fileExtension = "ldaclient"
    private static let sharedKeychainAccount = "lda-client-mappings"

    /// Creates or opens the store.
    ///
    /// - Parameter rootDirectory: the directory for client mapping files. When
    ///   nil the production default (<ApplicationSupport>/LDA/Clients) is used.
    ///   Created on first use.
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
                .appendingPathComponent("Clients", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Opaque stored mapping identifiers, sorted. Identifiers contain no client
    /// label. Legacy installations may temporarily return a slug until that
    /// mapping is migrated on access.
    public func list() throws -> [String] {
        try mappingURLs()
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Exact client labels resolved from the encrypted mappings. The ordinary
    /// list is intentionally value-free and returns opaque identifiers;
    /// workspace boundaries must use this method so punctuation differences
    /// are never guessed or merged.
    public func listResolvedLabels(
        protectionForIdentifier: (String) -> MappingProtection
    ) throws -> ClientLabelResolution {
        var labels: [String] = []
        var seen = Set<String>()
        var unreadableCount = 0

        for url in try mappingURLs() {
            let identifier = url.deletingPathExtension().lastPathComponent
            do {
                let mapping = try loadStoredMapping(
                    from: url,
                    identifier: identifier,
                    protection: protectionForIdentifier(identifier)
                )
                if UUID(uuidString: identifier) == nil,
                   Self.slug(for: mapping.sourceFile) != identifier {
                    throw DocumentIOError.corrupt(
                        "Client file \(url.lastPathComponent) does not match its encrypted label."
                    )
                }
                guard seen.insert(mapping.sourceFile).inserted else {
                    throw DocumentIOError.corrupt(
                        "More than one client mapping resolves to \"\(mapping.sourceFile)\"."
                    )
                }
                labels.append(mapping.sourceFile)
            } catch {
                unreadableCount += 1
            }
        }
        return ClientLabelResolution(
            labels: labels.sorted(),
            unreadableCount: unreadableCount
        )
    }

    /// Load the client's mapping, or nil when this client has none yet.
    ///
    /// - Parameters:
    ///   - label: the client label.
    ///   - protection: how the file is protected. nil uses the client's
    ///     derived Keychain account.
    /// - Throws: DocumentIOError.corrupt when the stored label does not match
    ///   the requested one (two labels sanitized to the same file name); the
    ///   usual decryption/Keychain errors otherwise.
    public func load(
        label: String,
        protection: MappingProtection? = nil
    ) throws -> Mapping? {
        let label = try validatedLabel(label)
        let resolvedProtection = protection ?? Self.defaultProtection(label: label)
        if let found = try findOpaqueMapping(label: label, protection: resolvedProtection) {
            return found.mapping
        }

        let legacyURL = try legacyFileURL(for: label)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return nil }
        let identifier = legacyURL.deletingPathExtension().lastPathComponent
        let mapping = try loadStoredMapping(
            from: legacyURL,
            identifier: identifier,
            protection: resolvedProtection
        )
        guard mapping.sourceFile == label else {
            throw DocumentIOError.corrupt(
                "Legacy client mapping belongs to a different exact label."
            )
        }
        try migrateLegacyMapping(
            mapping,
            from: legacyURL,
            protection: resolvedProtection
        )
        return mapping
    }

    /// Save (or overwrite) the client's mapping. The mapping's sourceFile is
    /// stamped with the label so load can verify ownership.
    public func save(
        _ mapping: Mapping,
        label: String,
        protection: MappingProtection? = nil
    ) throws {
        let label = try validatedLabel(label)
        let resolvedProtection = protection ?? Self.defaultProtection(label: label)
        var stamped = mapping
        stamped.sourceFile = label
        let existing = try findOpaqueMapping(label: label, protection: resolvedProtection)
        let legacyURL = try legacyFileURL(for: label)
        if existing == nil, FileManager.default.fileExists(atPath: legacyURL.path) {
            _ = try load(label: label, protection: resolvedProtection)
        }
        let url = try findOpaqueMapping(label: label, protection: resolvedProtection)?.url
            ?? randomFileURL()
        try MappingStore.save(
            stamped,
            to: url,
            protection: resolvedProtection
        )
    }

    /// Re-encrypt a client mapping under a new exact label. Returns false when
    /// the old matter has no mapping yet. An occupied destination is rejected
    /// before either file is changed.
    @discardableResult
    public func rename(
        from oldLabel: String,
        to newLabel: String,
        oldProtection: MappingProtection? = nil,
        newProtection: MappingProtection? = nil
    ) throws -> Bool {
        let oldLabel = try validatedLabel(oldLabel)
        let newLabel = try validatedLabel(newLabel)
        guard oldLabel != newLabel else { return true }

        let resolvedOldProtection = oldProtection ?? Self.defaultProtection(label: oldLabel)
        let resolvedNewProtection = newProtection ?? Self.defaultProtection(label: newLabel)
        guard try load(label: oldLabel, protection: resolvedOldProtection) != nil else {
            return false
        }
        guard let source = try findOpaqueMapping(
            label: oldLabel,
            protection: resolvedOldProtection
        ) else {
            throw DocumentIOError.corrupt(
                "The client mapping could not be prepared for rename."
            )
        }
        if try findMapping(label: newLabel, protection: resolvedNewProtection) != nil {
            throw DocumentIOError.unsupportedFormat(
                "A different client mapping already uses \"\(newLabel)\"."
            )
        }

        var renamed = source.mapping
        renamed.sourceFile = newLabel
        try MappingStore.save(renamed, to: source.url, protection: resolvedNewProtection)
        return true
    }

    /// Remove one exact client mapping. A missing client is success. The shared
    /// production key remains because it protects every client mapping.
    public func delete(
        label: String,
        protection: MappingProtection? = nil
    ) throws {
        let label = try validatedLabel(label)
        let resolvedProtection = protection ?? Self.defaultProtection(label: label)
        if let found = try findMapping(label: label, protection: resolvedProtection) {
            try FileManager.default.removeItem(at: found.url)
        }
    }

    // MARK: - Derivations

    /// The default Keychain protection for a client label.
    public static func defaultProtection(label: String) -> MappingProtection {
        .keychain(account: keychainAccount(label: label))
    }

    /// One label-free Keychain account protects all client mappings. The label
    /// parameter remains for source compatibility with existing callers.
    public static func keychainAccount(label: String) -> String {
        sharedKeychainAccount
    }

    // MARK: - File naming

    private struct StoredMapping {
        let url: URL
        let mapping: Mapping
    }

    private func mappingURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == Self.fileExtension }
    }

    private func findMapping(
        label: String,
        protection: MappingProtection
    ) throws -> StoredMapping? {
        if let opaque = try findOpaqueMapping(label: label, protection: protection) {
            return opaque
        }
        let legacyURL = try legacyFileURL(for: label)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return nil }
        let identifier = legacyURL.deletingPathExtension().lastPathComponent
        let mapping = try loadStoredMapping(
            from: legacyURL,
            identifier: identifier,
            protection: protection
        )
        guard mapping.sourceFile == label else { return nil }
        return StoredMapping(url: legacyURL, mapping: mapping)
    }

    private func findOpaqueMapping(
        label: String,
        protection: MappingProtection
    ) throws -> StoredMapping? {
        var match: StoredMapping?
        var firstUnreadableError: Error?
        for url in try mappingURLs() {
            let identifier = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: identifier) != nil else { continue }
            let mapping: Mapping
            do {
                mapping = try loadStoredMapping(
                    from: url,
                    identifier: identifier,
                    protection: protection
                )
            } catch {
                if firstUnreadableError == nil {
                    firstUnreadableError = error
                }
                continue
            }
            guard mapping.sourceFile == label else { continue }
            guard match == nil else {
                throw DocumentIOError.corrupt(
                    "More than one encrypted client mapping uses \"\(label)\"."
                )
            }
            match = StoredMapping(url: url, mapping: mapping)
        }
        if let firstUnreadableError {
            throw firstUnreadableError
        }
        return match
    }

    private func loadStoredMapping(
        from url: URL,
        identifier: String,
        protection: MappingProtection
    ) throws -> Mapping {
        do {
            return try MappingStore.load(from: url, protection: protection)
        } catch {
            guard case .keychain(let account) = protection,
                  account == Self.sharedKeychainAccount else {
                throw error
            }
            return try MappingStore.load(
                from: url,
                protection: .keychain(account: Self.legacyKeychainAccount(identifier: identifier))
            )
        }
    }

    private func migrateLegacyMapping(
        _ mapping: Mapping,
        from legacyURL: URL,
        protection: MappingProtection
    ) throws {
        let newURL = randomFileURL()
        try MappingStore.save(mapping, to: newURL, protection: protection)
        do {
            try FileManager.default.removeItem(at: legacyURL)
        } catch {
            try? FileManager.default.removeItem(at: newURL)
            throw error
        }
        try? MappingStore.deleteKeychainKey(
            account: Self.legacyKeychainAccount(
                identifier: legacyURL.deletingPathExtension().lastPathComponent
            )
        )
    }

    private func randomFileURL() -> URL {
        root.appendingPathComponent("\(UUID().uuidString).\(Self.fileExtension)")
    }

    private func legacyFileURL(for label: String) throws -> URL {
        let slug = Self.slug(for: label)
        guard !slug.isEmpty else {
            throw DocumentIOError.unsupportedFormat("client label must not be empty")
        }
        return root.appendingPathComponent("\(slug).\(Self.fileExtension)")
    }

    private func validatedLabel(_ label: String) throws -> String {
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw DocumentIOError.unsupportedFormat("client label must not be empty")
        }
        return cleaned
    }

    private static func legacyKeychainAccount(identifier: String) -> String {
        "lda-client-\(identifier)"
    }

    /// Sanitize a label into a filesystem-safe slug: keep letters, digits,
    /// spaces, dashes, and underscores; replace everything else with a space;
    /// collapse runs of whitespace; trim. Distinct labels can collide on the
    /// slug; load detects that via the embedded label and fails loudly.
    internal static func slug(for label: String) -> String {
        let kept = label.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == " " ? ch : " "
        }
        let collapsed = String(kept)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }
}
