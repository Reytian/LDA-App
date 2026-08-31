//
//  SecurityEventLog.swift
//  LDACore
//
//  A local, encrypted, append-only audit trail of security-relevant operations:
//  container seals and opens, Keychain key creation and retrieval, Touch ID
//  denials, and failed user-presence upgrades. It closes the Repudiation gap
//  (no audit trail) without weakening the offline, no-plaintext-on-disk posture.
//
//  What is recorded: a timestamp, the operation kind, the store kind (the
//  container's description noun), a truncated digest of the Keychain account,
//  success or failure, and a short PII-free detail. What is NEVER recorded:
//  document text, entity values, file paths, client or matter labels, and the
//  Keychain account itself (account names embed client labels, so only a
//  truncated HMAC-SHA256 of the account, keyed by a per-install random key in
//  the Keychain, is stored; it correlates repeated access to one key without
//  naming it, and without the key it cannot be dictionary-tested against
//  candidate labels).
//
//  Storage: the event array is JSON-encoded and written through
//  EncryptedContainer under its own magic bytes and its own Keychain service,
//  so the audit log is encrypted at rest like every other store and cannot be
//  opened by any other store's loader. The log's own container has auditing
//  turned off, which is what keeps recording an event from recursing.
//
//  Enablement: OFF by default, exactly like KeychainAccessPolicy. The GUI app
//  turns it on at launch. Headless tools (CLI, MCP) and unit tests leave it
//  off, so no process starts writing an audit file merely by linking LDACore.
//
//  Write policy: events accumulate in memory and are flushed to disk when the
//  pending count reaches flushThreshold, when a FAILURE is recorded (a
//  security-relevant failure must not be lost to a crash), or on an explicit
//  flush(). This keeps the per-event cost off the hot path: the whole log is
//  re-encrypted on every flush, so flushing per event would re-encrypt the
//  entire file thousands of times during one document scan. The tradeoff is
//  that an abrupt termination can lose up to flushThreshold - 1 successful
//  operations; failures and the counts around them survive.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import CryptoKit
import Security

// MARK: - Event kinds

/// The security-relevant operations the log records.
public enum SecurityEventKind: String, Codable, Sendable {
    /// A payload was encrypted and written to a container.
    case containerSealed
    /// A container was authenticated and decrypted.
    case containerOpened
    /// A container failed to open (wrong key, tampered bytes, or corrupt).
    case containerOpenFailed
    /// A fresh symmetric key was generated and stored in the Keychain.
    case keychainKeyCreated
    /// An existing Keychain key was retrieved (from the Keychain, not the cache).
    case keychainKeyFetched
    /// A Keychain key was deleted.
    case keychainKeyDeleted
    /// A Keychain read failed, including a cancelled or failed Touch ID prompt.
    case keychainAccessDenied
    /// A legacy unprotected key could not be upgraded to user presence, so it
    /// remains readable without Touch ID. Pairs with
    /// KeychainProtectionAdvisory.
    case userPresenceUpgradeFailed
    /// The in-process key cache was purged (policy change or explicit lock).
    case keyCachePurged
    /// A source document was copied into the staging vault and given a handle.
    case vaultDocumentStaged
    /// A derived artifact (redacted or restored) was registered in the vault.
    case vaultArtifactStored
    /// A vault artifact was copied to the outbox (or an export was refused,
    /// recorded as a failure with a short reason).
    case vaultArtifactExported
    /// A plaintext-form vault (pre phase 5) was migrated to encrypted storage.
    case vaultMigratedToEncryptedForm
}

// MARK: - Event

/// One audit record. Deliberately narrow: no field can carry document text,
/// an entity value, a file path, or a client label.
public struct SecurityEvent: Codable, Sendable, Equatable {
    /// When the event happened, ISO-8601. Supplied by the recorder so tests
    /// stay deterministic.
    public let atISO8601: String
    /// What happened.
    public let kind: SecurityEventKind
    /// Which store kind it happened to, using the container's description noun
    /// (for example "Mapping sidecar"). A fixed vocabulary, never a path.
    public let scope: String
    /// Truncated keyed digest (HMAC-SHA256 under the per-install digest key)
    /// of "service\u{1F}account", or nil when the event is not about a
    /// specific key. Correlates repeated access to one key without recording
    /// the account, which embeds a client or matter label.
    public let subjectDigest: String?
    /// Whether the operation succeeded.
    public let succeeded: Bool
    /// A short PII-free reason on failure (an OSStatus number, an error case
    /// name). nil on success.
    public let detail: String?

