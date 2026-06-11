//
//  ProfileStore.swift
//  LDACore
//
//  Encrypted persistence for ClientPortfolio (.ldaprofile). The profile holds
//  real client PII and must never touch disk in plaintext. Same container
//  format and protection modes as MappingStore, with its own distinct magic
//  bytes and distinct Keychain service string (per the EncryptedContainer rule:
//  each store kind must use a distinct magic AND a distinct keychainService).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - ProfileStore

/// Persists a ClientPortfolio to disk as an AES-GCM encrypted, versioned
/// container, and loads it back. The on-disk bytes never contain any plaintext
/// profile value.
///
/// All container crypto is handled by the shared EncryptedContainer.
/// ProfileStore is responsible only for JSON encode/decode of the
/// ClientPortfolio payload.
public enum ProfileStore {

    // MARK: - Public constants

    /// The default file extension for saved profiles.
    public static let fileExtension = "ldaprofile"

    // MARK: - Shared container instance

    private static let container = EncryptedContainer(
        magic: Array("LDAPROF".utf8),
        keychainService: "ai.openclaw.lda.profilekey",
        containerDescription: "Profile file"
    )

    // MARK: - Public API

    /// Encrypts and writes the ClientPortfolio to url under the given protection.
    ///
    /// For .keychain the symmetric key is created if absent and reused
    /// otherwise. Throws DocumentIOError.keychainError on a Keychain failure.
    public static func save(
        _ profile: ClientPortfolio,
        to url: URL,
        protection: MappingProtection
    ) throws {
        let plaintext = try encodeProfile(profile)
        try container.save(plaintext, to: url, protection: protection)
    }

    /// Reads url, decrypts it, and returns the ClientPortfolio.
    ///
    /// A wrong passphrase or any tampering throws DocumentIOError.decryptionFailed.
    /// A Keychain failure throws DocumentIOError.keychainError.
    /// A container written by MappingStore (different magic) throws
    /// DocumentIOError.corrupt before any key material is used.
    public static func load(
        from url: URL,
        protection: MappingProtection
    ) throws -> ClientPortfolio {
        let plaintext = try container.load(from: url, protection: protection)
        return try decodeProfile(plaintext)
    }

    /// Removes the stored Keychain key for an account. Best-effort cleanup
    /// helper for tests and key rotation; a missing item is treated as success.
    public static func deleteKeychainKey(account: String) throws {
        try container.deleteKeychainKey(account: account)
    }

    // MARK: - Keychain account derivation

    /// Standard per-file Keychain account: the file name without extension.
    /// This is the canonical form used for all new saves.
    /// Example: "Acme Matter.ldaprofile" -> "Acme Matter"
    public static func standardAccount(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Legacy account written by the pre-portal UI: the file name WITH extension.
    /// Used only as a fallback on load so that UI-saved files can still be read.
    /// Example: "Acme Matter.ldaprofile" -> "Acme Matter.ldaprofile"
    public static func legacyAccount(for url: URL) -> String {
        url.lastPathComponent
    }

    /// Keychain-mode load that tries the standard account first, then the legacy
    /// account. Call this for every Keychain load so that files saved by the
    /// pre-portal UI (which used the extension-included account) still open.
    public static func loadWithAccountFallback(from url: URL) throws -> ClientPortfolio {
        do {
            return try load(from: url, protection: .keychain(account: standardAccount(for: url)))
        } catch {
            return try load(from: url, protection: .keychain(account: legacyAccount(for: url)))
        }
    }

    // MARK: - Encoding

    private static func encodeProfile(_ profile: ClientPortfolio) throws -> Data {
        let encoder = JSONEncoder()
        // Sorted keys keep the output deterministic; does not affect security.
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(profile)
        } catch {
            throw DocumentIOError.corrupt("Failed to encode profile: \(error)")
        }
    }

    private static func decodeProfile(_ data: Data) throws -> ClientPortfolio {
        do {
            return try JSONDecoder().decode(ClientPortfolio.self, from: data)
        } catch {
            // Decryption succeeded but the payload is not a valid ClientPortfolio;
            // treat as a corrupt container rather than a decryption failure.
            throw DocumentIOError.corrupt("Decrypted payload is not a valid ClientPortfolio: \(error)")
        }
    }
}
