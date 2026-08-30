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

    /// Remove scratch plaintext whose owning process is gone (security audit
    /// F-001). Scratch names are pt_<pid>_<hex>.<format>; a file whose PID
    /// segment is missing, unparseable, or names a dead process is a crash
    /// leftover and is removed. A live PID's files are in use by that process
    /// (the CLI and the MCP server can share one vault) and are left alone.
    /// Best effort by design: a failed removal must not fail the operation
    /// that triggered the sweep.
    func sweepDeadScratchFiles() {
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: scratchDirectory.path
        ) else {
            return
        }
        for name in names {
            guard name.hasPrefix("pt_") else { continue }
            if let owner = Self.scratchOwnerPID(fromName: name), Self.isProcessAlive(owner) {
                continue
            }
            try? FileManager.default.removeItem(
                at: scratchDirectory.appendingPathComponent(name)
            )
        }
    }

    /// Parse the owner PID out of a pt_<pid>_<hex> scratch name. Returns nil
    /// for the pre-PID naming or anything else unparseable.
    static func scratchOwnerPID(fromName name: String) -> pid_t? {
        let segments = name.split(separator: "_")
        guard segments.count >= 3, segments[0] == "pt", let pid = pid_t(segments[1]) else {
            return nil
        }
        return pid
    }

    /// Whether a process with this PID exists. kill(pid, 0) delivers no
    /// signal: 0 means it exists, EPERM means it exists but is not ours (not
    /// expected inside a per-user vault, still treated as alive), ESRCH means
    /// it is gone.
    static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Decrypt each entry to a private scratch file, run body over the URLs,
    /// and remove the scratch files afterwards, throw or return. The scratch
    /// name embeds the creator's PID (so crash leftovers are attributable)
    /// plus random hex, with the entry's logical format as its extension so
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
        // The defer below removes these files on every ORDERLY exit, but a
        // SIGKILL or power loss mid-body leaves decrypted plaintext behind,
        // silently defeating "encrypted at rest" for the in-flight document.
        // Sweeping dead owners' files here means the next vault use by any
        // process cleans up after a crashed one.
        sweepDeadScratchFiles()
        var scratchURLs: [URL] = []
        defer {
            for url in scratchURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        for entry in entries {
            let plaintext = try openObjectData(for: entry)
            let name = try DocumentVault.randomHandle(prefix: "pt_\(pid)_")
                + "." + entry.format
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
