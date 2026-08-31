//
//  StoreScope.swift
//  LDAUI
//
//  Matter-scoped persistence for the user-vocabulary stores. A lawyer working
//  matter A (labor arbitration: suppress a term) and matter B (IPO diligence:
//  keep the same term) needs the learned rules isolated per matter. Each store
//  keeps its existing global blob untouched, byte for byte, and gains optional
//  per-matter blobs whose UserDefaults keys embed only the matter's stable
//  random id, never its label: labels stay inside ciphertext, matching the
//  privacy model of ClientMappingStore's UUID-named files.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

/// Which persisted layer a store instance reads and writes.
public enum StoreScope: Equatable, Hashable, Sendable {

    /// The app-wide layer. Its storage key is the store's existing key,
    /// unchanged, so scoping is invisible to existing installs.
    case global

    /// One matter's layer. The id is the matter's stable random identity
    /// (MatterMetadata.id). Typing it as UUID makes leaking a matter label
    /// into a UserDefaults key structurally impossible.
    case matter(id: UUID)

    /// The UserDefaults storage key for a store blob under this scope.
    public func storageKey(base: String) -> String {
        switch self {
        case .global:
            return base
        case .matter(let id):
            return base + ".matter." + id.uuidString
        }
    }
}

/// The layer a scoped-store write should land in. The review UI's future
/// "apply to this matter only" toggle selects .matter; the default across the
/// scoped facades is .global, which preserves the pre-scoping behavior of
/// every existing call site.
public enum ScopeTarget: String, Equatable, Sendable {
    case global
    case matter
}

/// Shared key derivations for the encrypted store blobs. One place, so the
/// stores and the matter-deletion cleanup can never drift apart.
enum StoreBlobKeys {

    /// UserDefaults key of the encrypted blob for a storage key.
    static func sealed(_ storageKey: String) -> String {
        storageKey + ".sealed"
    }

    /// Keychain account of the vault key for a storage key.
    static func vaultAccount(_ storageKey: String) -> String {
        "store." + storageKey
    }

    /// Remove every persisted trace of one storage key: the encrypted blob,
    /// any legacy plaintext blob, and the vault key in the Keychain.
    static func removeAll(storageKey: String, defaults: UserDefaults) {
        defaults.removeObject(forKey: sealed(storageKey))
        defaults.removeObject(forKey: storageKey)
        LocalDataVault.deleteKey(account: vaultAccount(storageKey))
    }
}
