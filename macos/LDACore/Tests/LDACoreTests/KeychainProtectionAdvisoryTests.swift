//
//  KeychainProtectionAdvisoryTests.swift
//  LDACoreTests
//
//  The app turns on user-presence protection at launch and its Settings copy
//  tells the user their keys are behind Touch ID. When the Keychain refuses the
//  protected item the app keeps working with a silent key, which is the right
//  availability choice and the wrong thing to keep quiet about.
//
//  On the machine this was found on, Touch ID had never engaged once and no
//  warning had ever appeared. Two branches were responsible, and neither had
//  any coverage:
//    - a key CREATED under the policy fell back to a silent item and recorded
//      nothing at all, so a machine whose keys are all new produced no
//      advisory even though every key was unprotected;
//    - a protected LOOKUP that failed for want of an entitlement suppressed
//      the advisory deliberately, to avoid "firing on every launch of a build
//      that can never hold the protected item", which silenced exactly the
//      users for whom the promise is never kept rather than merely delayed.
//
//  These tests pin both, plus the diagnosability the fix adds: the verbatim
//  OSStatus and the system's own message for it have to reach the audit trail
//  AND the user-facing sentence, because a failure nobody can name is a failure
//  nobody can fix.
//
//  A real protected add cannot be driven here: it needs a signed app with a
//  provisioned application identifier. EncryptedContainer.userPresenceStatusSeam
//  injects the refusal instead, so the branch is covered on every machine
//  rather than only on ones that happen to refuse.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import CryptoKit
import Security
@testable import LDACore
@testable import LDAUI

final class KeychainProtectionAdvisoryTests: XCTestCase {

    /// The status the real Keychain returns on this class of machine, observed
    /// rather than assumed: SecItemAdd with a .userPresence access control
    /// answers -34018 in a process without the required entitlement.
    private let observedRefusal = errSecMissingEntitlement

    private let scope = "Advisory test store"

    /// Fail ONE user-presence operation and leave the other on the real
    /// Keychain. Failing both would let each path's test pass on the strength
    /// of the other path's fix, which is precisely the confusion that let one
    /// of these branches ship with no coverage.
    private func failOnly(
        _ target: EncryptedContainer.UserPresenceOperation,
        with status: OSStatus
    ) {
        EncryptedContainer.userPresenceStatusSeam.value = { operation in
            operation == target ? status : nil
        }
    }

    override func setUp() {
        super.setUp()
        assertNoTestSeamsInstalled()
        KeychainProtectionAdvisory.reset()
    }

    override func tearDown() {
        EncryptedContainer.userPresenceStatusSeam.clear()
        KeychainAccessPolicy.requireUserPresence = false
        KeychainProtectionAdvisory.reset()
        super.tearDown()
    }

    // MARK: - Diagnosability

    func testStatusDescriptionCarriesBothTheNumberAndTheSystemMessage() {
        // Arrange / Act
        let described = EncryptedContainer.describeStatus(errSecMissingEntitlement)

        // Assert
        XCTAssertTrue(
            described.contains("-34018"),
            "the numeric OSStatus must survive verbatim, it is what identifies "
                + "the failure: \(described)"
        )
        XCTAssertTrue(
            described.contains("("),
            "the system message must be included, not just the number: \(described)"
        )
        XCTAssertGreaterThan(
            described.count, "OSStatus -34018".count,
            "a bare number sends the reader to a table: \(described)"
        )
    }

    func testStatusDescriptionSurvivesAStatusWithNoSystemMessage() {
        // A status Security has no text for must still describe itself rather
        // than produce an empty detail that reads as "no reason recorded".
        let described = EncryptedContainer.describeStatus(OSStatus(1_234_567))
        XCTAssertTrue(described.contains("1234567"), described)
    }

    // MARK: - The create path

