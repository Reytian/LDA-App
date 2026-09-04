//
//  UserPresenceKeychainDiagnosticTests.swift
//  LDACoreTests
//
//  Observes the REAL OSStatus that a user-presence keychain add returns on this
//  machine, instead of inferring it.
//
//  Why this exists: Touch ID protection has never engaged once. The Keychain
//  holds 40 silent key items under ai.openclaw.lda.* and zero under the
//  ".userpresence" account suffix, and that stayed true after running a
//  Developer ID signed, sandboxed build. addProtectedKey's SecItemAdd fails,
//  migrateToUserPresence swallows it, and the silent key is kept, so nothing
//  breaks and nothing is said.
//
//  Two candidate causes, which call for DIFFERENT fixes, and the status code is
//  what separates them:
//
//    errSecMissingEntitlement (-34018) means the process lacks a keychain
//    access group. Biometry ACL items live in the data-protection keychain,
//    which requires an application identifier; the shipped app is signed with
//    only four entitlements and none of them is one. That fix is a signing
//    change and belongs to whoever holds the provisioning profile.
//
//    errSecParam (-50) or errSecNotAvailable points somewhere else entirely:
//    the code never sets kSecUseDataProtectionKeychain, so on macOS the add
//    targets the LEGACY FILE keychain, where a .userPresence access control on
//    a generic password is not honoured the way the call site assumes. That
//    fix is a code change, and adding the entitlement alone would not help.
//
//  This test never fails on the status. It records it, because a diagnostic
//  that fails is a diagnostic somebody deletes. Read the printed line.
//
//  It also asserts the one thing that IS a defect regardless of which cause
//  wins: that the source has not silently started depending on the
//  data-protection keychain without saying so.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LocalAuthentication
import Security
import XCTest

final class UserPresenceKeychainDiagnosticTests: XCTestCase {

    /// A service name of this test's own, so the probe can never collide with
    /// or delete a real ai.openclaw.lda.* key. Those hold the only copies of
    /// the mapping-sidecar keys and losing one makes documents unrestorable.
    private let probeService = "ai.openclaw.lda.diagnostic.userpresence.probe"
    private let probeAccount = "probe.userpresence"

    override func tearDown() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount
        ] as CFDictionary)
        super.tearDown()
    }

    func testRecordTheRealUserPresenceAddStatus() throws {
        var accessControlError: Unmanaged<CFError>?
        let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.userPresence],
            &accessControlError
        )
        guard let accessControl else {
            let message = accessControlError.map {
                CFErrorCopyDescription($0.takeRetainedValue()) as String
            } ?? "unknown"
            print("""
            [USER-PRESENCE DIAGNOSTIC] SecAccessControlCreateWithFlags FAILED \
            before any add was attempted: \(message)
            """)
            return
        }

        // Probe A: exactly what EncryptedContainer.addProtectedKey does today,
        // with no data-protection keychain hint.
        let legacy = attemptAdd(accessControl: accessControl, dataProtection: false)
        // Probe B: the same add, explicitly targeting the data-protection
        // keychain, which is where biometry items are supposed to live.
        let modern = attemptAdd(accessControl: accessControl, dataProtection: true)

        print("""

        ================ USER-PRESENCE KEYCHAIN DIAGNOSTIC ================
        process is signed for a keychain group: \(hasKeychainAccessGroupEntitlement())
        biometry available:                     \(biometryAvailability())

        A) as shipped, no kSecUseDataProtectionKeychain:
           \(describe(legacy))
        B) same add with kSecUseDataProtectionKeychain = true:
           \(describe(modern))

        -34018 errSecMissingEntitlement -> signing fix (application identifier)
        -50    errSecParam              -> code fix (wrong keychain targeted)
        0      success                  -> the add works here; the failure is
                                           elsewhere in migrateToUserPresence
        ===================================================================

        """)

        // Deliberately no assertion on the status: this is instrumentation.
        // A diagnostic that can fail the suite is one somebody deletes, and
        // the value here is the recorded line, not a pass or a fail.
    }

    /// The invariant worth guarding while the cause is still open: if a future
    /// change starts asking for the data-protection keychain, that is a real
    /// behaviour change on macOS and must be deliberate, not incidental.
    func testTheSourceDoesNotQuietlyAdoptTheDataProtectionKeychain() throws {
        let container = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LDACore/Security/EncryptedContainer.swift")
        let source = try String(contentsOf: container, encoding: .utf8)
        let mentions = source
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .filter { $0.contains("kSecUseDataProtectionKeychain") }
        XCTAssertTrue(
            mentions.isEmpty,
            "EncryptedContainer now targets the data-protection keychain. That "
                + "is very likely the correct fix for Touch ID, but it changes "
                + "which keychain every container key lives in, so it needs a "
                + "migration story for the 40 existing silent items and this "
                + "guard should be replaced by one that pins the migration. "
                + "Offending lines: \(mentions)"
        )
    }

    // MARK: - Probes

    private func attemptAdd(accessControl: SecAccessControl, dataProtection: Bool) -> OSStatus {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount
        ] as CFDictionary)

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount,
            kSecValueData as String: Data("probe".utf8),
            kSecAttrAccessControl as String: accessControl,
            // Never prompt during the probe: the question is whether the item
            // can be CREATED, not whether a human is present.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        if dataProtection {
            attributes[kSecUseDataProtectionKeychain as String] = true
        }
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    private func describe(_ status: OSStatus) -> String {
        guard let message = SecCopyErrorMessageString(status, nil) as String? else {
            return "OSStatus \(status)"
        }
        return "OSStatus \(status) (\(message))"
    }

    private func biometryAvailability() -> String {
        let context = LAContext()
        var error: NSError?
        let can = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
        if can { return "yes, \(context.biometryType == .touchID ? "Touch ID" : "other")" }
        return "no (\(error?.localizedDescription ?? "unknown"))"
    }

    private func hasKeychainAccessGroupEntitlement() -> Bool {
        // A process with no application identifier has no keychain group, which
        // is the condition the entitlement hypothesis rests on.
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.application-identifier" as CFString,
            nil
        )
        return value != nil
    }
}
