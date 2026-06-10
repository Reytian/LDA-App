//
//  EncryptedStoreTests.swift
//  LDACoreTests
//
//  The learned vocabulary and custom patterns are a de facto client list:
//  names the lawyer repeatedly redacts. They must not sit in UserDefaults as
//  plaintext JSON (readable with `defaults read`, swept into Time Machine).
//  These tests pin the encrypted-at-rest behavior and the one-time migration
//  of legacy plaintext blobs.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

final class EncryptedStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "EncryptedStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        // Drop the stable vault keys these tests mint, so the developer
        // keychain holds nothing from test runs.
        LocalDataVault.deleteKey(account: "store.test.learnedTerms")
        LocalDataVault.deleteKey(account: "store.test.customPatterns")
        try super.tearDownWithError()
    }

    // MARK: - LocalDataVault

    func testVaultSealOpenRoundTripsAndHidesPlaintext() throws {
        let secret = Data("John Smith of Acme Corporation".utf8)
        let account = "test-vault-\(UUID().uuidString)"
        defer { LocalDataVault.deleteKey(account: account) }

        let sealed = try LocalDataVault.seal(secret, account: account)
        XCTAssertNil(
            sealed.range(of: Data("John Smith".utf8)),
            "sealed blob must not contain plaintext"
        )
        let opened = try LocalDataVault.open(sealed, account: account)
        XCTAssertEqual(opened, secret)
    }

    // MARK: - LearningStore at rest

    @MainActor
    func testLearningStoreEncryptsAtRestAndMigratesLegacyPlaintext() throws {
        let storageKey = "test.learnedTerms"
        // Seed a LEGACY plaintext blob the way the old store wrote it.
        let term = LearnedTerm(
            id: "PERSON|john smith", value: "John Smith", type: .person,
            acceptCount: 3, rejectCount: 0
        )
        let legacy = try JSONEncoder().encode(["PERSON|john smith": term])
        defaults.set(legacy, forKey: storageKey)

        // Opening the store migrates: terms load, plaintext disappears.
        let store = LearningStore(defaults: defaults, storageKey: storageKey)
        XCTAssertEqual(store.terms["PERSON|john smith"]?.value, "John Smith")

        let residual = defaults.data(forKey: storageKey)
        XCTAssertTrue(
            residual == nil || residual!.range(of: Data("John Smith".utf8)) == nil,
            "legacy plaintext must be gone after migration"
        )

        // No plaintext anywhere in the persisted domain.
        for (_, anyValue) in defaults.persistentDomain(forName: suiteName) ?? [:] {
            if let data = anyValue as? Data {
                XCTAssertNil(
                    data.range(of: Data("John Smith".utf8)),
                    "a stored blob still contains the client name in plaintext"
                )
            }
        }

        // A fresh instance over the same defaults still sees the terms.
        let reopened = LearningStore(defaults: defaults, storageKey: storageKey)
        XCTAssertEqual(reopened.terms["PERSON|john smith"]?.acceptCount, 3)
    }

    // MARK: - CustomPatternStore at rest

    @MainActor
    func testCustomPatternStoreEncryptsAtRestAndMigratesLegacyPlaintext() throws {
        let storageKey = "test.customPatterns"
        let legacy = try JSONEncoder().encode(
            [CustomPattern(text: "Acme Corporation", type: .company)]
        )
        defaults.set(legacy, forKey: storageKey)

        let store = CustomPatternStore(defaults: defaults, storageKey: storageKey)
        XCTAssertEqual(store.patterns.first?.text, "Acme Corporation")

        for (_, anyValue) in defaults.persistentDomain(forName: suiteName) ?? [:] {
            if let data = anyValue as? Data {
                XCTAssertNil(
                    data.range(of: Data("Acme Corporation".utf8)),
                    "a stored blob still contains the vocabulary term in plaintext"
                )
            }
        }

        let reopened = CustomPatternStore(defaults: defaults, storageKey: storageKey)
        XCTAssertEqual(reopened.patterns.first?.text, "Acme Corporation")
    }
}