    /// The gap that made the whole thing invisible on a machine with no legacy
    /// keys: only the upgrade path recorded a fallback, and a key created fresh
    /// under the policy never goes through the upgrade path.
    func testCreatePathRecordsTheFallbackNotOnlyTheUpgradePath() throws {
        // Arrange: only the protected ADD is refused. The protected LOOKUP runs
        // for real and answers errSecItemNotFound (there is no such item), so
        // the lookup path's own fallback recording cannot fire and this test
        // can only pass if the CREATE path records one.
        failOnly(.add, with: observedRefusal)
        KeychainAccessPolicy.requireUserPresence = true
        let container = EncryptedContainer(
            magic: Array("LDATEST".utf8),
            keychainService: "ai.openclaw.lda.advisorytest.create",
            containerDescription: scope
        )
        let account = TestNamespace.keychainAccount("advisory-create")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        defer {
            try? container.deleteKeychainKey(account: account)
            try? FileManager.default.removeItem(at: url)
        }

        // Act: a store whose key does not exist yet, so this is the create path.
        let secret = Data("Jordan Lee at Meridian Works".utf8)
        do {
            try container.save(secret, to: url, protection: .keychain(account: account))
        } catch let DocumentIOError.keychainError(status) {
            throw XCTSkip("Keychain unavailable in this process (status \(status))")
        }

        // Assert: the key works, AND the degradation was recorded.
        XCTAssertEqual(
            try container.load(from: url, protection: .keychain(account: account)),
            secret,
            "the fallback must keep the store usable"
        )
        XCTAssertTrue(
            KeychainProtectionAdvisory.didFallBackToUnprotected,
            "a key created unprotected under the policy must record the fallback"
        )
        XCTAssertEqual(KeychainProtectionAdvisory.affectedScopes, [scope])
    }

    // MARK: - The lookup path

    /// The suppression that hid it on a build that can never hold the protected
    /// item. Skipping the doomed re-add is fine; skipping the record is not.
    func testEntitlementBlockedLookupStillRecordsTheFallback() throws {
        // Arrange: a silent key that already exists, written with the policy off.
        let container = EncryptedContainer(
            magic: Array("LDATEST".utf8),
            keychainService: "ai.openclaw.lda.advisorytest.lookup",
            containerDescription: scope
        )
        let account = TestNamespace.keychainAccount("advisory-lookup")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        defer {
            try? container.deleteKeychainKey(account: account)
            try? FileManager.default.removeItem(at: url)
        }

        let secret = Data("Meridian Works".utf8)
        do {
            try container.save(secret, to: url, protection: .keychain(account: account))
        } catch let DocumentIOError.keychainError(status) {
            throw XCTSkip("Keychain unavailable in this process (status \(status))")
        }

        // The key is cached from the write; a fresh launch has an empty cache
        // and that is the state the lookup path runs in.
        EncryptedContainer.purgeKeyCache()
        KeychainProtectionAdvisory.reset()

        // Act: only the protected LOOKUP is refused, so it throws before any
        // legacy key is consulted. The add is left alone: this test is about
        // the branch that decided an unreachable protected item was not worth
        // mentioning, not about a failed write.
        failOnly(.lookup, with: observedRefusal)
        KeychainAccessPolicy.requireUserPresence = true
        let loaded = try container.load(from: url, protection: .keychain(account: account))

        // Assert
        XCTAssertEqual(loaded, secret, "the legacy key must still open the container")
        XCTAssertTrue(
            KeychainProtectionAdvisory.didFallBackToUnprotected,
            "an entitlement-blocked lookup means Touch ID can NEVER apply in this "
                + "build, which is the case the user most needs told, not the one "
                + "to stay quiet about"
        )
    }

    // MARK: - The audit trail