    public init(
        atISO8601: String,
        kind: SecurityEventKind,
        scope: String,
        subjectDigest: String?,
        succeeded: Bool,
        detail: String?
    ) {
        self.atISO8601 = atISO8601
        self.kind = kind
        self.scope = scope
        self.subjectDigest = subjectDigest
        self.succeeded = succeeded
        self.detail = detail
    }
}

// MARK: - SecurityEventLog

/// The process-wide encrypted audit log. Disabled until a host explicitly
/// enables it, so linking LDACore never starts writing an audit file.
public final class SecurityEventLog {

    // MARK: Shared instance

    /// The process-wide log. A single instance keeps one in-memory buffer and
    /// one on-disk file, so concurrent stores cannot interleave partial writes.
    public static let shared = SecurityEventLog()

    // MARK: Tuning

    /// Maximum events retained on disk. The oldest are dropped first, which
    /// bounds the file at a few hundred kilobytes.
    public static let maxEvents = 5_000

    /// Pending successful events that trigger a flush. A failure always
    /// flushes immediately regardless of this threshold.
    public static let flushThreshold = 16

    /// File name of the encrypted log inside the log directory.
    public static let fileName = "security-events.ldaaudit"

    /// The Keychain service every audit key lives under: the log's own
    /// encryption key and the subject digest key.
    static let keychainService = "ai.openclaw.lda.audit"

    /// The Keychain account holding the log's own encryption key.
    static let keychainAccount = "security-event-log"

    /// The Keychain account holding the per-install subject digest key.
    static let digestKeyKeychainAccount = "subject-digest-key"

    // MARK: Container

    /// The log's own container: distinct magic and distinct Keychain service
    /// (the documented isolation rule), and auditing OFF so recording an event
    /// cannot recurse into recording another one.
    private static let container = EncryptedContainer(
        magic: Array("LDAAUD".utf8),
        keychainService: SecurityEventLog.keychainService,
        containerDescription: "Security event log",
        auditing: false
    )

    // MARK: State

    private let lock = NSLock()
    private var _isEnabled = false
    private var _directory: URL?
    /// Events already on disk plus the pending tail, oldest first.
    private var events: [SecurityEvent] = []
    /// How many trailing entries of `events` are not yet written.
    private var pendingCount = 0
    private var didLoad = false
    /// The last flush failure, if any. Surfaced instead of swallowed: a log
    /// that cannot write is a fact the host should be able to report.
    private var _lastFailure: String?

    private init() {}

    // MARK: Configuration

    /// Turn recording on or off. Off is the default. Enabling loads any
    /// existing log lazily on the first record, not here, so enabling costs
    /// nothing and never prompts for a key on its own.
    public var isEnabled: Bool {
        get { lock.withLock { _isEnabled } }
        set { lock.withLock { _isEnabled = newValue } }
    }

    /// Where the encrypted log lives. Defaults to Application Support/LDA.
    /// Tests point this at a temporary directory.
    public var directory: URL {
        get {
            lock.withLock { _directory } ?? SecurityEventLog.defaultDirectory()
        }
        set {
            lock.withLock {
                _directory = newValue
                // A new location means the in-memory view no longer describes
                // the file on disk; reload on next use.
                events = []
                pendingCount = 0
                didLoad = false
            }
        }
    }

    /// The last flush failure, or nil when every flush so far succeeded.
    public var lastFailure: String? {
        lock.withLock { _lastFailure }
    }

