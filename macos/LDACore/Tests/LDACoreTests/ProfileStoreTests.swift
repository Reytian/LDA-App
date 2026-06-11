//
//  ProfileStoreTests.swift
//  LDACoreTests
//
//  Encrypted .ldaprofile round trips and failure modes.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import Security
@testable import LDACore

final class ProfileStoreTests: XCTestCase {

    // MARK: - Hermetic working directory

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileStoreTests-\(UUID().uuidString)", isDirectory: true)
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

    private func tempURL() -> URL {
        workDir
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ProfileStore.fileExtension)
    }

    // MARK: - Sample fixture

    /// Build a profile with a stable UUID so round-trip equality works. Called
    /// once per test into a local let; never called twice and compared (UUID()
    /// would differ across calls).
    private func sampleProfile() -> ClientPortfolio {
        ClientPortfolio(
            label: "Acme",
            fields: [
                ProfileField(
                    id: UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!,
                    key: .companyName,
                    value: "Acme Holdings Limited",
                    sourceDocument: "cert.pdf",
                    sourceSnippet: "the name of the company is Acme Holdings Limited",
                    snippetVerified: true,
                    confidence: 0.95,
                    userEdited: false
                )
            ],
            sourceDocuments: ["cert.pdf"],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            incomplete: false
        )
    }

    // MARK: - Tests

    func testPassphraseRoundTrip() throws {
        // Build the profile ONCE so the stable UUID is consistent across save and compare.
        let original = sampleProfile()
        let url = tempURL()
        try ProfileStore.save(original, to: url, protection: .passphrase("long enough pass"))
        let back = try ProfileStore.load(from: url, protection: .passphrase("long enough pass"))
        XCTAssertEqual(back, original)
    }

    func testWrongPassphraseFails() throws {
        let url = tempURL()
        try ProfileStore.save(sampleProfile(), to: url, protection: .passphrase("right right right"))
        XCTAssertThrowsError(
            try ProfileStore.load(from: url, protection: .passphrase("wrong wrong wrong"))
        ) { error in
            guard case DocumentIOError.decryptionFailed = error else {
                XCTFail("Expected decryptionFailed for wrong passphrase, got \(error)")
                return
            }
        }
    }

    func testPlaintextNeverOnDisk() throws {
        let url = tempURL()
        try ProfileStore.save(sampleProfile(), to: url, protection: .passphrase("long enough pass"))
        let raw = try Data(contentsOf: url)
        // The PII value must not appear verbatim anywhere in the stored bytes.
        XCTAssertFalse(
            raw.range(of: Data("Acme Holdings".utf8)) != nil,
            "PII found in raw file bytes"
        )
        XCTAssertNil(
            String(data: raw, encoding: .utf8)?.range(of: "Acme Holdings"),
            "PII found via string decode of file"
        )
    }

    func testMappingContainerRejectedByProfileStore() throws {
        // A .ldamap container must not load as a profile (different magic bytes).
        let mapping = Mapping(
            entries: [:],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            sourceFile: "test.pdf"
        )
        let url = tempURL()
        try MappingStore.save(mapping, to: url, protection: .passphrase("p p p p p"))
        XCTAssertThrowsError(
            try ProfileStore.load(from: url, protection: .passphrase("p p p p p"))
        ) { error in
            guard case DocumentIOError.corrupt = error else {
                XCTFail("Expected corrupt for mismatched magic (mapping vs profile), got \(error)")
                return
            }
        }
    }

    func testTamperedByteCausesDecryptionFailed() throws {
        // Arrange
        let url = tempURL()
        let passphrase = "tamper-test-passphrase"
        try ProfileStore.save(sampleProfile(), to: url, protection: .passphrase(passphrase))

        var bytes = try Data(contentsOf: url)
        // Flip a bit deep inside the ciphertext region (well past the header and
        // salt) so AES-GCM authentication fails on load.
        let tamperIndex = bytes.count - 4
        XCTAssertGreaterThan(tamperIndex, 0)
        bytes[tamperIndex] ^= 0xFF
        try bytes.write(to: url)

        // Act + Assert
        XCTAssertThrowsError(
            try ProfileStore.load(from: url, protection: .passphrase(passphrase))
        ) { error in
            guard case DocumentIOError.decryptionFailed = error else {
                XCTFail("Expected decryptionFailed for tampered file, got \(error)")
                return
            }
        }
    }

    func testLoadingTruncatedContainerThrowsCorrupt() throws {
        // A file that is not a valid container should not be reported as a
        // decryption failure; it is structurally corrupt.
        let url = tempURL()
        try Data("not a real container".utf8).write(to: url)

        XCTAssertThrowsError(
            try ProfileStore.load(from: url, protection: .passphrase("whatever"))
        ) { error in
            guard case DocumentIOError.corrupt = error else {
                XCTFail("Expected corrupt for a non-container file, got \(error)")
                return
            }
        }
    }

    // MARK: - Account derivation helpers

    func testStandardAccountDerivation() {
        let url = URL(fileURLWithPath: "/tmp/Acme Matter.ldaprofile")
        XCTAssertEqual(ProfileStore.standardAccount(for: url), "Acme Matter")
        XCTAssertEqual(ProfileStore.legacyAccount(for: url), "Acme Matter.ldaprofile")
    }

    // MARK: - Keychain fallback (tolerant)

    /// Saves under the LEGACY (extension-included) account and then loads via
    /// loadWithAccountFallback. Proves the legacy fallback path. Skipped when
    /// the unsigned test process cannot access the Keychain.
    func testKeychainLoadFallsBackToLegacyAccountOrSkip() throws {
        let url = tempURL()
        let profile = sampleProfile()
        let standardAcc = ProfileStore.standardAccount(for: url)
        let legacyAcc = ProfileStore.legacyAccount(for: url)

        // Clean up any stale keys from a previous run.
        try? ProfileStore.deleteKeychainKey(account: standardAcc)
        try? ProfileStore.deleteKeychainKey(account: legacyAcc)

        // Save using the legacy (extension-included) account directly.
        do {
            try ProfileStore.save(profile, to: url, protection: .keychain(account: legacyAcc))
        } catch let DocumentIOError.keychainError(status) {
            try skipIfKeychainUnavailable(status)
            XCTFail("Keychain save failed with status \(status)")
            return
        }

        defer {
            try? ProfileStore.deleteKeychainKey(account: standardAcc)
            try? ProfileStore.deleteKeychainKey(account: legacyAcc)
        }

        // Load using the fallback helper: standard account will fail, legacy
        // account should succeed.
        let back: ClientPortfolio
        do {
            back = try ProfileStore.loadWithAccountFallback(from: url)
        } catch let DocumentIOError.keychainError(status) {
            try skipIfKeychainUnavailable(status)
            XCTFail("Keychain load failed with status \(status)")
            return
        }

        XCTAssertEqual(back.label, profile.label)
    }

    /// Saves under the STANDARD (extension-less) account and then loads via
    /// loadWithAccountFallback. Proves the primary path.
    func testKeychainStandardAccountRoundTripOrSkip() throws {
        let url = tempURL()
        let profile = sampleProfile()
        let standardAcc = ProfileStore.standardAccount(for: url)
        let legacyAcc = ProfileStore.legacyAccount(for: url)

        try? ProfileStore.deleteKeychainKey(account: standardAcc)
        try? ProfileStore.deleteKeychainKey(account: legacyAcc)

        do {
            try ProfileStore.save(profile, to: url, protection: .keychain(account: standardAcc))
        } catch let DocumentIOError.keychainError(status) {
            try skipIfKeychainUnavailable(status)
            XCTFail("Keychain save failed with status \(status)")
            return
        }

        defer {
            try? ProfileStore.deleteKeychainKey(account: standardAcc)
            try? ProfileStore.deleteKeychainKey(account: legacyAcc)
        }

        let back: ClientPortfolio
        do {
            back = try ProfileStore.loadWithAccountFallback(from: url)
        } catch let DocumentIOError.keychainError(status) {
            try skipIfKeychainUnavailable(status)
            XCTFail("Keychain load failed with status \(status)")
            return
        }

        XCTAssertEqual(back.label, profile.label)
    }

    // MARK: - Helpers

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
}
