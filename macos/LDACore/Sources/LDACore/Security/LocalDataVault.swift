//
//  LocalDataVault.swift
//  LDACore
//
//  Small-data encryption at rest for app-local stores (learned vocabulary,
//  custom patterns). Those stores accumulate client and party names, which is
//  a de facto client list; persisting them as plaintext JSON in UserDefaults
//  leaves them readable with `defaults read` and swept into Time Machine.
//
//  Sealing uses AES-256-GCM with a per-account symmetric key held in the
//  Keychain under kSecAttrAccessibleWhenUnlockedThisDeviceOnly, the same
//  posture MappingStore uses for sidecar keys (never synced, unavailable
//  while locked).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import CryptoKit
import Security

/// AES-GCM seal/open for app-local data, keyed per account in the Keychain.
public enum LocalDataVault {

    /// Service name under which vault keys live in the Keychain. Distinct from
    /// the mapping-key service so rotating one class of keys never touches the
    /// other.
    private static let keychainService = "ai.openclaw.lda.localvault"

    /// AES-256 key length in bytes.
    private static let keyLength = 32

    /// Encrypt data under the account's key (created on first use). The result
    /// is the AES-GCM combined box (nonce + ciphertext + tag).
    public static func seal(_ data: Data, account: String) throws -> Data {
        let key = try fetchOrCreateKey(account: account)
        let box = try AES.GCM.seal(data, using: key)
        guard let combined = box.combined else {
            throw DocumentIOError.keychainError(errSecParam)
        }
        return combined
    }

    /// Decrypt a sealed blob under the account's key. Throws when the key is
    /// missing or the blob fails authentication.
    public static func open(_ sealed: Data, account: String) throws -> Data {
        guard let key = try lookupKey(account: account) else {
            throw DocumentIOError.keychainError(errSecItemNotFound)
        }
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw DocumentIOError.decryptionFailed
        }
    }

    /// Remove the account's key. Best-effort cleanup for tests and rotation; a
    /// missing item is treated as success.
    public static func deleteKey(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Keychain key management

    private static func fetchOrCreateKey(account: String) throws -> SymmetricKey {
        if let existing = try lookupKey(account: account) {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: keyLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, keyLength, &bytes)
        guard status == errSecSuccess else {
            throw DocumentIOError.keychainError(status)
        }
        defer { bytes = [UInt8](repeating: 0, count: keyLength) }
        try addKey(account: account, keyData: Data(bytes))
        return SymmetricKey(data: Data(bytes))
    }

    private static func lookupKey(account: String) throws -> SymmetricKey? {
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

    private static func addKey(account: String, keyData: Data) throws {
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
}
