//
//  UserPresenceKeychainInvariantsTests.swift
//  LDACoreTests
//
//  Pins the two invariants that make Touch ID protection actually work once
//  the app is signed with a keychain access group, and the one rule that keeps
//  the headless surfaces from corrupting what the app sealed.
//
//  BACKGROUND. Touch ID protection had never engaged once. The measured cause
//  (UserPresenceKeychainAddMatrixTests) is that an ACL item needs a keychain
//  access group, which the app's Developer ID signature never carried, so
//  SecItemAdd returned errSecMissingEntitlement and the code fell back to a
//  silent key. A provisioning profile now grants the group. That alone is NOT
//  the fix, and this file exists because of the half that is easy to miss:
//
//  1. THE FLAG. Biometry-protected items live only in the data-protection
//     keychain, and on macOS SecItem targets the file keychain unless a call
//     passes kSecUseDataProtectionKeychain. With the entitlement present but
//     the flag absent, the protected ADD and the protected LOOKUP would aim at
//     different keychains: every launch mints afresh, and the second launch
//     cannot open what the first one sealed. The flag must be on every
//     protected path, and must NOT be on the legacy silent paths, which have
//     40 existing keys in the file keychain that still need reading.
//
//  2. THE HEADLESS RULE. Data-protection items are invisible to a process
//     without the entitlement. The CLI, the MCP server and the unsandboxed dev
//     binary all read the login keychain silently, and they share fixed
//     account names with the app. Once the app migrates a key and deletes the
//     silent original, a headless process misses. If it then MINTED, the same
//     account would hold two keys and every later restore would be a coin
//     toss. So a miss against a container that already exists is a refusal,
//     never a mint; a container that does not exist yet is a genuine first
//     use.
//
//  Source-text pins are used for (1) because the behaviour cannot be observed
//  from an unentitled test process (every protected add returns -34018 here),
//  matching the convention in TestHermeticityTests. Rule (2) IS observable
//  from a test process and is exercised for real below.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import XCTest
@testable import LDACore

final class UserPresenceKeychainInvariantsTests: XCTestCase {

    private static let containerSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LDACore/Security/EncryptedContainer.swift")

    private static let flag = "kSecUseDataProtectionKeychain"

    private func source() throws -> String {
        try String(contentsOf: Self.containerSource, encoding: .utf8)
    }

    /// The body of `name`, from its declaration to the next top-level `func`
    /// or the end of the type. Good enough for these pins: each function here
    /// is short and none nests another `func`.
    private func body(of name: String, in text: String) throws -> Substring {
        let start = try XCTUnwrap(
            text.range(of: "func \(name)("),
            "EncryptedContainer.swift no longer declares \(name); repoint this pin"
        )
        let after = text[start.upperBound...]
        let end = after.range(of: "\n    private func ")
            ?? after.range(of: "\n    public func ")
            ?? after.range(of: "\n    // MARK:")
        return end.map { after[..<$0.lowerBound] } ?? after
    }

    // MARK: - 1. The flag is on every protected path and no legacy path

    func testEveryProtectedKeychainCallTargetsTheDataProtectionKeychain() throws {
        let text = try source()
        XCTAssertTrue(
            try body(of: "lookupProtectedKey", in: text).contains(Self.flag),
            "the protected lookup must search the data-protection keychain, or "
                + "it can never find the key addProtectedKey stored"
        )
        let add = try body(of: "addProtectedKey", in: text)
        XCTAssertEqual(
            add.components(separatedBy: Self.flag).count - 1, 2,
            "addProtectedKey must carry the flag TWICE: on the stale-copy delete "
                + "and on the add itself, so both aim at the keychain the item "
                + "lives in"
        )
        XCTAssertTrue(
            try body(of: "deleteKeychainKey", in: text).contains(Self.flag),
            "deleteKeychainKey must aim the protected-copy delete at the "
                + "data-protection keychain, or a deleted key leaves a Touch ID "
                + "item behind"
        )
    }

