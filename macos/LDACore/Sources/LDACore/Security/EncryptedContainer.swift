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
//   - .passphrase: derive a 256-bit AES key with PBKDF2-HMAC-SHA256 (CommonCrypto)
//     over a random 16-byte salt stored in the container. The iteration count is
//     recorded in the container (version 2 onward) so it can be raised over time
//     without breaking existing files.
//   - .keychain: generate (create-if-absent) or fetch a 256-bit SymmetricKey held
//     in the macOS Keychain (kSecClassGenericPassword), keyed by an account.
//
//  Version 2 additions (both backward compatible; version 1 files still open):
//   - The plaintext header is bound into AES-GCM as additional authenticated
//     data, so the header is no longer malleable.
//   - The PBKDF2 iteration count is stored in the header. New containers use
//     600k per current OWASP guidance; version 1 files are read at their
//     implicit 200k.
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

    /// Whether operations on this container are recorded in SecurityEventLog.
    /// True for every real store. The audit log's OWN container sets it false,
    /// which is what stops recording an event from recursing into recording
    /// another one.
    public let auditing: Bool

    // MARK: Container constants

    /// Container format version written into every NEW container.
    ///
    /// This versions the SHARED container layout (magic, version, tag, salt length, salt,
    /// iteration count, sealed box), not any individual store's payload schema. A payload
    /// schema change (e.g., adding a field to MappingEntry) must NOT bump this constant;
    /// bump the store's own schema version instead.
    ///
    /// Version history:
    ///   1: magic | version | tag | saltLen | salt | sealed. No AAD; PBKDF2 at an
    ///      implicit 200k iterations.
    ///   2: magic | version | tag | saltLen | salt | iterations(UInt32 BE) | sealed.
    ///      The whole header is bound as AES-GCM additional authenticated data and
    ///      the PBKDF2 iteration count is explicit.
    public static let containerVersion: UInt8 = 2

    /// Versions this build can READ. Writing always uses containerVersion, but
    /// files produced by earlier builds must keep opening: a user's existing
    /// sidecars and portfolios are the whole point of the store.
    public static let readableVersions: Set<UInt8> = [1, 2]

    /// Protection tag written into the container so load knows how the key was
    /// derived without trusting the caller blindly.
    private enum ProtectionTag: UInt8 {
        case passphrase = 1
        case keychain = 2
    }

    /// PBKDF2 salt length in bytes.
    private static let saltLength = 16

    /// PBKDF2 iteration count written into every NEW container. 600k is the
    /// current OWASP recommendation for PBKDF2-HMAC-SHA256; the previous 200k
    /// only met the older NIST floor. The count lives in the container header,
    /// so raising it again later needs no format change and does not strand
    /// files written under an older number.
    private static let pbkdf2Iterations: UInt32 = 600_000

    /// The iteration count version 1 containers used without recording it.
    /// Required to open files written before the count became explicit.
    private static let legacyPBKDF2Iterations: UInt32 = 200_000

    /// Largest iteration count accepted when OPENING a container. The header
    /// is authenticated (v2 AAD), but the count must be USED to derive the key
    /// before that authentication can run, so without a cap a hostile sidecar
    /// declaring UInt32.max pins a core for half an hour per open attempt.
    /// 10M leaves generous headroom above the 600k we write.
    static let maxAcceptedPBKDF2Iterations: UInt32 = 10_000_000

    /// Width of the iteration-count field in the version 2 header.
    private static let iterationFieldLength = 4

    /// Derived AES key length in bytes (256-bit).
    private static let keyLength = 32

    // MARK: Initializer

    public init(
        magic: [UInt8],
        keychainService: String,
        containerDescription: String,
        auditing: Bool = true
    ) {
        precondition(!magic.isEmpty, "magic must be non-empty")
        self.magic = magic
        self.keychainService = keychainService
        self.containerDescription = containerDescription
        self.auditing = auditing
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
        // The header is built BEFORE sealing because it doubles as the AAD:
        // the bytes that prefix the file are exactly the bytes bound into
        // AES-GCM authentication, so a header edit invalidates the tag.
        let header: Data
        let key: SymmetricKey
        switch protection {
        case .passphrase(let passphrase):
            let salt = Self.randomBytes(count: Self.saltLength)
            let iterations = Self.pbkdf2Iterations
            header = makeHeader(tag: .passphrase, salt: salt, iterations: iterations)
            key = try deriveKey(
                passphrase: passphrase,
                salt: salt,
                iterations: iterations
            )
        case .keychain(let account):
            // Iterations are meaningless for a Keychain key; the field is
            // written as zero so the layout stays fixed-width.
            header = makeHeader(tag: .keychain, salt: [], iterations: 0)
            key = try fetchOrCreateKeychainKey(account: account)
        }

        let sealed = try Self.seal(plaintext, with: key, authenticating: header)
        var containerData = header
        containerData.append(sealed)

        do {
            try containerData.write(to: url, options: [.atomic])
        } catch {
            audit(.containerSealed, protection: protection, succeeded: false, detail: "writeFailed")
            throw DocumentIOError.unreadable("Failed to write \(containerDescription): \(error)")
        }
        audit(.containerSealed, protection: protection)
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
            key = try deriveKey(
                passphrase: passphrase,
                salt: parsed.salt,
                iterations: parsed.iterations
            )
        case .keychain(let account):
            guard parsed.tag == .keychain else {
                throw DocumentIOError.decryptionFailed
            }
            key = try fetchKeychainKey(account: account)
        }

        do {
            let plaintext = try Self.open(
                parsed.sealed,
                with: key,
                authenticating: parsed.authenticatedHeader
            )
            audit(.containerOpened, protection: protection)
            return plaintext
        } catch {
            audit(
                .containerOpenFailed,
                protection: protection,
                succeeded: false,
                detail: "decryptionFailed"
            )
            throw error
        }
    }

    /// Removes the stored Keychain key for an account under this container's service.
    /// A missing item is treated as success (best-effort cleanup). Both stores
    /// are cleared: the legacy login-keychain item and the data-protection
    /// item (where user-presence keys live), plus the in-process cache.
    public func deleteKeychainKey(account: String) throws {
        Self.forgetKey(forCacheKey: cacheKey(for: account))
        auditKey(.keychainKeyDeleted, account: account)

        // Remove both the legacy silent item and the user-presence-protected
        // copy (kept under the ".userpresence" account).
        for storedAccount in [account, Self.protectedAccount(account)] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: storedAccount
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw DocumentIOError.keychainError(status)
            }
        }
    }

    // MARK: - AES-GCM

    /// Seals plaintext, binding `header` as additional authenticated data when
    /// present. A version 1 container passes nil, which reproduces the original
    /// unbound behavior byte for byte.
    private static func seal(
        _ plaintext: Data,
        with key: SymmetricKey,
        authenticating header: Data?
    ) throws -> Data {
        do {
            let box = try header.map {
                try AES.GCM.seal(plaintext, using: key, authenticating: $0)
            } ?? AES.GCM.seal(plaintext, using: key)
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

    /// Opens a sealed box, requiring `header` to authenticate when present.
    /// A tampered header therefore fails here rather than merely failing a
    /// downstream sanity check.
    private static func open(
        _ sealedCombined: Data,
        with key: SymmetricKey,
        authenticating header: Data?
    ) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: sealedCombined)
            if let header {
                return try AES.GCM.open(box, using: key, authenticating: header)
            }
            return try AES.GCM.open(box, using: key)
        } catch {
            // Authentication failure (wrong key or tampered bytes) or a malformed
            // sealed box both mean the document cannot be decrypted.
            throw DocumentIOError.decryptionFailed
        }
    }

    // MARK: - PBKDF2 key derivation

    /// Derives a 256-bit key from a passphrase and salt using PBKDF2-HMAC-SHA256
    /// at the given iteration count. The count comes from the container being
    /// opened (or from pbkdf2Iterations when writing a new one), so raising the
    /// default never strands an older file.
    private func deriveKey(
        passphrase: String,
        salt: [UInt8],
        iterations: UInt32
    ) throws -> SymmetricKey {
        guard iterations > 0 else {
            throw DocumentIOError.corrupt(
                "\(containerDescription) declares a zero PBKDF2 iteration count"
            )
        }
        guard iterations <= Self.maxAcceptedPBKDF2Iterations else {
            throw DocumentIOError.corrupt(
                "\(containerDescription) declares an implausible PBKDF2 iteration "
                    + "count (\(iterations)); refusing to derive"
            )
        }
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
                        iterations,
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

    // MARK: Key cache
    //
    // Why a cache at all: user-presence protection would otherwise cost one
    // Touch ID prompt per keychain read, and a single user action can trigger
    // several (mapping key, session record key, client key).
    //
    // Why it is BOUNDED: keys are per document and per client, so an unbounded
    // process-lifetime cache grows with every document a long-running GUI
    // session touches, and every entry is live key material sitting in memory
    // for hours. Two bounds apply: entries expire after keyCacheTTL, and the
    // cache holds at most keyCacheCapacity keys, evicting least-recently-used
    // first. Expiry also re-establishes the Touch ID prompt after an idle
    // period rather than trusting one prompt for the whole launch.

    /// Maximum number of keys held at once.
    static let keyCacheCapacity = 16

    /// How long a cached key stays usable after its last use.
    static let keyCacheTTL: TimeInterval = 900

    /// A cached key plus the monotonic timestamp of its last use. The clock is
    /// deliberately monotonic (never the wall clock) so a system clock change
    /// cannot extend a key's lifetime.
    private struct CachedKey {
        let key: SymmetricKey
        var lastUsedUptime: UInt64
    }

    private static let keyCacheLock = NSLock()
    private static var keyCache: [String: CachedKey] = [:]

#if DEBUG
    /// Debug-only clock override so the TTL rule is testable without waiting
    /// out 15 real minutes. Lock guarded and compiled out of release; see
    /// TestSeam.
    static let clockSeam = TestSeam<() -> UInt64>()
#endif

    /// Monotonic nanoseconds, INCLUDING time the machine spends asleep.
    ///
    /// Darwin's CLOCK_MONOTONIC keeps advancing through sleep, unlike
    /// DispatchTime/mach_absolute_time, which pause. The distinction is the
    /// point of the TTL: close the lid on Friday with keys cached and a paused
    /// clock would still call them fresh on Monday, keeping the idle-timeout
    /// promise only for a machine that never sleeps.
    private static func uptimeNanos() -> UInt64 {
#if DEBUG
        if let clock = clockSeam.value {
            return clock()
        }
#endif
        return clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    private static func isExpired(_ entry: CachedKey, now: UInt64) -> Bool {
        let elapsedNanos = now >= entry.lastUsedUptime ? now - entry.lastUsedUptime : 0
        return Double(elapsedNanos) / 1_000_000_000 > keyCacheTTL
    }

    /// Read a live cache entry, refreshing its recency. Returns nil when
    /// absent or expired; an expired entry is dropped on the way out so the
    /// next access re-fetches (and, under the policy, re-prompts).
    private static func cachedKey(forCacheKey cacheKey: String) -> SymmetricKey? {
        keyCacheLock.lock()
        defer { keyCacheLock.unlock() }
        guard let entry = keyCache[cacheKey] else { return nil }
        let now = uptimeNanos()
        if isExpired(entry, now: now) {
            keyCache[cacheKey] = nil
            return nil
        }
        keyCache[cacheKey] = CachedKey(key: entry.key, lastUsedUptime: now)
        return entry.key
    }

    /// Insert a key, first dropping expired entries and then the
    /// least-recently-used one if the cache is still at capacity.
    private static func storeKey(_ key: SymmetricKey, forCacheKey cacheKey: String) {
        keyCacheLock.lock()
        defer { keyCacheLock.unlock() }
        let now = uptimeNanos()
        keyCache = keyCache.filter { !isExpired($0.value, now: now) }
        if keyCache[cacheKey] == nil, keyCache.count >= keyCacheCapacity {
            if let oldest = keyCache.min(by: { $0.value.lastUsedUptime < $1.value.lastUsedUptime }) {
                keyCache[oldest.key] = nil
            }
        }
        keyCache[cacheKey] = CachedKey(key: key, lastUsedUptime: now)
    }

    private static func forgetKey(forCacheKey cacheKey: String) {
        keyCacheLock.lock()
        keyCache[cacheKey] = nil
        keyCacheLock.unlock()
    }

    /// Drop every cached key. Called when the user-presence policy changes (the
    /// keys in hand were obtained under the old policy) and available to a host
    /// that wants to force a re-prompt, for example on screen lock.
    public static func purgeKeyCache() {
        keyCacheLock.lock()
        let purged = keyCache.count
        keyCache = [:]
        keyCacheLock.unlock()
        if purged > 0 {
            SecurityEventLog.shared.record(
                kind: .keyCachePurged,
                scope: "Key cache",
                detail: "\(purged)"
            )
        }
    }

    /// Number of keys currently cached. Test visibility for the eviction rules.
    static var cachedKeyCount: Int {
        keyCacheLock.lock()
        defer { keyCacheLock.unlock() }
        let now = uptimeNanos()
        return keyCache.filter { !isExpired($0.value, now: now) }.count
    }

    private func cacheKey(for account: String) -> String {
        "\(keychainService)\u{1F}\(account)"
    }

    /// Fetches an existing Keychain key, or creates and stores a fresh one.
    private func fetchOrCreateKeychainKey(account: String) throws -> SymmetricKey {
        if let existing = try lookupKeychainKey(account: account) {
            return existing
        }

        let keyData = Self.randomBytes(count: Self.keyLength)
        do {
            try addKeychainKey(account: account, keyData: Data(keyData))
        } catch {
            auditKey(
                .keychainKeyCreated,
                account: account,
                succeeded: false,
                detail: Self.statusDetail(error)
            )
            throw error
        }
        let key = SymmetricKey(data: Data(keyData))
        Self.storeKey(key, forCacheKey: cacheKey(for: account))
        auditKey(.keychainKeyCreated, account: account)
        return key
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
    ///
    /// Under KeychainAccessPolicy.requireUserPresence the search order is:
    /// in-memory cache, then the data-protection keychain (Touch ID), then the
    /// legacy login-keychain item, which is upgraded in place when found.
    private func lookupKeychainKey(account: String) throws -> SymmetricKey? {
        // A cache hit is not audited: it performs no Keychain access and shows
        // no prompt, so recording it would bury the real accesses in noise.
        if let cached = Self.cachedKey(forCacheKey: cacheKey(for: account)) {
            return cached
        }

        do {
            if KeychainAccessPolicy.requireUserPresence {
                if let protected = try lookupProtectedKey(account: account) {
                    remember(protected, account: account)
                    auditKey(.keychainKeyFetched, account: account)
                    return protected
                }
                if let legacy = try lookupLegacyKey(account: account) {
                    migrateToUserPresence(account: account, key: legacy)
                    remember(legacy, account: account)
                    auditKey(.keychainKeyFetched, account: account)
                    return legacy
                }
                return nil
            }

            guard let legacy = try lookupLegacyKey(account: account) else {
                return nil
            }
            remember(legacy, account: account)
            auditKey(.keychainKeyFetched, account: account)
            return legacy
        } catch {
            auditKey(
                .keychainAccessDenied,
                account: account,
                succeeded: false,
                detail: Self.statusDetail(error)
            )
            throw error
        }
    }

    private func remember(_ key: SymmetricKey, account: String) {
        Self.storeKey(key, forCacheKey: cacheKey(for: account))
    }

    /// A short, PII-free detail for the audit log: the OSStatus when we have
    /// one, otherwise the error's type name.
    private static func statusDetail(_ error: Error) -> String {
        if case DocumentIOError.keychainError(let status) = error {
            return "OSStatus \(status)"
        }
        return String(describing: type(of: error))
    }

    /// The original lookup: a silent generic-password item in the login file
    /// keychain (created by pre-policy versions, headless tools, and tests).
    private func lookupLegacyKey(account: String) throws -> SymmetricKey? {
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

    /// Lookup of the access-control-protected item behind user presence.
    /// Returning from here means the user approved via Touch ID (or the
    /// password fallback) within the shared context's reuse window.
    ///
    /// This uses the traditional macOS file keychain, not the data-protection
    /// keychain: an ACL item (kSecAttrAccessControl with .userPresence) prompts
    /// for Touch ID there too, and it needs no keychain-access-group
    /// entitlement, which a locally signed Developer ID app (no provisioning
    /// profile) cannot reliably obtain. The item is distinguished from the
    /// legacy silent item by a distinct account suffix.
    private func lookupProtectedKey(account: String) throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: Self.protectedAccount(account),
            kSecUseAuthenticationContext as String: KeychainAccessPolicy.sharedAuthenticationContext,
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
        case errSecUserCanceled, errSecAuthFailed:
            // The user dismissed or failed the Touch ID prompt: surface it as
            // a keychain error so the caller reports "could not unlock", and
            // never fall through to the unprotected legacy path.
            throw DocumentIOError.keychainError(status)
        default:
            throw DocumentIOError.keychainError(status)
        }
    }

    /// The account name under which the user-presence-protected copy is stored.
    /// A distinct suffix keeps it separate from the legacy silent item so the
    /// two never collide during migration.
    private static func protectedAccount(_ account: String) -> String {
        "\(account).userpresence"
    }

    /// Adds a fresh key to the Keychain. Under the policy it is stored as a
    /// user-presence-protected item (Touch ID on retrieval) under the
    /// ".userpresence" account; otherwise as the original silent item under the
    /// bare account.
    private func addKeychainKey(account: String, keyData: Data) throws {
        if KeychainAccessPolicy.requireUserPresence {
            try addProtectedKey(account: account, keyData: keyData)
        } else {
            try addSilentKey(account: account, keyData: keyData)
        }
    }

    /// The original silent generic-password item (no access control).
    private func addSilentKey(account: String, keyData: Data) throws {
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

    /// A user-presence-protected item under the ".userpresence" account. A
    /// stale copy is removed first so a re-add after a failed migration
    /// cannot hit errSecDuplicateItem.
    private func addProtectedKey(account: String, keyData: Data) throws {
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.userPresence],
            &accessControlError
        ) else {
            accessControlError?.release()
            throw DocumentIOError.keychainError(errSecParam)
        }

        let protectedAccount = Self.protectedAccount(account)
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: protectedAccount
        ] as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: protectedAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessControl as String: accessControl,
            // Do not prompt while merely writing the item; the prompt belongs
            // on retrieval, driven by the shared LAContext.
            kSecUseAuthenticationContext as String: KeychainAccessPolicy.sharedAuthenticationContext
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DocumentIOError.keychainError(status)
        }
    }

    /// Best-effort upgrade of a legacy silent key to user-presence protection:
    /// write the protected copy, then remove the silent one only after the
    /// protected write succeeds. The key bytes are already safely in hand (and
    /// cached), so a failure mid-way never loses data: if the protected write
    /// fails the silent item is left intact and the next run retries; the
    /// silent item is deleted only once its protected replacement exists.
    private func migrateToUserPresence(account: String, key: SymmetricKey) {
        let keyData = key.withUnsafeBytes { Data($0) }
        do {
            try addProtectedKey(account: account, keyData: keyData)
        } catch {
            // The upgrade failed, so this key stays readable with no Touch ID
            // prompt. Previously this returned silently and the user went on
            // believing Touch ID was guarding the store. Record it so the UI
            // can say otherwise.
            KeychainProtectionAdvisory.noteFallback(scope: containerDescription)
            auditKey(
                .userPresenceUpgradeFailed,
                account: account,
                succeeded: false,
                detail: Self.statusDetail(error)
            )
            return
        }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }

    // MARK: - Container layout
    //
    // Version 2 byte layout (big-endian lengths):
    //   [0 ..< M]      magic bytes (M = magic.count)
    //   [M]            version (UInt8, 2)
    //   [M+1]          protection tag (UInt8: 1 passphrase, 2 keychain)
    //   [M+2]          salt length (UInt8; 16 for passphrase, 0 for keychain)
    //   [M+3 ..< M+3+S] salt bytes (S = salt length)
    //   [next 4]       PBKDF2 iteration count (UInt32 big-endian; 0 for keychain)
    //   [rest]         AES-GCM combined sealed box (nonce + ciphertext + tag)
    //
    // Version 1 is the same without the 4-byte iteration count, and is still
    // read (at an implicit 200k iterations) so files from earlier builds open.
    //
    // The salt and the sealed box carry no plaintext payload value. The combined
    // sealed box prefixes the 12-byte nonce, then ciphertext, then the 16-byte
    // authentication tag.
    //
    // Header authentication: from version 2 the ENTIRE header (magic, version,
    // tag, salt length, salt, iteration count) is passed to AES-GCM as
    // additional authenticated data, so editing any header byte makes the tag
    // fail and the container refuses to open. Version 1 containers were written
    // without AAD; they are still opened without it, which is why the parsed
    // version selects the AAD rather than a try-then-retry. That keeps the
    // legacy path explicit instead of guessing.
    //
    // RULE: each store kind MUST use a distinct magic byte sequence AND a distinct
    // keychainService string. Sharing either across store kinds would allow a container
    // of one kind to be silently opened as another kind, defeating store-level isolation.

    /// Build the plaintext header. The returned bytes are both the file prefix
    /// and, for version 2, the AES-GCM additional authenticated data.
    private func makeHeader(
        tag: ProtectionTag,
        salt: [UInt8],
        iterations: UInt32
    ) -> Data {
        var header = Data()
        header.append(contentsOf: magic)
        header.append(Self.containerVersion)
        header.append(tag.rawValue)
        header.append(UInt8(salt.count))
        header.append(contentsOf: salt)
        header.append(contentsOf: Self.bigEndianBytes(iterations))
        return header
    }

    private struct ParsedContainer {
        let version: UInt8
        let tag: ProtectionTag
        let salt: [UInt8]
        /// PBKDF2 iteration count to use for this container.
        let iterations: UInt32
        /// The header bytes to authenticate against, or nil for version 1,
        /// which was written without AAD.
        let authenticatedHeader: Data?
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
        guard Self.readableVersions.contains(version) else {
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

        let iterations: UInt32
        let authenticatedHeader: Data?
        if version >= 2 {
            guard bytes.count >= cursor + Self.iterationFieldLength else {
                throw DocumentIOError.corrupt(
                    "\(containerDescription) iteration count is truncated"
                )
            }
            iterations = Self.readBigEndianUInt32(
                bytes[cursor ..< cursor + Self.iterationFieldLength]
            )
            cursor += Self.iterationFieldLength
            authenticatedHeader = Data(bytes[0 ..< cursor])
        } else {
            iterations = Self.legacyPBKDF2Iterations
            authenticatedHeader = nil
        }

        let sealed = Data(bytes[cursor ..< bytes.count])
        guard !sealed.isEmpty else {
            throw DocumentIOError.corrupt("\(containerDescription) has no ciphertext")
        }

        return ParsedContainer(
            version: version,
            tag: tag,
            salt: salt,
            iterations: iterations,
            authenticatedHeader: authenticatedHeader,
            sealed: sealed
        )
    }

    // MARK: - Fixed-width integers

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
    }

    private static func readBigEndianUInt32(_ slice: ArraySlice<UInt8>) -> UInt32 {
        slice.reduce(UInt32(0)) { accumulated, byte in
            (accumulated << 8) | UInt32(byte)
        }
    }

    // MARK: - Audit

    /// Record a container-level event, unless this container has auditing off
    /// (the audit log's own container). The Keychain account is never logged
    /// directly: it embeds a client or matter label, so only its digest is.
    private func audit(
        _ kind: SecurityEventKind,
        protection: MappingProtection,
        succeeded: Bool = true,
        detail: String? = nil
    ) {
        // The enabled check runs here, not only inside record(): the digest is
        // keyed by a per-install Keychain key, and a disabled log (every
        // headless tool) must not pay for or create that key per operation.
        guard auditing, SecurityEventLog.shared.isEnabled else { return }
        var digest: String?
        if case .keychain(let account) = protection {
            digest = SecurityEventLog.subjectDigest(
                service: keychainService,
                account: account
            )
        }
        SecurityEventLog.shared.record(
            kind: kind,
            scope: containerDescription,
            subjectDigest: digest,
            succeeded: succeeded,
            detail: detail
        )
    }

    /// Record a Keychain-level event for a specific account.
    private func auditKey(
        _ kind: SecurityEventKind,
        account: String,
        succeeded: Bool = true,
        detail: String? = nil
    ) {
        // Same rule as audit(): never compute a keyed digest for a log that
        // will drop the event anyway.
        guard auditing, SecurityEventLog.shared.isEnabled else { return }
        SecurityEventLog.shared.record(
            kind: kind,
            scope: containerDescription,
            subjectDigest: SecurityEventLog.subjectDigest(
                service: keychainService,
                account: account
            ),
            succeeded: succeeded,
            detail: detail
        )
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