    /// The advisory tells the user; the audit trail tells whoever diagnoses it
    /// later. Both have to carry the status, and the event kind has to say
    /// which path degraded, because "created unprotected" and "could not be
    /// upgraded" call for different answers.
    func testTheAuditTrailRecordsTheVerbatimStatusOnTheCreatePath() throws {
        // Arrange
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdvisoryAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let log = SecurityEventLog.shared
        let previousDirectory = log.directory
        SecurityEventLog.digestKeySeam.value = {
            SymmetricKey(data: Data(repeating: 0xA5, count: 32))
        }
        log.directory = logDir
        log.isEnabled = true
        defer {
            log.isEnabled = false
            log.directory = previousDirectory
            SecurityEventLog.digestKeySeam.clear()
            try? FileManager.default.removeItem(at: logDir)
        }

        failOnly(.add, with: observedRefusal)
        KeychainAccessPolicy.requireUserPresence = true
        let container = EncryptedContainer(
            magic: Array("LDATEST".utf8),
            keychainService: "ai.openclaw.lda.advisorytest.audit",
            containerDescription: scope
        )
        let account = TestNamespace.keychainAccount("advisory-audit")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        defer {
            try? container.deleteKeychainKey(account: account)
            try? FileManager.default.removeItem(at: url)
        }

        // Act
        do {
            try container.save(Data("secret".utf8), to: url,
                               protection: .keychain(account: account))
        } catch let DocumentIOError.keychainError(status) {
            throw XCTSkip("Keychain unavailable in this process (status \(status))")
        }
        log.flush()

        // Assert
        let events = try log.readAll()
        let fallbacks = events.filter { $0.kind == .userPresenceCreateFallback }
        XCTAssertEqual(
            fallbacks.count, 1,
            "the create-path fallback must appear exactly once, named as itself"
        )
        let detail = fallbacks.first?.detail ?? ""
        XCTAssertTrue(
            detail.contains("-34018"),
            "the audit detail must carry the numeric OSStatus: \(detail)"
        )
        XCTAssertFalse(
            detail.contains(account),
            "the account embeds a client or matter label and must never be logged"
        )
        XCTAssertEqual(fallbacks.first?.succeeded, false)
        XCTAssertEqual(fallbacks.first?.scope, scope)
    }

    /// A repeating cause must not spend the log's bounded budget restating
    /// itself, and must still leave the advisory standing. The key cache
    /// expires every 15 minutes, so an unreachable protected item is
    /// re-discovered many times in one session.
    func testARepeatingLookupFailureIsAuditedOnceButStillAdvised() throws {
        // Arrange
        let logDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdvisoryRepeat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let log = SecurityEventLog.shared
        let previousDirectory = log.directory
        SecurityEventLog.digestKeySeam.value = {
            SymmetricKey(data: Data(repeating: 0xA5, count: 32))
        }
        log.directory = logDir
        log.isEnabled = true
        defer {
            log.isEnabled = false
            log.directory = previousDirectory
            SecurityEventLog.digestKeySeam.clear()
            try? FileManager.default.removeItem(at: logDir)
        }

        let container = EncryptedContainer(
            magic: Array("LDATEST".utf8),
            keychainService: "ai.openclaw.lda.advisorytest.repeat",
            containerDescription: scope
        )
        let account = TestNamespace.keychainAccount("advisory-repeat")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        defer {
            try? container.deleteKeychainKey(account: account)
            try? FileManager.default.removeItem(at: url)
        }

        let secret = Data("Meridian Works".utf8)
        do {
            try container.save(secret, to: url, protection: .keychain(account: account))
        } catch let DocumentIOError.keychainError(status) {
            throw XCTSkip("Keychain unavailable in this process (status \(status))")
        }
        KeychainProtectionAdvisory.reset()
        failOnly(.lookup, with: observedRefusal)
        KeychainAccessPolicy.requireUserPresence = true

        // Act: three cache-cold reads, which is what three TTL expiries look
        // like to the lookup path.
        for _ in 0 ..< 3 {
            EncryptedContainer.purgeKeyCache()
            _ = try container.load(from: url, protection: .keychain(account: account))
        }
        log.flush()

        // Assert
        let unavailable = try log.readAll().filter { $0.kind == .userPresenceUnavailable }
        XCTAssertEqual(
            unavailable.count, 1,
            "one unchanging fact must not be restated into a size-bounded log"
        )
        XCTAssertNotNil(
            KeychainProtectionAdvisory.advisory,
            "suppressing the repeat audit must not suppress the user's warning"
        )
    }

