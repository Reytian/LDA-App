//
//  MappingStore.swift
//  LDACore
//
//  Phase 4: encrypted persistence for the re-identification key (the Mapping).
//
//  The Mapping is the sensitive sidecar that maps opaque tokens back to the
//  original surface values. It must never be written to disk in plaintext.
//  MappingStore JSON-encodes the Mapping and delegates all container crypto to
//  EncryptedContainer (magic "LDAMAP", version 1, Keychain service
//  "ai.openclaw.lda.mappingkey").
//
//  The public API, on-disk format, and Keychain service are unchanged.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - Protection mode

/// How a Mapping sidecar is protected at rest.
public enum MappingProtection {
    /// Derive the AES key from a user passphrase using PBKDF2-HMAC-SHA256.
    case passphrase(String)
    /// Use a SymmetricKey held in the macOS Keychain, keyed by this account.
    case keychain(account: String)
}

// MARK: - MappingStore

/// Persists a Mapping to disk as an AES-GCM encrypted, versioned container, and
/// loads it back. The on-disk bytes never contain any plaintext mapping value.
///
/// All container crypto is handled by the shared EncryptedContainer. MappingStore
/// is responsible only for JSON encode/decode of the Mapping payload.
public enum MappingStore {

    /// The sidecar's file extension, as written by every export.
    public static let fileExtension = "ldamap"

    /// The exported uniform type identifier declared in the app's Info.plist.
    /// Declared there as a related item type, so a sandbox grant on the file
    /// a sidecar sits next to extends to the sidecar.
    public static let uniformTypeIdentifier = "com.haotianyi.LDA.mapping"

    // MARK: - Shared container instance

    private static let container = EncryptedContainer(
        magic: Array("LDAMAP".utf8),
        keychainService: "ai.openclaw.lda.mappingkey",
        containerDescription: "Mapping sidecar"
    )

    // MARK: - Public API

    /// Encrypts and writes the Mapping to url under the given protection.
    ///
    /// For .keychain the symmetric key is created if absent and reused otherwise.
    /// Throws DocumentIOError.keychainError on a Keychain failure.
    public static func save(
        _ mapping: Mapping,
        to url: URL,
        protection: MappingProtection
    ) throws {
        let plaintext = try encodeMapping(mapping)
        try container.save(plaintext, to: url, protection: protection)
    }

    /// Reads url, decrypts it, and returns the Mapping.
    ///
    /// A wrong passphrase or any tampering throws DocumentIOError.decryptionFailed.
    /// A Keychain failure throws DocumentIOError.keychainError.
    public static func load(
        from url: URL,
        protection: MappingProtection
    ) throws -> Mapping {
        let plaintext = try container.load(from: url, protection: protection)
        return try decodeMapping(plaintext)
    }

    /// Removes a stored Keychain key for an account. Best-effort cleanup helper
    /// for tests and key rotation; a missing item is treated as success.
    public static func deleteKeychainKey(account: String) throws {
        try container.deleteKeychainKey(account: account)
    }

    // MARK: - Encoding

    private static func encodeMapping(_ mapping: Mapping) throws -> Data {
        let encoder = JSONEncoder()
        // Sorted keys keep the output deterministic; it does not affect security.
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(mapping)
        } catch {
            throw DocumentIOError.corrupt("Failed to encode mapping: \(error)")
        }
    }

    private static func decodeMapping(_ data: Data) throws -> Mapping {
        do {
            return try JSONDecoder().decode(Mapping.self, from: data)
        } catch {
            // Decryption succeeded but the payload is not a valid Mapping; treat
            // as a corrupt container rather than a decryption failure.
            throw DocumentIOError.corrupt("Decrypted payload is not a valid Mapping: \(error)")
        }
    }
}
