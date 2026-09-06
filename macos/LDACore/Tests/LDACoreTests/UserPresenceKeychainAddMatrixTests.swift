//
//  UserPresenceKeychainAddMatrixTests.swift
//  LDACoreTests
//
//  The second user-presence diagnostic. It exists because of a number the
//  first one could not explain.
//
//  UserPresenceKeychainDiagnosticTests recorded OSStatus -50 (errSecParam) for
//  a user-presence add against BOTH the legacy file keychain and the
//  data-protection keychain. The entitlement hypothesis predicts -34018
//  (errSecMissingEntitlement) for the data-protection probe, so either the
//  hypothesis is incomplete or the probe passed something the add rejects. It
//  did: that probe sets kSecUseAuthenticationUI = kSecUseAuthenticationUISkip,
//  and SecItem.h says of that value "This value can be used only with
//  SecItemCopyMatching". The real addProtectedKey never passes it, so the
//  first probe measured its own dictionary and not the shipped one.
//
//  This test takes the attribute set apart one key at a time and records the
//  OSStatus of every combination against both keychains, so each candidate
//  cause (the Skip value, an LAContext on an add, an access control the file
//  keychain will not hold, the missing keychain access group) is either seen
//  to move the status or seen not to. One variant mirrors addProtectedKey's
//  dictionary exactly, and one drives the real EncryptedContainer.save under
//  the policy so the end-to-end status is printed instead of being absorbed
//  by an assertion. Nothing here fails on a status: this is instrumentation,
//  and the value is the printed table.
//
//  Every item lives under this file's own service name and a process-unique
//  account, and tearDown sweeps both keychains, so no real ai.openclaw.lda.*
//  key is ever read or removed.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import LDACore

final class UserPresenceKeychainAddMatrixTests: XCTestCase {

    private let probeService = "ai.openclaw.lda.diagnostic.userpresence.matrix"
    private var mintedAccounts: [String] = []

    override func tearDown() {
        sweepProbeItems()
        super.tearDown()
    }

    // MARK: - The matrix

    private enum AccessControlChoice {
        /// No kSecAttrAccessControl at all.
        case none
        /// SecAccessControl(WhenUnlockedThisDeviceOnly, [.userPresence]), as
        /// addProtectedKey builds it.
        case userPresence
        /// SecAccessControl(WhenUnlockedThisDeviceOnly, []): a control object
        /// with no constraint, to separate "any access control" from
        /// "user presence" as the thing a keychain rejects.
        case noFlags
    }

    private enum ContextChoice {
        case none
        /// KeychainAccessPolicy.sharedAuthenticationContext, the very object
        /// addProtectedKey passes.
        case shared
        /// A fresh LAContext with interactionNotAllowed = true, the modern
        /// replacement for kSecUseAuthenticationUIFail.
        case noInteraction
    }

    private enum UIChoice {
        case none, skip, allow, fail
    }

    private struct Variant {
        let name: String
        let accessControl: AccessControlChoice
        let context: ContextChoice
        let ui: UIChoice
        /// kSecAttrAccessible set directly on the item, as addSilentKey does.
        let accessible: Bool
    }

    private static let variants: [Variant] = [
        Variant(name: "plain silent add (control)",
                accessControl: .none, context: .none, ui: .none, accessible: false),
        Variant(name: "addSilentKey mirror (kSecAttrAccessible only)",
                accessControl: .none, context: .none, ui: .none, accessible: true),
        Variant(name: "first probe as written (ACL + UISkip)",
                accessControl: .userPresence, context: .none, ui: .skip, accessible: false),
        Variant(name: "addProtectedKey mirror (ACL + shared LAContext)",
                accessControl: .userPresence, context: .shared, ui: .none, accessible: false),
        Variant(name: "ACL only",
                accessControl: .userPresence, context: .none, ui: .none, accessible: false),
        Variant(name: "ACL with no flags",
                accessControl: .noFlags, context: .none, ui: .none, accessible: false),
        Variant(name: "shared LAContext only",
                accessControl: .none, context: .shared, ui: .none, accessible: false),
        Variant(name: "UISkip only",
                accessControl: .none, context: .none, ui: .skip, accessible: false),
        Variant(name: "ACL + UIAllow",
                accessControl: .userPresence, context: .none, ui: .allow, accessible: false),
        Variant(name: "ACL + UIFail",
                accessControl: .userPresence, context: .none, ui: .fail, accessible: false),
        Variant(name: "ACL + LAContext.interactionNotAllowed",
                accessControl: .userPresence, context: .noInteraction, ui: .none, accessible: false)
    ]