    /// Application Support/LDA, matching the other stores' default root.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LDA", isDirectory: true)
    }

    // MARK: Recording

    /// Record one event. A no-op when disabled, so call sites need no guard.
    ///
    /// - Parameter atISO8601: the timestamp. Defaults to now; tests pass an
    ///   explicit value to stay deterministic.
    public func record(
        kind: SecurityEventKind,
        scope: String,
        subjectDigest: String? = nil,
        succeeded: Bool = true,
        detail: String? = nil,
        atISO8601: String? = nil
    ) {
        guard isEnabled else { return }
        let stamp = atISO8601 ?? SecurityEventLog.nowISO8601()
        let event = SecurityEvent(
            atISO8601: stamp,
            kind: kind,
            scope: scope,
            subjectDigest: subjectDigest,
            succeeded: succeeded,
            detail: detail
        )

        let shouldFlush: Bool = lock.withLock {
            loadIfNeededLocked()
            events.append(event)
            pendingCount += 1
            if events.count > SecurityEventLog.maxEvents {
                events.removeFirst(events.count - SecurityEventLog.maxEvents)
                pendingCount = min(pendingCount, events.count)
            }
            // A failure is flushed at once: losing the record of a denied
            // Keychain read or a failed decrypt defeats the point of the log.
            return !succeeded || pendingCount >= SecurityEventLog.flushThreshold
        }

        if shouldFlush {
            flush()
        }
    }

    /// Write any pending events to disk. Safe to call when disabled or when
    /// nothing is pending.
    public func flush() {
        guard isEnabled else { return }
        let snapshot: [SecurityEvent]? = lock.withLock {
            guard pendingCount > 0 else { return nil }
            return events
        }
        guard let snapshot else { return }

        do {
            try write(snapshot)
            lock.withLock {
                // Only the entries we just wrote are clean; anything appended
                // while the write was in flight stays pending.
                pendingCount = max(0, events.count - snapshot.count)
                _lastFailure = nil
            }
        } catch {
            lock.withLock {
                _lastFailure = SecurityEventLog.describe(error)
            }
        }
    }

    /// Every recorded event, oldest first, including the not-yet-flushed tail.
    /// Reads through to disk on first use.
    public func readAll() throws -> [SecurityEvent] {
        lock.withLock {
            loadIfNeededLocked()
            return events
        }
    }

    /// Delete the log file and forget the in-memory events. Exposed so a user
    /// can clear their own audit trail deliberately.
    public func clear() throws {
        let url = fileURL()
        lock.withLock {
            events = []
            pendingCount = 0
            didLoad = true
            _lastFailure = nil
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Digest

    #if DEBUG
    /// Test seam: supplies the digest key, so unit tests are deterministic and
    /// never read or create the real per-install key in the Keychain.
    static let digestKeySeam = TestSeam<() -> SymmetricKey>()
    #endif

    private static let digestKeyLock = NSLock()
    private static var cachedDigestKey: SymmetricKey?

    /// A stable, truncated digest of a Keychain identity. It exists only so
    /// two events about the same key can be correlated.
    ///
    /// The digest is an HMAC-SHA256 under a per-install random key, truncated
    /// to 8 bytes. Account names embed client and matter labels, and labels
    /// are guessable, so an unkeyed hash could be reversed by dictionary
    /// testing candidate labels against a decrypted log. Keying closes that:
    /// reading the log is not enough, the digest key would have to come out of
    /// the Keychain too. Within one install the digest is still only a
    /// pseudonym, not encryption of the account name.
    public static func subjectDigest(service: String, account: String) -> String {
        let input = Data("\(service)\u{1F}\(account)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: input, using: digestKey())
        return Data(mac).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The per-install digest key: injected in tests, cached after the first
    /// use, otherwise loaded from or created in the Keychain. When the
    /// Keychain cannot serve or store it, the fallback is an ephemeral process
    /// key, so digests still correlate within the run and are never unkeyed.
    private static func digestKey() -> SymmetricKey {
        #if DEBUG
        if let injected = digestKeySeam.value {
            return injected()
        }
        #endif
        return digestKeyLock.withLock {
            if let cached = cachedDigestKey {
                return cached
            }
            let key = loadOrCreatePersistentDigestKey() ?? SymmetricKey(size: .bits256)
            cachedDigestKey = key
            return key
        }
    }

    /// Load the digest key from the Keychain, creating and storing a fresh
    /// random one on first use. Returns nil when the Keychain cannot serve or
    /// store it; the caller falls back to an ephemeral key.
    ///
    /// Deliberately a silent Keychain item, never user-presence protected:
    /// digests are computed in the middle of ordinary store operations, and
    /// the audit trail must never raise a Touch ID prompt of its own. The key
    /// guards log pseudonymity, not document content.
    ///
    /// - Parameter account: which Keychain account holds the key. Production
    ///   always uses the install-wide default. A test passes a process-unique
    ///   account so that exercising this real Keychain path cannot race with,
    ///   or delete the key of, another process running the same test.
    static func loadOrCreatePersistentDigestKey(
        account: String = digestKeyKeychainAccount
    ) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, !data.isEmpty {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else {
            return nil
        }

        let fresh = SymmetricKey(size: .bits256)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: fresh.withUnsafeBytes { Data($0) },
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return fresh
        }
        if addStatus == errSecDuplicateItem {
            // Another thread or process created it between the read and the
            // add. Use theirs, so the whole install digests under one key.
            var raced: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &raced) == errSecSuccess,
               let data = raced as? Data, !data.isEmpty {
                return SymmetricKey(data: data)
            }
        }
        return nil
    }

    #if DEBUG
    /// Test support: whether a digest key exists under account.
    ///
    /// The account is required rather than defaulted, so a test cannot ask
    /// about the install-wide key by accident.
    static func digestKeyExistsForTesting(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Test support: remove the digest key under account and forget the cache.
    ///
    /// The account is required rather than defaulted, so deleting the
    /// install-wide key has to be spelled out. It should never be: another
    /// process may be digesting under it, and on a machine where the audit key
    /// was upgraded to user presence, deleting the account takes the
    /// ".userpresence" variant with it.
    static func deleteDigestKeyForTesting(account: String) {
        digestKeyLock.withLock { cachedDigestKey = nil }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
    #endif

    // MARK: Private

    private func fileURL() -> URL {
        directory.appendingPathComponent(SecurityEventLog.fileName)
    }

    /// Load the existing log once. Called with the lock held.
    private func loadIfNeededLocked() {
        guard !didLoad else { return }
        didLoad = true
        let url = (_directory ?? SecurityEventLog.defaultDirectory())
            .appendingPathComponent(SecurityEventLog.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let plaintext = try SecurityEventLog.container.load(
                from: url,
                protection: .keychain(account: SecurityEventLog.keychainAccount)
            )
            events = try JSONDecoder().decode([SecurityEvent].self, from: plaintext)
            pendingCount = 0
        } catch {
            // An unreadable log must not break the operation being audited.
            // Start a fresh in-memory list and report the reason; the old file
            // is left in place rather than destroyed.
            _lastFailure = "Could not read the existing log: "
                + SecurityEventLog.describe(error)
        }
    }

    private func write(_ snapshot: [SecurityEvent]) throws {
        let directory = self.directory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(snapshot)
        try SecurityEventLog.container.save(
            payload,
            to: directory.appendingPathComponent(SecurityEventLog.fileName),
            protection: .keychain(account: SecurityEventLog.keychainAccount)
        )
    }

    /// A short, PII-free description of a failure.
    private static func describe(_ error: Error) -> String {
        if let ioError = error as? DocumentIOError {
            switch ioError {
            case .decryptionFailed: return "decryptionFailed"
            case .keychainError(let status): return "keychainError(\(status))"
            case .corrupt: return "corrupt"
            case .unreadable: return "unreadable"
            case .unsupportedFormat: return "unsupportedFormat"
            case .ocrUnavailable: return "ocrUnavailable"
            case .tooLarge: return "tooLarge"
            }
        }
        return String(describing: type(of: error))
    }

    /// The recorder owns its clock. LDAService is clock-free by contract, but
    /// an audit trail whose timestamps came from callers would be trivially
    /// forgeable by the very code it audits.
    private static func nowISO8601() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

// MARK: - KeychainProtectionAdvisory

/// Records whether user-presence (Touch ID) protection actually took effect.
///
/// Why this exists: under KeychainAccessPolicy.requireUserPresence a legacy
/// unprotected key found in the login keychain is upgraded in place. That
/// upgrade is best-effort: on a Developer ID build without a provisioning
/// profile it can fail, leaving the key readable with no Touch ID prompt. The
/// old behavior was to continue silently, so the user believed Touch ID was
/// guarding data that it was not. The advisory makes the degradation visible
/// so the UI can say so plainly.
public enum KeychainProtectionAdvisory {

    /// Posted the first time a user-presence upgrade fails, so a host UI can
    /// show the advisory when it happens instead of polling for it or only
    /// noticing on the next launch. The fallback is discovered lazily, on the
    /// first read of a key that cannot be upgraded, which is well after launch.
    public static let didFallBackNotification = Notification.Name(
        "ai.openclaw.lda.keychainProtectionFallback"
    )

    private static let lock = NSLock()
    private static var _didFallBack = false
    private static var _scopes: Set<String> = []

    /// True once any key has been left unprotected after a failed upgrade.
    public static var didFallBackToUnprotected: Bool {
        lock.withLock { _didFallBack }
    }

    /// The store kinds affected, for a specific message ("Mapping sidecar",
    /// "Client portfolio"). Never a client label or path.
    public static var affectedScopes: [String] {
        lock.withLock { _scopes.sorted() }
    }

    /// A one-line, user-facing advisory, or nil when protection is intact.
    public static var advisory: String? {
        let scopes = affectedScopes
        guard !scopes.isEmpty else { return nil }
        return "Touch ID could not be applied to "
            + scopes.joined(separator: ", ")
            + ". Those keys are still protected by your login keychain, but they "
            + "unlock without a Touch ID prompt."
    }

    /// Called by EncryptedContainer when a user-presence upgrade fails.
    static func noteFallback(scope: String) {
        let isNew: Bool = lock.withLock {
            _didFallBack = true
            return _scopes.insert(scope).inserted
        }
        // Post outside the lock: an observer that reads the advisory back would
        // otherwise deadlock on it.
        if isNew {
            NotificationCenter.default.post(
                name: didFallBackNotification,
                object: nil
            )
        }
    }

    /// Test hook: forget every recorded fallback.
    public static func reset() {
        lock.withLock {
            _didFallBack = false
            _scopes = []
        }
    }
}
