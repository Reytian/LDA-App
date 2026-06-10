//
//  EncryptedContainer.swift
//  LDACore
//
//  Shared AES-GCM encrypted, versioned binary container used by MappingStore and
//  any future stores that need the same on-disk protection.
//
//  The container format is parameterized by a magic byte sequence, a Keychain
//  service string, and a description noun used in error messages. The crypto
//  bodies were moved verbatim from MappingStore (Phase 4) to keep the on-disk
//  format and the security properties identical.
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

// MARK: - EncryptedContainer

/// A parameterized AES-GCM encrypted, versioned binary container.
///
/// Instantiate once per store kind with its own magic bytes, Keychain service,
/// and error-message description. Use save(_:to:protection:) and
/// load(from:protection:) to persist and recover arbitrary Data payloads.
public struct EncryptedContainer {

    // MARK: Stored properties

    /// Magic header bytes that prefix every container for this store kind.
    public let magic: [UInt8]

    /// The Keychain service string under which keys for this container live.
    public let keychainService: String

    /// Noun used in error messages. Required; no default so a new store can never
    /// silently inherit another store's wording. Example: "Mapping sidecar".
    public let containerDescription: String

    // MARK: Container constants

    /// Container format version. Bump only on an incompatible layout change.
    public static let containerVersion: UInt8 = 1

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

    // MARK: Initializer

    public init(magic: [UInt8], keychainService: String, containerDescription: String) {
        self.magic = magic
        self.keychainService = keychainService
        self.containerDescription = containerDescription
    }

    // MARK: Public API

    /// Encrypts plaintext and writes the versioned container to url.
    ///
    /// For .keychain the symmetric key is created if absent and reused otherwise.
    /// Throws DocumentIOError.keychainError on a Keychain failure.
    public func save(
        _ plaintext: Data,
        to url: URL,
        protection: MappingProtection
    ) throws {
        let containerData: Data
        switch protection {
        case .passphrase(let passphrase):
            let salt = Self.randomBytes(count: Self.saltLength)
            let key = try deriveKey(passphrase: passphrase, salt: salt)
            let sealed = try Self.seal(plaintext, with: key)
            containerData = makeContainer(tag: .passphrase, salt: salt, sealed: sealed)
        case .keychain(let account):
            let key = try fetchOrCreateKeychainKey(account: account)
            let sealed = try Self.seal(plaintext, with: key)
            containerData = makeContainer(tag: .keychain, salt: [], sealed: sealed)
        }

        do {
            try containerData.write(to: url, options: [.atomic])
        } catch {
            throw DocumentIOError.unreadable("Failed to write \(containerDescription): \(error)")
        }
    }

    /// Reads url, authenticates, and decrypts it, returning the plaintext payload.
    ///
    /// A wrong passphrase or any tampering throws DocumentIOError.decryptionFailed.
    /// A Keychain failure throws DocumentIOError.keychainError.
    public func load(
        from url: URL,
        protection: MappingProtection
    ) throws -> Data {
        let containerData: Data
        do {
            containerData = try Data(contentsOf: url)
        } catch {
            throw DocumentIOError.unreadable("Failed to read \(containerDescription): \(error)")
        }

        let parsed = try parseContainer(containerData)

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

        return try Self.open(parsed.sealed, with: key)
    }

    /// Removes the stored Keychain key for an account under this container's service.
    /// A missing item is treated as success (best-effort cleanup).
    public func deleteKeychainKey(account: String) throws {
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
    private func deriveKey(passphrase: String, salt: [UInt8]) throws -> SymmetricKey {
        let passwordData = Data(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: Self.keyLength)

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
                        Self.pbkdf2Iterations,
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

    /// Fetches an existing Keychain key, or creates and stores a fresh one.
    private func fetchOrCreateKeychainKey(account: String) throws -> SymmetricKey {
        if let existing = try lookupKeychainKey(account: account) {
            return existing
        }

        let keyData = Self.randomBytes(count: Self.keyLength)
        try addKeychainKey(account: account, keyData: Data(keyData))
        return SymmetricKey(data: Data(keyData))
    }

    /// Fetches an existing Keychain key, throwing if it is absent.
    private func fetchKeychainKey(account: String) throws -> SymmetricKey {
        guard let key = try lookupKeychainKey(account: account) else {
            throw DocumentIOError.keychainError(errSecItemNotFound)
        }
        return key
    }

    /// Returns the stored key for an account, nil if not found, or throws on a
    /// genuine Keychain error.
    private func lookupKeychainKey(account: String) throws -> SymmetricKey? {
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
            guard let data = item as? Data, data.count == Self.keyLength else {
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
    private func addKeychainKey(account: String, keyData: Data) throws {
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

    // MARK: - Container layout
    //
    // Byte layout (big-endian lengths):
    //   [0 ..< M]    magic bytes (M = magic.count)
    //   [M]          version (UInt8)
    //   [M+1]        protection tag (UInt8: 1 passphrase, 2 keychain)
    //   [M+2]        salt length (UInt8; 16 for passphrase, 0 for keychain)
    //   [M+3..M+3+S] salt bytes (S = salt length)
    //   [rest]       AES-GCM combined sealed box (nonce + ciphertext + tag)
    //
    // The salt and the sealed box carry no plaintext payload value. The combined
    // sealed box prefixes the 12-byte nonce, then ciphertext, then the 16-byte
    // authentication tag.

    private func makeContainer(
        tag: ProtectionTag,
        salt: [UInt8],
        sealed: Data
    ) -> Data {
        var containerData = Data()
        containerData.append(contentsOf: magic)
        containerData.append(Self.containerVersion)
        containerData.append(tag.rawValue)
        containerData.append(UInt8(salt.count))
        containerData.append(contentsOf: salt)
        containerData.append(sealed)
        return containerData
    }

    private struct ParsedContainer {
        let tag: ProtectionTag
        let salt: [UInt8]
        let sealed: Data
    }

    private func parseContainer(_ data: Data) throws -> ParsedContainer {
        // Read against a zero-based copy so subscripts are predictable regardless
        // of the source Data's start index.
        let bytes = [UInt8](data)
        let headerFixed = magic.count + 1 + 1 + 1 // magic + version + tag + saltLen

        guard bytes.count >= headerFixed else {
            throw DocumentIOError.corrupt("\(containerDescription) is too short")
        }

        guard Array(bytes[0 ..< magic.count]) == magic else {
            throw DocumentIOError.corrupt("\(containerDescription) has a bad magic header")
        }

        var cursor = magic.count

        let version = bytes[cursor]
        cursor += 1
        guard version == Self.containerVersion else {
            throw DocumentIOError.corrupt("Unsupported \(containerDescription) version \(version)")
        }

        guard let tag = ProtectionTag(rawValue: bytes[cursor]) else {
            throw DocumentIOError.corrupt("Unknown \(containerDescription) protection tag")
        }
        cursor += 1

        let saltCount = Int(bytes[cursor])
        cursor += 1

        guard bytes.count >= cursor + saltCount else {
            throw DocumentIOError.corrupt("\(containerDescription) salt is truncated")
        }
        let salt = Array(bytes[cursor ..< cursor + saltCount])
        cursor += saltCount

        let sealed = Data(bytes[cursor ..< bytes.count])
        guard !sealed.isEmpty else {
            throw DocumentIOError.corrupt("\(containerDescription) has no ciphertext")
        }

        return ParsedContainer(tag: tag, salt: salt, sealed: sealed)
    }

    // MARK: - Randomness

    /// Returns count cryptographically secure random bytes.
    static func randomBytes(count: Int) -> [UInt8] {
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