    private struct Outcome {
        let name: String
        let dataProtection: Bool
        let status: OSStatus
    }

    // MARK: - Test

    func testRecordEveryUserPresenceAddStatus() throws {
        var adds: [Outcome] = []
        for (index, variant) in Self.variants.enumerated() {
            for dataProtection in [false, true] {
                let status = try attemptAdd(variant, index: index, dataProtection: dataProtection)
                adds.append(Outcome(name: variant.name, dataProtection: dataProtection, status: status))
            }
        }
        let queries = recordQueryAndDeleteStatuses()
        let endToEnd = recordEndToEndSaveOutcome()

        print("""

        ============ USER-PRESENCE KEYCHAIN ADD MATRIX ============
        \(processFacts())

        SecItemAdd, one generic password per row, probe service only:
        \(table(adds))

        SecItemCopyMatching / SecItemDelete on an ABSENT probe item:
        \(table(queries))

        EncryptedContainer.save under requireUserPresence = true:
           \(endToEnd)

        legend: 0 success, -50 errSecParam, -34018 errSecMissingEntitlement,
                -25300 errSecItemNotFound, -25308 errSecInteractionNotAllowed
        ===========================================================

        """)
        // No assertion on any status: this is instrumentation, and a diagnostic
        // that can fail the suite is one somebody deletes.
    }

    // MARK: - Adds

    private func attemptAdd(_ variant: Variant, index: Int, dataProtection: Bool) throws -> OSStatus {
        let account = mintAccount("matrix-\(index)-\(dataProtection ? "dp" : "file")")
        deleteProbeItem(account: account, dataProtection: dataProtection)

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data("probe".utf8)
        ]
        switch variant.accessControl {
        case .none:
            break
        case .userPresence:
            attributes[kSecAttrAccessControl as String] = try makeAccessControl(flags: [.userPresence])
        case .noFlags:
            attributes[kSecAttrAccessControl as String] = try makeAccessControl(flags: [])
        }
        switch variant.context {
        case .none:
            break
        case .shared:
            attributes[kSecUseAuthenticationContext as String] =
                KeychainAccessPolicy.sharedAuthenticationContext
        case .noInteraction:
            let context = LAContext()
            context.interactionNotAllowed = true
            attributes[kSecUseAuthenticationContext as String] = context
        }
        switch variant.ui {
        case .none:
            break
        case .skip:
            attributes[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        case .allow:
            attributes[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIAllow
        case .fail:
            attributes[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        if variant.accessible {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        if dataProtection {
            attributes[kSecUseDataProtectionKeychain as String] = true
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            deleteProbeItem(account: account, dataProtection: dataProtection)
        }
        return status
    }

    private func makeAccessControl(flags: SecAccessControlCreateFlags) throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        let control = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
            &error
        )
        let message = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? ""
        return try XCTUnwrap(control, "SecAccessControlCreateWithFlags failed: \(message)")
    }

    // MARK: - Queries and deletes

    private func recordQueryAndDeleteStatuses() -> [Outcome] {
        let account = mintAccount("matrix-query")
        var outcomes: [Outcome] = []

        func query(_ name: String, _ dataProtection: Bool, _ extra: [String: Any]) {
            var attributes: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: probeService,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            for (key, value) in extra { attributes[key] = value }
            if dataProtection { attributes[kSecUseDataProtectionKeychain as String] = true }
            var item: CFTypeRef?
            let status = SecItemCopyMatching(attributes as CFDictionary, &item)
            outcomes.append(Outcome(name: name, dataProtection: dataProtection, status: status))
        }

        let shared = [kSecUseAuthenticationContext as String: KeychainAccessPolicy.sharedAuthenticationContext as Any]
        let skip = [kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip as Any]
        for dataProtection in [false, true] {
            query("lookupProtectedKey mirror (shared LAContext)", dataProtection, shared)
            query("plain query", dataProtection, [:])
            query("query + UISkip", dataProtection, skip)

            var deletion: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: probeService,
                kSecAttrAccount as String: account
            ]
            if dataProtection { deletion[kSecUseDataProtectionKeychain as String] = true }
            let status = SecItemDelete(deletion as CFDictionary)
            outcomes.append(Outcome(name: "SecItemDelete", dataProtection: dataProtection, status: status))
        }
        return outcomes
    }

    // MARK: - End to end through the production code

    /// Drives EncryptedContainer.save with a fresh key under the policy. This is
    /// the path a brand-new user hits on first save. KeychainAccessPolicyTests
    /// runs the same call but treats a thrown errSecParam as acceptable, which
    /// hides the status this test exists to print.
    private func recordEndToEndSaveOutcome() -> String {
        let previous = KeychainAccessPolicy.requireUserPresence
        KeychainAccessPolicy.requireUserPresence = true
        defer { KeychainAccessPolicy.requireUserPresence = previous }

        let container = EncryptedContainer(
            magic: Array("LDAPROBE".utf8),
            keychainService: probeService,
            containerDescription: "user-presence matrix probe",
            auditing: false
        )
        let account = mintAccount("matrix-e2e")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).bin")
        defer {
            try? container.deleteKeychainKey(account: account)
            try? FileManager.default.removeItem(at: url)
        }

        do {
            try container.save(Data("probe".utf8), to: url, protection: .keychain(account: account))
            let silent = probeItemExists(account: account)
            let protected = probeItemExists(account: "\(account).userpresence")
            return "save SUCCEEDED; silent file-keychain item present: \(silent); "
                + ".userpresence file-keychain item present: \(protected)"
        } catch let DocumentIOError.keychainError(status) {
            return "save THREW DocumentIOError.keychainError \(describe(status)); "
                + "no fallback to a silent item happened"
        } catch {
            return "save threw \(error)"
        }
    }

