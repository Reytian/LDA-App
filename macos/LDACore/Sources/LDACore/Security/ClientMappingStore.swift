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
//  Storage format: each client is one MappingStore container file
//  (<slug>.ldaclient, LDAMAP magic, AES-GCM), so the crypto and Keychain
//  handling are exactly the same as mapping sidecars. The mapping's sourceFile
//  field records the client label; load verifies it so two labels that
//  sanitize to the same file name fail loudly instead of silently handing one
//  client's identities to another.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Encrypted per-client mapping directory.
public struct ClientMappingStore {

    /// The directory holding one .ldaclient file per client.
    public let root: URL

    private static let fileExtension = "ldaclient"

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

    /// The labels of every stored client, sorted.
    ///
    /// Labels are read from the file names (the slug); the exact label is
    /// verified on load. Listing does not decrypt anything.
    public func list() throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        return contents
            .filter { $0.pathExtension == Self.fileExtension }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
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
        let url = try fileURL(for: label)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let mapping = try MappingStore.load(
            from: url,
            protection: protection ?? Self.defaultProtection(label: label)
        )
        guard mapping.sourceFile == label else {
            throw DocumentIOError.corrupt(
                "Client file \(url.lastPathComponent) belongs to \"\(mapping.sourceFile)\", "
                    + "not \"\(label)\". Rename one of the clients."
            )
        }
        return mapping
    }

    /// Save (or overwrite) the client's mapping. The mapping's sourceFile is
    /// stamped with the label so load can verify ownership.
    public func save(
        _ mapping: Mapping,
        label: String,
        protection: MappingProtection? = nil
    ) throws {
        var stamped = mapping
        stamped.sourceFile = label
        let url = try fileURL(for: label)
        try MappingStore.save(
            stamped,
            to: url,
            protection: protection ?? Self.defaultProtection(label: label)
        )
    }

    /// Remove the client's mapping file and (best effort) its Keychain key.
    /// A missing client is treated as success.
    public func delete(label: String) throws {
        let url = try fileURL(for: label)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try? MappingStore.deleteKeychainKey(account: Self.keychainAccount(label: label))
    }

    // MARK: - Derivations

    /// The default Keychain protection for a client label.
    public static func defaultProtection(label: String) -> MappingProtection {
        .keychain(account: keychainAccount(label: label))
    }

    /// The Keychain account for a client label: "lda-client-" plus the slug.
    public static func keychainAccount(label: String) -> String {
        "lda-client-\(slug(for: label))"
    }

    // MARK: - File naming

    /// The on-disk file for a label.
    private func fileURL(for label: String) throws -> URL {
        let slug = Self.slug(for: label)
        guard !slug.isEmpty else {
            throw DocumentIOError.unsupportedFormat("client label must not be empty")
        }
        return root.appendingPathComponent("\(slug).\(Self.fileExtension)")
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
