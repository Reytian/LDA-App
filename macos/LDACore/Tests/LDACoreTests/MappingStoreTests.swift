//
//  MappingStoreTests.swift
//  LDACoreTests
//
//  Tests for the AES-GCM encrypted Mapping sidecar (the re-identification key).
//
//  These tests are hermetic: every fixture is written into a unique directory
//  under FileManager.temporaryDirectory and removed in tearDown. No binaries are
//  committed. The passphrase path is the primary tested path. Keychain assertions
//  are tolerant: in a non-app, unsigned test process the Keychain may be
//  unavailable (errSecMissingEntitlement / errSecNotAvailable), in which case the
//  test is skipped with XCTSkip rather than failed.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import Security
@testable import LDACore

final class MappingStoreTests: XCTestCase {

    // MARK: - Hermetic working directory

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappingStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A known secret surface value embedded in the fixture mapping. The on-disk
    /// container must never contain this byte sequence in the clear.
    private static let knownSecretValue = "Jane Q. Confidential-Person-12345"

    /// Builds a Mapping fixture carrying the known secret surface value.
    private func makeFixtureMapping() -> Mapping {
        let entry = MappingEntry(
            token: "{PERSON_1}",
            value: Self.knownSecretValue,
            type: .person,
            surfaceText: Self.knownSecretValue,
            aliases: ["Jane Confidential", "J. Confidential"]
        )
        let secondEntry = MappingEntry(
            token: "{EMAIL_1}",
            value: "jane.confidential@example-secret.test",
            type: .email,
            surfaceText: "jane.confidential@example-secret.test",
            aliases: []
        )
        return Mapping(
            entries: ["{PERSON_1}": entry, "{EMAIL_1}": secondEntry],
            createdAtISO8601: "2026-06-06T00:00:00Z",
            sourceFile: "engagement-letter.docx"
        )
    }

    // MARK: - Passphrase round-trip

    func testPassphraseRoundTripReturnsEqualMapping() throws {
        // Arrange
        let mapping = makeFixtureMapping()
        let url = workDir.appendingPathComponent("mapping.ldamap")
        let passphrase = "correct horse battery staple"

        // Act
        try MappingStore.save(mapping, to: url, protection: .passphrase(passphrase))
        let loaded = try MappingStore.load(from: url, protection: .passphrase(passphrase))

        // Assert
        XCTAssertEqual(loaded, mapping)
    }

    func testWrongPassphraseThrowsDecryptionFailed() throws {
        // Arrange
        let mapping = makeFixtureMapping()
        let url = workDir.appendingPathComponent("mapping.ldamap")
        try MappingStore.save(mapping, to: url, protection: .passphrase("right-passphrase"))

        // Act + Assert
        XCTAssertThrowsError(
            try MappingStore.load(from: url, protection: .passphrase("wrong-passphrase"))
        ) { error in
            guard case DocumentIOError.decryptionFailed = error else {
                XCTFail("Expected decryptionFailed, got \(error)")
                return
            }
        }
    }

    func testWrittenBytesDoNotContainKnownSecret() throws {
        // Arrange
        let mapping = makeFixtureMapping()
        let url = workDir.appendingPathComponent("mapping.ldamap")

        // Act
        try MappingStore.save(mapping, to: url, protection: .passphrase("a-strong-passphrase"))
        let onDisk = try Data(contentsOf: url)

        // Assert: the plaintext secret surface value must be absent from disk.
        let secretBytes = Data(Self.knownSecretValue.utf8)
        XCTAssertFalse(
            dataContains(onDisk, subsequence: secretBytes),
            "On-disk container leaked the plaintext secret value"
        )

        // Also assert a couple of other plaintext surfaces are absent.
        XCTAssertFalse(
            dataContains(onDisk, subsequence: Data("engagement-letter.docx".utf8)),
            "On-disk container leaked the plaintext sourceFile"
        )
        XCTAssertFalse(
            dataContains(onDisk, subsequence: Data("jane.confidential@example-secret.test".utf8)),
            "On-disk container leaked the plaintext email value"
        )

        // The magic header IS expected to be present in the clear.
        XCTAssertTrue(
            dataContains(onDisk, subsequence: Data("LDAMAP".utf8)),
            "Container should carry the magic header"
        )
    }