    func testNoLegacySilentPathTargetsTheDataProtectionKeychain() throws {
        let text = try source()
        for name in ["addSilentKey", "lookupLegacyKey"] {
            XCTAssertFalse(
                try body(of: name, in: text).contains(Self.flag),
                "\(name) is the legacy file-keychain path; 40 existing silent keys "
                    + "live there and must stay readable. Moving it silently "
                    + "relocates every key with no migration."
            )
        }
        // migrateToUserPresence deletes the SILENT original after the protected
        // add succeeds. That delete must target the file keychain, so the
        // function body may mention the flag only through addProtectedKey,
        // never on its own SecItemDelete.
        let migrate = try body(of: "migrateToUserPresence", in: text)
        let ownDelete = try XCTUnwrap(
            migrate.range(of: "SecItemDelete("),
            "migrateToUserPresence must still delete the silent original"
        )
        let deleteArgs = migrate[ownDelete.upperBound...].prefix(400)
        XCTAssertFalse(
            deleteArgs.contains(Self.flag),
            "the silent-original delete in migrateToUserPresence must NOT carry the "
                + "flag: the item it removes is in the file keychain"
        )
    }

    func testMigrationAddsTheProtectedCopyBeforeDeletingTheSilentOne() throws {
        let migrate = try body(of: "migrateToUserPresence", in: try source())
        let add = try XCTUnwrap(migrate.range(of: "addProtectedKey("))
        let delete = try XCTUnwrap(migrate.range(of: "SecItemDelete("))
        XCTAssertTrue(
            add.lowerBound < delete.lowerBound,
            "the protected copy must be written BEFORE the silent original is "
                + "removed, so a failure mid-way never loses the key"
        )
    }

    // MARK: - 2. A headless process refuses to mint over an existing container

    private var workDir: URL!
    private var account: String!
    private let container = EncryptedContainer(
        magic: Array("LDATEST".utf8),
        keychainService: "ai.openclaw.lda.testkey",
        containerDescription: "test container"
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserPresenceInvariants-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        account = TestNamespace.keychainAccount("userpresence-invariants")
    }

    override func tearDownWithError() throws {
        if let account {
            try? container.deleteKeychainKey(account: account)
        }
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        try super.tearDownWithError()
    }

    func testAMissAgainstAnExistingContainerRefusesRatherThanMinting() throws {
        // Test processes run without the user-presence policy, exactly like
        // the CLI and the MCP server.
        XCTAssertFalse(KeychainAccessPolicy.requireUserPresence)

        let url = workDir.appendingPathComponent("sealed.bin")
        try container.save(Data("first".utf8), to: url, protection: .keychain(account: account))
        let sealedBytes = try Data(contentsOf: url)

        // Simulate what the packaged app does: the silent key is gone from
        // the keychain this process can see (migrated into the protected
        // store, which is invisible from here).
        try container.deleteKeychainKey(account: account)

        do {
            try container.save(Data("second".utf8), to: url, protection: .keychain(account: account))
            XCTFail(
                "a headless process must refuse to mint a key over a container "
                    + "that already exists: minting here forks the account into "
                    + "two keys and the app can no longer open what this wrote"
            )
        } catch DocumentIOError.unreadable(let message) {
            XCTAssertTrue(
                message.contains("already exists") && message.contains("Touch ID"),
                "the refusal must explain what happened and where the key is: \(message)"
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: url), sealedBytes,
            "the refusal must leave the existing container byte-for-byte untouched"
        )
    }

    func testAMissAgainstANewContainerStillMints() throws {
        XCTAssertFalse(KeychainAccessPolicy.requireUserPresence)
        let url = workDir.appendingPathComponent("fresh.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // No file, no key: a genuine first use, and minting is correct.
        try container.save(Data("hello".utf8), to: url, protection: .keychain(account: account))
        XCTAssertEqual(
            try container.load(from: url, protection: .keychain(account: account)),
            Data("hello".utf8),
            "a first-use save must mint and the same process must read it back"
        )
    }
}
