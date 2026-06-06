//
//  MappingStore.swift
//  LDACore
//
//  Phase 4: encrypted persistence for the re-identification key (the Mapping).
//
//  The Mapping is the sensitive sidecar that maps opaque tokens back to the
//  original surface values. It must never be written to disk in plaintext.
//  MappingStore JSON-encodes the Mapping, encrypts it with AES-GCM (CryptoKit),
//  and writes a small versioned binary container.
//
//  Two protection modes:
//   - .passphrase: derive a 256-bit AES key with PBKDF2-HMAC-SHA256 (CommonCrypto,
//     >= 200k iterations) over a random 16-byte salt stored in the container.
//   - .keychain: generate (create-if-absent) or fetch a 256-bit SymmetricKey held
//     in the macOS Keychain (kSecClassGenericPassword), keyed by an account.
//
//  A wrong passphrase or a tampered file surfaces as DocumentIOError.decryptionFailed
//  because AES-GCM authentication fails. Keychain API failures surface as
//  DocumentIOError.keychainError(status).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import CryptoKit
import CommonCrypto
import Security

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
public enum MappingStore {

    // MARK: Container constants

    /// Magic header that prefixes every container so we can reject foreign files
    /// early. ASCII "LDAMAP01" is not stored here as text; see containerMagic.
    private static let containerMagic: [UInt8] = Array("LDAMAP".utf8)

    /// Container format version. Bump only on an incompatible layout change.
    private static let containerVersion: UInt8 = 1

    /// Protection tag written into the container so load knows how the key was
    /// derived without trusting the caller blindly.
    private enum ProtectionTag: UInt8 {
        case passphrase = 1
        case keychain = 2
    }

    /// PBKDF2 salt length in bytes.
    private static let saltLength = 16

    /// PBKDF2 iteration count. Kept well above the 200k floor from the contract.
    private static let pbkdf2Iterations: UInt32 = 200_000

    /// Derived AES key length in bytes (256-bit).
    private static let keyLength = 32

    // MARK: Public API

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

        let container: Data
        switch protection {
        case .passphrase(let passphrase):
            let salt = randomBytes(count: saltLength)
            let key = try deriveKey(passphrase: passphrase, salt: salt)
            let sealed = try seal(plaintext, with: key)
            container = makeContainer(tag: .passphrase, salt: salt, sealed: sealed)
        case .keychain(let account):
            let key = try fetchOrCreateKeychainKey(account: account)
            let sealed = try seal(plaintext, with: key)
            container = makeContainer(tag: .keychain, salt: [], sealed: sealed)
        }