    /// Attribute-only lookup in the file keychain: no data is returned, so no
    /// decrypt happens and no prompt can appear. UISkip is valid here because
    /// this is SecItemCopyMatching.
    private func probeItemExists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    // MARK: - Housekeeping

    private func mintAccount(_ label: String) -> String {
        let account = TestNamespace.keychainAccount(label)
        mintedAccounts.append(account)
        return account
    }

    private func deleteProbeItem(account: String, dataProtection: Bool) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: account
        ]
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        SecItemDelete(query as CFDictionary)
    }

    private func sweepProbeItems() {
        for account in mintedAccounts {
            for dataProtection in [false, true] {
                deleteProbeItem(account: account, dataProtection: dataProtection)
                deleteProbeItem(account: "\(account).userpresence", dataProtection: dataProtection)
            }
        }
        mintedAccounts.removeAll()
    }

    // MARK: - Reporting

    private func describe(_ status: OSStatus) -> String {
        EncryptedContainer.describeStatus(status)
    }

    private func table(_ outcomes: [Outcome]) -> String {
        outcomes.map { outcome in
            let name = outcome.name.padding(toLength: 50, withPad: " ", startingAt: 0)
            let keychain = (outcome.dataProtection ? "data-protection" : "file (legacy)  ")
            return "   \(name) \(keychain)  \(describe(outcome.status))"
        }.joined(separator: "\n")
    }

    private func processFacts() -> String {
        let task = SecTaskCreateFromSelf(nil)
        func entitlement(_ key: String) -> String {
            guard let task,
                  let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else {
                return "absent"
            }
            return String(describing: value)
        }
        let executable = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "unknown"
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let context = LAContext()
        var error: NSError?
        let biometry = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? "available (\(context.biometryType == .touchID ? "Touch ID" : "other"))"
            : "unavailable (\(error?.localizedDescription ?? "unknown"))"
        return """
        executable:                        \(executable)
        sandboxed:                         \(sandboxed)
        com.apple.application-identifier:  \(entitlement("com.apple.application-identifier"))
        keychain-access-groups:            \(entitlement("keychain-access-groups"))
        com.apple.security.app-sandbox:    \(entitlement("com.apple.security.app-sandbox"))
        biometry:                          \(biometry)
        """
    }
}