    func testTamperedByteCausesDecryptionFailed() throws {
        // Arrange
        let mapping = makeFixtureMapping()
        let url = workDir.appendingPathComponent("mapping.ldamap")
        let passphrase = "tamper-test-passphrase"
        try MappingStore.save(mapping, to: url, protection: .passphrase(passphrase))

        var bytes = try Data(contentsOf: url)
        // Flip a bit deep inside the ciphertext region (well past the header and
        // salt) so AES-GCM authentication fails on load.
        let tamperIndex = bytes.count - 4
        XCTAssertGreaterThan(tamperIndex, 0)
        bytes[tamperIndex] ^= 0xFF
        try bytes.write(to: url)

        // Act + Assert
        XCTAssertThrowsError(
            try MappingStore.load(from: url, protection: .passphrase(passphrase))
        ) { error in
            guard case DocumentIOError.decryptionFailed = error else {
                XCTFail("Expected decryptionFailed for tampered file, got \(error)")
                return
            }
        }
    }

    func testPassphraseSaltDiffersAcrossSaves() throws {
        // Two saves of the same mapping with the same passphrase must produce
        // different ciphertext because a fresh random salt and nonce are used.
        let mapping = makeFixtureMapping()
        let urlA = workDir.appendingPathComponent("a.ldamap")
        let urlB = workDir.appendingPathComponent("b.ldamap")
        let passphrase = "shared-passphrase"

        try MappingStore.save(mapping, to: urlA, protection: .passphrase(passphrase))
        try MappingStore.save(mapping, to: urlB, protection: .passphrase(passphrase))

        let dataA = try Data(contentsOf: urlA)
        let dataB = try Data(contentsOf: urlB)
        XCTAssertNotEqual(dataA, dataB, "Encrypted containers should not be identical across saves")

        // Both must still decrypt to the same mapping.
        XCTAssertEqual(
            try MappingStore.load(from: urlA, protection: .passphrase(passphrase)),
            try MappingStore.load(from: urlB, protection: .passphrase(passphrase))
        )
    }

    func testLoadingTruncatedContainerThrowsCorrupt() throws {
        // A file that is not a valid container should not be reported as a
        // decryption failure; it is structurally corrupt.
        let url = workDir.appendingPathComponent("garbage.ldamap")
        try Data("not a real container".utf8).write(to: url)

        XCTAssertThrowsError(
            try MappingStore.load(from: url, protection: .passphrase("whatever"))
        ) { error in
            guard case DocumentIOError.corrupt = error else {
                XCTFail("Expected corrupt for a non-container file, got \(error)")
                return
            }
        }
    }

    // MARK: - Keychain path (tolerant)

    func testKeychainRoundTripOrSkip() throws {
        let account = TestNamespace.keychainAccount("mappingstore")
        let mapping = makeFixtureMapping()
        let url = workDir.appendingPathComponent("keychain.ldamap")

        // Ensure no stale key, ignoring Keychain availability problems.
        try? MappingStore.deleteKeychainKey(account: account)

        do {
            try MappingStore.save(mapping, to: url, protection: .keychain(account: account))
        } catch let DocumentIOError.keychainError(status) {
            try skipIfKeychainUnavailable(status)
            // A non-skippable Keychain status is a genuine failure.
            XCTFail("Keychain save failed with status \(status)")
            return
        }

        defer { try? MappingStore.deleteKeychainKey(account: account) }

        let loaded: Mapping
        do {
            loaded = try MappingStore.load(from: url, protection: .keychain(account: account))
        } catch let DocumentIOError.keychainError(status) {
            try skipIfKeychainUnavailable(status)
            XCTFail("Keychain load failed with status \(status)")
            return
        }

        XCTAssertEqual(loaded, mapping)

        // The on-disk container must not leak the secret in the Keychain path either.
        let onDisk = try Data(contentsOf: url)
        XCTAssertFalse(
            dataContains(onDisk, subsequence: Data(Self.knownSecretValue.utf8)),
            "Keychain-protected container leaked the plaintext secret value"
        )
    }

    /// Skips the current test when a Keychain status indicates the service is
    /// unavailable in this unsigned, non-app test process.
    private func skipIfKeychainUnavailable(_ status: OSStatus) throws {
        let tolerated: Set<OSStatus> = [
            errSecMissingEntitlement,
            errSecNotAvailable,
            errSecInteractionNotAllowed,
            errSecAuthFailed
        ]
        if tolerated.contains(status) {
            throw XCTSkip("Keychain unavailable in this test process (status \(status))")
        }
    }

    // MARK: - Helpers

    /// Returns true when haystack contains the exact byte subsequence needle.
    private func dataContains(_ haystack: Data, subsequence needle: Data) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else {
            return false
        }
        let haystackBytes = [UInt8](haystack)
        let needleBytes = [UInt8](needle)
        let lastStart = haystackBytes.count - needleBytes.count
        var start = 0
        while start <= lastStart {
            var matched = true
            var offset = 0
            while offset < needleBytes.count {
                if haystackBytes[start + offset] != needleBytes[offset] {
                    matched = false
                    break
                }
                offset += 1
            }
            if matched {
                return true
            }
            start += 1
        }
        return false
    }
}