        do {
            try container.write(to: url, options: [.atomic])
        } catch {
            throw DocumentIOError.unreadable("Failed to write mapping sidecar: \(error)")
        }
    }

    /// Reads url, decrypts it, and returns the Mapping.
    ///
    /// A wrong passphrase or any tampering throws DocumentIOError.decryptionFailed.
    /// A Keychain failure throws DocumentIOError.keychainError.
    public static func load(
        from url: URL,
        protection: MappingProtection
    ) throws -> Mapping {
        let container: Data
        do {
            container = try Data(contentsOf: url)
        } catch {
            throw DocumentIOError.unreadable("Failed to read mapping sidecar: \(error)")
        }

        let parsed = try parseContainer(container)

        let key: SymmetricKey
        switch protection {
        case .passphrase(let passphrase):
            guard parsed.tag == .passphrase else {
                throw DocumentIOError.decryptionFailed
            }
            key = try deriveKey(passphrase: passphrase, salt: parsed.salt)
        case .keychain(let account):
            guard parsed.tag == .keychain else {
                throw DocumentIOError.decryptionFailed
            }
            key = try fetchKeychainKey(account: account)
        }

        let plaintext = try open(parsed.sealed, with: key)
        return try decodeMapping(plaintext)
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

    // MARK: - AES-GCM

    private static func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.seal(plaintext, using: key)
            guard let combined = box.combined else {
                // combined is nil only for a non-standard 96-bit nonce; the default
                // seal always uses a 96-bit nonce, so this is defensive.
                throw DocumentIOError.corrupt("AES-GCM produced no combined output")
            }
            return combined
        } catch let error as DocumentIOError {
            throw error
        } catch {
            throw DocumentIOError.corrupt("AES-GCM seal failed: \(error)")
        }
    }

    private static func open(_ sealedCombined: Data, with key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: sealedCombined)
            return try AES.GCM.open(box, using: key)
        } catch {
            // Authentication failure (wrong key or tampered bytes) or a malformed
            // sealed box both mean the document cannot be decrypted.
            throw DocumentIOError.decryptionFailed
        }
    }

    // MARK: - PBKDF2 key derivation

    /// Derives a 256-bit key from a passphrase and salt using PBKDF2-HMAC-SHA256.
    private static func deriveKey(passphrase: String, salt: [UInt8]) throws -> SymmetricKey {
        let passwordData = Data(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: keyLength)

        let status = passwordData.withUnsafeBytes { passwordBytes -> Int32 in
            salt.withUnsafeBufferPointer { saltBuffer in
                derived.withUnsafeMutableBufferPointer { derivedBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                        passwordData.count,
                        saltBuffer.baseAddress,
                        saltBuffer.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        pbkdf2Iterations,
                        derivedBuffer.baseAddress,
                        derivedBuffer.count
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw DocumentIOError.corrupt("PBKDF2 key derivation failed with status \(status)")
        }

        let key = SymmetricKey(data: Data(derived))
        // Wipe the intermediate buffer; SymmetricKey holds its own copy.
        for index in derived.indices {
            derived[index] = 0
        }
        return key
    }

    // MARK: - Keychain

    /// Service name under which all LDA mapping keys live in the Keychain.
    private static let keychainService = "ai.openclaw.lda.mappingkey"

    /// Fetches an existing Keychain key, or creates and stores a fresh one.
    private static func fetchOrCreateKeychainKey(account: String) throws -> SymmetricKey {
        if let existing = try lookupKeychainKey(account: account) {
            return existing
        }

        let keyData = randomBytes(count: keyLength)
        try addKeychainKey(account: account, keyData: Data(keyData))
        return SymmetricKey(data: Data(keyData))
    }

    /// Fetches an existing Keychain key, throwing if it is absent.
    private static func fetchKeychainKey(account: String) throws -> SymmetricKey {
        guard let key = try lookupKeychainKey(account: account) else {
            throw DocumentIOError.keychainError(errSecItemNotFound)
        }
        return key
    }

    /// Returns the stored key for an account, nil if not found, or throws on a
    /// genuine Keychain error.
    private static func lookupKeychainKey(account: String) throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == keyLength else {
                throw DocumentIOError.keychainError(errSecDecode)
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw DocumentIOError.keychainError(status)
        }
    }

    /// Adds a fresh key to the Keychain for an account.
    private static func addKeychainKey(account: String, keyData: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DocumentIOError.keychainError(status)
        }
    }

    /// Removes a stored key for an account. Best-effort cleanup helper for tests
    /// and key rotation; a missing item is treated as success.
    public static func deleteKeychainKey(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DocumentIOError.keychainError(status)
        }
    }

    // MARK: - Container layout
    //
    // Byte layout (big-endian lengths):
    //   [0 ..< 6]    magic "LDAMAP"
    //   [6]          version (UInt8)
    //   [7]          protection tag (UInt8: 1 passphrase, 2 keychain)
    //   [8]          salt length (UInt8; 16 for passphrase, 0 for keychain)
    //   [9 ..< 9+S]  salt bytes (S = salt length)
    //   [rest]       AES-GCM combined sealed box (nonce + ciphertext + tag)
    //
    // The salt and the sealed box carry no plaintext mapping value. The combined
    // sealed box prefixes the 12-byte nonce, then ciphertext, then the 16-byte
    // authentication tag.

    private static func makeContainer(
        tag: ProtectionTag,
        salt: [UInt8],
        sealed: Data
    ) -> Data {
        var container = Data()
        container.append(contentsOf: containerMagic)
        container.append(containerVersion)
        container.append(tag.rawValue)
        container.append(UInt8(salt.count))
        container.append(contentsOf: salt)
        container.append(sealed)
        return container
    }

    private struct ParsedContainer {
        let tag: ProtectionTag
        let salt: [UInt8]
        let sealed: Data
    }

    private static func parseContainer(_ data: Data) throws -> ParsedContainer {
        // Read against a zero-based copy so subscripts are predictable regardless
        // of the source Data's start index.
        let bytes = [UInt8](data)
        let headerFixed = containerMagic.count + 1 + 1 + 1 // magic + version + tag + saltLen

        guard bytes.count >= headerFixed else {
            throw DocumentIOError.corrupt("Mapping sidecar is too short")
        }

        guard Array(bytes[0 ..< containerMagic.count]) == containerMagic else {
            throw DocumentIOError.corrupt("Mapping sidecar has a bad magic header")
        }

        var cursor = containerMagic.count

        let version = bytes[cursor]
        cursor += 1
        guard version == containerVersion else {
            throw DocumentIOError.corrupt("Unsupported mapping sidecar version \(version)")
        }

        guard let tag = ProtectionTag(rawValue: bytes[cursor]) else {
            throw DocumentIOError.corrupt("Unknown mapping sidecar protection tag")
        }
        cursor += 1

        let saltCount = Int(bytes[cursor])
        cursor += 1

        guard bytes.count >= cursor + saltCount else {
            throw DocumentIOError.corrupt("Mapping sidecar salt is truncated")
        }
        let salt = Array(bytes[cursor ..< cursor + saltCount])
        cursor += saltCount

        let sealed = Data(bytes[cursor ..< bytes.count])
        guard !sealed.isEmpty else {
            throw DocumentIOError.corrupt("Mapping sidecar has no ciphertext")
        }

        return ParsedContainer(tag: tag, salt: salt, sealed: sealed)
    }

    // MARK: - Randomness

    /// Returns count cryptographically secure random bytes.
    private static func randomBytes(count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status == errSecSuccess {
            return bytes
        }
        // Fallback to the system RNG; SystemRandomNumberGenerator is CSPRNG-backed
        // on Apple platforms. This path is effectively unreachable.
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min ... UInt8.max, using: &generator)
        }
        return bytes
    }
}
