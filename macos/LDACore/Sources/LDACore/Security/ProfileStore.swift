//
//  ProfileStore.swift
//  LDACore
//
//  Encrypted persistence for CompanyProfile (.ldaprofile). The profile holds
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

/// Persists a CompanyProfile to disk as an AES-GCM encrypted, versioned
/// container, and loads it back. The on-disk bytes never contain any plaintext
/// profile value.
///
/// All container crypto is handled by the shared EncryptedContainer.
/// ProfileStore is responsible only for JSON encode/decode of the
/// CompanyProfile payload.
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

    /// Encrypts and writes the CompanyProfile to url under the given protection.
    ///
    /// For .keychain the symmetric key is created if absent and reused
    /// otherwise. Throws DocumentIOError.keychainError on a Keychain failure.
    public static func save(
        _ profile: CompanyProfile,
        to url: URL,
        protection: MappingProtection
    ) throws {
        let plaintext = try encodeProfile(profile)
        try container.save(plaintext, to: url, protection: protection)
    }

    /// Reads url, decrypts it, and returns the CompanyProfile.
    ///
    /// A wrong passphrase or any tampering throws DocumentIOError.decryptionFailed.
    /// A Keychain failure throws DocumentIOError.keychainError.
    /// A container written by MappingStore (different magic) throws
    /// DocumentIOError.corrupt before any key material is used.
    public static func load(
        from url: URL,
        protection: MappingProtection
    ) throws -> CompanyProfile {
        let plaintext = try container.load(from: url, protection: protection)
        return try decodeProfile(plaintext)
    }

    /// Removes the stored Keychain key for an account. Best-effort cleanup
    /// helper for tests and key rotation; a missing item is treated as success.
    public static func deleteKeychainKey(account: String) throws {
        try container.deleteKeychainKey(account: account)
    }

    // MARK: - Encoding

    private static func encodeProfile(_ profile: CompanyProfile) throws -> Data {
        let encoder = JSONEncoder()
        // Sorted keys keep the output deterministic; does not affect security.
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(profile)
        } catch {
            throw DocumentIOError.corrupt("Failed to encode profile: \(error)")
        }
    }

    private static func decodeProfile(_ data: Data) throws -> CompanyProfile {
        do {
            return try JSONDecoder().decode(CompanyProfile.self, from: data)
        } catch {
            // Decryption succeeded but the payload is not a valid CompanyProfile;
            // treat as a corrupt container rather than a decryption failure.
            throw DocumentIOError.corrupt("Decrypted payload is not a valid CompanyProfile: \(error)")
        }
    }
}
