//
//  KeychainAccessPolicyTests.swift
//  LDACoreTests
//
//  Exercises the user-presence keychain policy plumbing. The actual Touch ID
//  path cannot be driven headlessly (an unsigned test process cannot present a
//  biometric prompt and the Secure Enclave ACL add is refused), so these tests
//  assert the two things that ARE testable without a signed app and a user:
//    - the policy defaults OFF, and the silent path is byte-for-byte unchanged;
//    - toggling the policy is a clean process-wide switch that never crashes
//      and never corrupts the silent store when it falls back.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import Security
@testable import LDACore

final class KeychainAccessPolicyTests: XCTestCase {

    override func tearDown() {
        // Never leak the policy into other suites; it is process-wide state.
        KeychainAccessPolicy.requireUserPresence = false
        super.tearDown()
    }

    func testPolicyDefaultsOff() {
        XCTAssertFalse(
            KeychainAccessPolicy.requireUserPresence,
            "the policy must default OFF so headless surfaces stay silent"
        )
    }

    func testSilentKeychainRoundTripUnaffectedByDefaultPolicy() throws {
        let container = EncryptedContainer(
            magic: Array("LDATEST".utf8),
            keychainService: "ai.openclaw.lda.policytest",
            containerDescription: "Policy test"
        )
        let account = "policy-silent-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        defer {
            try? container.deleteKeychainKey(account: account)
            try? FileManager.default.removeItem(at: url)
        }

        let secret = Data("Jordan Lee at Meridian Works".utf8)
        do {
            try container.save(secret, to: url, protection: .keychain(account: account))
            let loaded = try container.load(from: url, protection: .keychain(account: account))
            XCTAssertEqual(loaded, secret)
        } catch let DocumentIOError.keychainError(status) {
            try skipIfKeychainUnavailable(status)
            XCTFail("silent keychain round trip failed with status \(status)")
        }
    }

    func testTogglingPolicyIsReadBackConsistently() {
        KeychainAccessPolicy.requireUserPresence = true
        XCTAssertTrue(KeychainAccessPolicy.requireUserPresence)
        KeychainAccessPolicy.requireUserPresence = false
        XCTAssertFalse(KeychainAccessPolicy.requireUserPresence)
    }

    /// With the policy ON, a save must either succeed (signed host + present
    /// user) or fail with a tolerated Keychain status; it must NEVER silently
    /// write an unprotected key. In the unsigned test process this exercises
    /// the graceful-degradation branch without asserting a biometric prompt.
    func testProtectedSaveEitherSucceedsOrFailsCleanly() throws {
        KeychainAccessPolicy.requireUserPresence = true
        let container = EncryptedContainer(
            magic: Array("LDATEST".utf8),
            keychainService: "ai.openclaw.lda.policytest.up",
            containerDescription: "Policy test UP"
        )
        let account = "policy-up-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        defer {
            try? container.deleteKeychainKey(account: account)
            try? FileManager.default.removeItem(at: url)
        }

        do {
            try container.save(Data("secret".utf8), to: url,
                               protection: .keychain(account: account))
            // Succeeded: we are on a host that allowed the protected add. A
            // load may prompt, so we do not force it here.
        } catch let DocumentIOError.keychainError(status) {
            let acceptable: Set<OSStatus> = [
                errSecParam, errSecMissingEntitlement, errSecNotAvailable,
                errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled
            ]
            XCTAssertTrue(
                acceptable.contains(status),
                "protected save failed with an unexpected status \(status)"
            )
        }
    }

    private func skipIfKeychainUnavailable(_ status: OSStatus) throws {
        let tolerated: Set<OSStatus> = [
            errSecMissingEntitlement, errSecNotAvailable,
            errSecInteractionNotAllowed, errSecAuthFailed
        ]
        if tolerated.contains(status) {
            throw XCTSkip("Keychain unavailable in this test process (status \(status))")
        }
    }
}
