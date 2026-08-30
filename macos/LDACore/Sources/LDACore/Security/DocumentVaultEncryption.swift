//
//  DocumentVaultEncryption.swift
//  LDACore
//
//  Phase 5: encryption at rest for the staging vault. Everything key-shaped
//  for the vault lives in this file, and every stored byte the vault owns
//  (objects and the registry) passes through the two container instances
//  declared here. Phase 6 (XPC key holding) swaps the key source in exactly
//  one place: this file.
//
//  Design:
//   - Objects (staged originals plus derived artifacts) are AES-256-GCM
//     EncryptedContainer blobs with their own magic ("LDAVOBJ").
//   - The registry, which holds the ONE PII metadata item in the vault (the
//     original filename kept for export naming), is a container of its own
//     kind ("LDAVREG").
//   - Both facets share ONE vault master key: a single Keychain account under
//     a vault-only service. The magic distinction (bound into AES-GCM as AAD)
//     still prevents a blob of one facet from being opened as the other, so
//     the shared key does not weaken facet isolation. Mapping sidecars are NOT
//     wrapped here: they are already LDAMAP containers with their own keys.
//   - Decryption for use goes to scratch files INSIDE the vault root (so the
//     PreToolUse deny hook guards them and they never land in a world-readable
//     temporary directory), owner-only permissions, removed in a defer.
//
//  Key protection strategy is injectable (initializer parameter) so tests run
//  with passphrase protection and never touch the real Keychain. The launcher
//  may also select passphrase protection through LDA_VAULT_PASSPHRASE, which,
//  like LDA_VAULT_DIR, is read from the launch environment and never from a
//  request.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

extension DocumentVault {

    // MARK: - Constants

    /// Magic bytes prefixing every encrypted vault object (staged originals
    /// and derived artifacts).
    static let objectMagic: [UInt8] = Array("LDAVOBJ".utf8)

    /// Magic bytes prefixing the encrypted registry.
    static let registryMagic: [UInt8] = Array("LDAVREG".utf8)

    /// The Keychain service holding the vault master key. Follows the store
    /// naming convention (mappingkey, recordkey, matterkey, and so on).
    static let keychainService = "ai.openclaw.lda.vaultkey"

    /// The Keychain account of the single vault master key. Follows the store
    /// account convention (workspace-metadata, records, security-event-log).
    public static let masterKeyAccount = "vault-master"

    /// Launch-environment override selecting passphrase protection for the
    /// vault key. Set by whoever launches the process (tests, or a headless
    /// deployment without a usable Keychain), never by a request.
    public static let passphraseEnvironmentKey = "LDA_VAULT_PASSPHRASE"

    // MARK: - Containers

    /// The container for stored objects. Shared with the registry container
    /// below through one master key; see the file header for why that is safe.
    static let objectContainer = EncryptedContainer(
        magic: objectMagic,
        keychainService: keychainService,
        containerDescription: "Vault object"
    )

    /// The container for the registry.
    static let registryContainer = EncryptedContainer(
        magic: registryMagic,
        keychainService: keychainService,
        containerDescription: "Vault registry"
    )

    // MARK: - Protection resolution

    /// The vault key protection an environment selects: passphrase when
    /// LDA_VAULT_PASSPHRASE is set and non-empty, else the master key in the
    /// Keychain. The unsigned headless lda-mcp binary can create and read the
    /// silent file-keychain item (KeychainAccessPolicy.requireUserPresence is
    /// false on that path), so the default works without a prompt.
    public static func defaultProtection(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MappingProtection {
        if let passphrase = environment[passphraseEnvironmentKey], !passphrase.isEmpty {
            return .passphrase(passphrase)
        }
        return .keychain(account: masterKeyAccount)
    }

    // MARK: - Honest state reporting (attest)

    /// True when the on-disk vault holds no plaintext registry. A fresh vault
    /// is encrypted by construction; a vault carrying the pre-encryption
    /// registry.json has NOT migrated yet and must be reported as unprotected.
    /// This is a pure observer: it never triggers the migration itself.
    public func isEncryptionAtRestActive() -> Bool {
        !FileManager.default.fileExists(
            atPath: rootDirectory.appendingPathComponent(DocumentVault.registryFileName).path
        )
    }

    /// A short, honest description of how the vault key is protected, for the
    /// attest tool. Derived from the active protection, never hardcoded. The
    /// XPC phase will introduce a new value here.
    public var keyProtectionDescription: String {
        switch protection {
        case .passphrase:
            return "passphrase"
        case .keychain:
            return KeychainAccessPolicy.requireUserPresence
                ? "keychain-userpresence"
                : "keychain-silent"
        }
    }

    // MARK: - Object sealing

    /// Encrypt plaintext and write it to url. The container writes atomically
    /// (temp file plus rename), so a crash never leaves a torn or half-sealed
    /// object, and sealing over an existing plaintext file replaces it in one
    /// rename.
    func sealObjectData(_ plaintext: Data, to url: URL) throws {
        try DocumentVault.objectContainer.save(plaintext, to: url, protection: protection)
    }

    /// Read and decrypt the stored object of an entry.
    func openObjectData(for entry: VaultEntry) throws -> Data {
        let url = rootDirectory.appendingPathComponent(entry.relativePath)
        return try DocumentVault.objectContainer.load(from: url, protection: protection)
    }

    // MARK: - Scratch plaintext (decryption for use)

    /// Where scratch plaintext lives: inside the vault root, so the vault
    /// guard hook covers it and no other user on the machine can list it the
    /// way a shared temporary directory could be listed.
    var scratchDirectory: URL {
        rootDirectory.appendingPathComponent(
            DocumentVault.scratchDirectoryName,
            isDirectory: true
        )
    }

    /// Decrypt each entry to a private scratch file, run body over the URLs,
    /// and remove the scratch files afterwards, throw or return. The scratch
    /// name is random with the entry's logical format as its extension so
    /// importers dispatch correctly; it derives nothing from the original
    /// filename. Callers must not retain the URLs past body.
    func withScratchPlaintext<T>(
        entries: [VaultEntry],
        _ body: ([URL]) throws -> T
    ) throws -> T {
        try FileManager.default.createDirectory(
            at: scratchDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var scratchURLs: [URL] = []
        defer {
            for url in scratchURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for entry in entries {
            let plaintext = try openObjectData(for: entry)
            let name = try DocumentVault.randomHandle(prefix: "pt_") + "." + entry.format
            let url = scratchDirectory.appendingPathComponent(name)
            // createFile sets the owner-only mode at creation, so there is no
            // window during which the plaintext is readable more widely.
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: plaintext,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw DocumentVaultError.scratchWriteFailed
            }
            scratchURLs.append(url)
        }
        return try body(scratchURLs)
    }
}