    // MARK: - What the user actually sees

    func testFallbackSurfacesANonEmptyUserFacingSentenceCarryingTheStatus() {
        // Arrange / Act
        KeychainProtectionAdvisory.noteFallback(
            scope: scope,
            detail: EncryptedContainer.describeStatus(observedRefusal)
        )

        // Assert
        let advisory = KeychainProtectionAdvisory.advisory
        XCTAssertNotNil(advisory, "a recorded fallback must produce a sentence")
        let sentence = advisory ?? ""
        XCTAssertFalse(sentence.isEmpty)
        XCTAssertTrue(sentence.contains(scope), sentence)
        XCTAssertTrue(
            sentence.contains("-34018"),
            "the sentence is where the user reads the reason and where a bug "
                + "report quotes it from: \(sentence)"
        )
    }

    func testLocalizedAdvisoryIsNonEmptyAndCarriesTheStatus() {
        // The LDAUI wrapper builds the sentence the views render. A localized
        // sentence that dropped the status would leave the product warning
        // without the one detail that makes it actionable.
        KeychainProtectionAdvisory.noteFallback(
            scope: "Mapping sidecar",
            detail: EncryptedContainer.describeStatus(observedRefusal)
        )

        let store = MainActor.assumeIsolated { KeychainAdvisoryStore() }
        let sentence = MainActor.assumeIsolated { store.advisory }

        XCTAssertNotNil(sentence, "the UI store must expose the advisory")
        XCTAssertFalse((sentence ?? "").isEmpty)
        XCTAssertTrue((sentence ?? "").contains("-34018"), sentence ?? "")
    }

    func testNoAdvisoryWhenProtectionIsIntact() {
        XCTAssertNil(
            KeychainProtectionAdvisory.advisory,
            "a clean process must not warn about a fallback that did not happen"
        )
        XCTAssertFalse(KeychainProtectionAdvisory.didFallBackToUnprotected)
        XCTAssertTrue(KeychainProtectionAdvisory.diagnostics.isEmpty)
    }

    func testASecondReasonForAKnownScopeIsAlsoKept() {
        // One store can fail two ways in a session. Keying the record on the
        // scope alone would drop the more informative reason for arriving later.
        KeychainProtectionAdvisory.noteFallback(
            scope: scope,
            detail: EncryptedContainer.describeStatus(errSecMissingEntitlement)
        )
        KeychainProtectionAdvisory.noteFallback(
            scope: scope,
            detail: EncryptedContainer.describeStatus(errSecParam)
        )

        XCTAssertEqual(
            KeychainProtectionAdvisory.diagnostics.count, 2,
            "both reasons must survive: \(KeychainProtectionAdvisory.diagnostics)"
        )
        XCTAssertEqual(
            KeychainProtectionAdvisory.affectedScopes, [scope],
            "the scope is still reported once"
        )
    }

    func testResetClearsTheDiagnosticsToo() {
        KeychainProtectionAdvisory.noteFallback(scope: scope, detail: "OSStatus -1")
        XCTAssertFalse(KeychainProtectionAdvisory.diagnostics.isEmpty)

        KeychainProtectionAdvisory.reset()

        XCTAssertTrue(
            KeychainProtectionAdvisory.diagnostics.isEmpty,
            "a leaked diagnostic would make a later suite warn about a fallback "
                + "that never happened in it"
        )
        XCTAssertNil(KeychainProtectionAdvisory.advisory)
    }
}
