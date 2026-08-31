//
//  KeyCacheEvictionTests.swift
//  LDACoreTests
//
//  The container key cache is bounded. It exists so user-presence protection
//  costs about one Touch ID per key rather than one per operation, but it must
//  not accumulate live key material for the whole life of a long GUI session,
//  and keys obtained under one Keychain policy must not satisfy reads under
//  another.
//
//  These tests drive the cache through real container saves, so what is
//  asserted is the observable behavior of the store, not a private field.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class KeyCacheEvictionTests: XCTestCase {

    private var workDir: URL!
    private let service = "ai.openclaw.lda.cacheevictiontest"
    private var container: EncryptedContainer!
    private var createdAccounts: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = EncryptedContainer(
            magic: Array("LDACACHE".utf8),
            keychainService: service,
            containerDescription: "Cache test store"
        )
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyCacheEvictionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        EncryptedContainer.purgeKeyCache()
        createdAccounts = []
    }

    override func tearDownWithError() throws {
        EncryptedContainer.clockSeam.clear()
        for account in createdAccounts {
            try? container.deleteKeychainKey(account: account)
        }
        EncryptedContainer.purgeKeyCache()
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    /// Save one container under its own Keychain account, which is what puts a
    /// key in the cache. Returns false when the Keychain is unavailable in this
    /// environment, so the caller can skip instead of reporting a false failure.
    private func saveUnderNewAccount(_ index: Int) throws -> Bool {
        let account = TestNamespace.keychainAccount("cache-test-\(index)")
        do {
            try container.save(
                Data("payload \(index)".utf8),
                to: workDir.appendingPathComponent("c\(index).bin"),
                protection: .keychain(account: account)
            )
        } catch DocumentIOError.keychainError {
            return false
        }
        createdAccounts.append(account)
        return true
    }

    func testCacheStartsEmptyAfterAPurge() {
        EncryptedContainer.purgeKeyCache()
        XCTAssertEqual(EncryptedContainer.cachedKeyCount, 0)
    }

    func testCacheNeverExceedsItsCapacity() throws {
        // Arrange + Act: create more distinct keys than the cache can hold.
        // Per-document keys mean a real session does exactly this.
        let overshoot = EncryptedContainer.keyCacheCapacity + 6
        for index in 0 ..< overshoot {
            guard try saveUnderNewAccount(index) else {
                throw XCTSkip("Keychain unavailable in this environment")
            }
        }

        // Assert
        XCTAssertLessThanOrEqual(
            EncryptedContainer.cachedKeyCount,
            EncryptedContainer.keyCacheCapacity,
            "the cache must evict rather than grow with every document touched"
        )
    }

    func testEvictedKeysStillLoadFromTheKeychain() throws {
        // Eviction must be a cache miss, never data loss: the first container
        // has to keep opening after its key has been pushed out.
        let firstAccount = TestNamespace.keychainAccount("cache-test-first")
        let firstURL = workDir.appendingPathComponent("first.bin")
        let payload = Data("the first payload".utf8)
        do {
            try container.save(payload, to: firstURL, protection: .keychain(account: firstAccount))
        } catch DocumentIOError.keychainError {
            throw XCTSkip("Keychain unavailable in this environment")
        }
        createdAccounts.append(firstAccount)

        for index in 0 ..< (EncryptedContainer.keyCacheCapacity + 4) {
            guard try saveUnderNewAccount(index) else {
                throw XCTSkip("Keychain unavailable in this environment")
            }
        }

        let recovered = try container.load(
            from: firstURL,
            protection: .keychain(account: firstAccount)
        )
        XCTAssertEqual(recovered, payload)
    }

    func testPurgeClearsTheCache() throws {
        guard try saveUnderNewAccount(0) else {
            throw XCTSkip("Keychain unavailable in this environment")
        }
        XCTAssertGreaterThan(EncryptedContainer.cachedKeyCount, 0)

        EncryptedContainer.purgeKeyCache()

        XCTAssertEqual(EncryptedContainer.cachedKeyCount, 0)
    }

    func testTogglingTheUserPresencePolicyPurgesTheCache() throws {
        guard try saveUnderNewAccount(0) else {
            throw XCTSkip("Keychain unavailable in this environment")
        }
        XCTAssertGreaterThan(EncryptedContainer.cachedKeyCount, 0)

        // A key fetched under the silent policy must not satisfy a read once
        // user presence is required; otherwise turning Touch ID on would serve
        // pre-policy keys with no prompt.
        KeychainAccessPolicy.requireUserPresence = true
        defer { KeychainAccessPolicy.requireUserPresence = false }

        XCTAssertEqual(
            EncryptedContainer.cachedKeyCount, 0,
            "switching the policy must invalidate keys obtained under the old one"
        )
    }

    func testForgetCachedKeysIsAvailableToHosts() throws {
        guard try saveUnderNewAccount(0) else {
            throw XCTSkip("Keychain unavailable in this environment")
        }
        KeychainAccessPolicy.forgetCachedKeys()
        XCTAssertEqual(EncryptedContainer.cachedKeyCount, 0)
    }

    func testACachedKeyExpiresAfterTheTTL() throws {
        // The TTL exists so an idle session re-establishes the Touch ID prompt
        // instead of trusting one approval forever. The clock is injected here
        // because the production clock is sleep-inclusive monotonic time, which
        // a test cannot fast-forward.
        var fakeNow: UInt64 = 7_000_000_000_000
        EncryptedContainer.clockSeam.value = { fakeNow }

        guard try saveUnderNewAccount(0) else {
            throw XCTSkip("Keychain unavailable in this environment")
        }
        XCTAssertEqual(EncryptedContainer.cachedKeyCount, 1)

        // One nanosecond past the TTL: the key must no longer be served.
        fakeNow += UInt64(EncryptedContainer.keyCacheTTL * 1_000_000_000) + 1

        XCTAssertEqual(
            EncryptedContainer.cachedKeyCount, 0,
            "an idle key must expire; a paused clock would keep it fresh forever"
        )
    }

    func testAKeyReadWithinTheTTLStaysCachedAndRefreshes() throws {
        var fakeNow: UInt64 = 9_000_000_000_000
        EncryptedContainer.clockSeam.value = { fakeNow }

        let account = TestNamespace.keychainAccount("cache-ttl-refresh")
        let url = workDir.appendingPathComponent("ttl.bin")
        do {
            try container.save(Data("x".utf8), to: url, protection: .keychain(account: account))
        } catch DocumentIOError.keychainError {
            throw XCTSkip("Keychain unavailable in this environment")
        }
        createdAccounts.append(account)

        // Advance to just short of expiry, then USE the key: the read must
        // refresh its recency so steady use never re-prompts.
        fakeNow += UInt64((EncryptedContainer.keyCacheTTL - 1) * 1_000_000_000)
        _ = try container.load(from: url, protection: .keychain(account: account))
        fakeNow += UInt64((EncryptedContainer.keyCacheTTL - 1) * 1_000_000_000)

        XCTAssertEqual(
            EncryptedContainer.cachedKeyCount, 1,
            "a key in steady use must not expire between reads"
        )
    }

    func testTheCacheHasABoundedLifetime() {
        XCTAssertLessThanOrEqual(
            EncryptedContainer.keyCacheTTL, 3600,
            "a cached key should not outlive an idle hour of a GUI session"
        )
        XCTAssertGreaterThan(
            EncryptedContainer.keyCacheTTL, 60,
            "too short a TTL would re-prompt for Touch ID mid-task"
        )
    }
}
