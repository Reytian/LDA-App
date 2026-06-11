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

        // Register cleanup unconditionally so it runs even if save fails or throws.
        defer {
            try? ProfileStore.deleteKeychainKey(account: standardAcc)
            try? ProfileStore.deleteKeychainKey(account: legacyAcc)
        }

        // Save using the legacy (extension-included) account directly.
        do {
            try ProfileStore.save(profile, to: url, protection: .keychain(account: legacyAcc))
        } catch let DocumentIOError.keychainError(status) {
            try skipIfKeychainUnavailable(status)
            XCTFail("Keychain save failed with status \(status)")
            return
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

        // Register cleanup unconditionally so it runs even if save fails or throws.
        defer {
            try? ProfileStore.deleteKeychainKey(account: standardAcc)
            try? ProfileStore.deleteKeychainKey(account: legacyAcc)
        }

        do {
            try ProfileStore.save(profile, to: url, protection: .keychain(account: standardAcc))
        } catch let DocumentIOError.keychainError(status) {
            try skipIfKeychainUnavailable(status)
            XCTFail("Keychain save failed with status \(status)")
            return
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

    // MARK: - Keychain fallback: legacy CLI account

    /// Saves under the legacy CLI account ("lda-" prefix) and then loads via
    /// loadWithAccountFallback. Proves the legacy-CLI fallback path. Skipped
    /// when the unsigned test process cannot access the Keychain.
    func testKeychainFallbackFromLegacyCLIAccountOrSkip() throws {
        let url = tempURL()
        let profile = sampleProfile()
        let standardAcc = ProfileStore.standardAccount(for: url)
        let legacyAcc = ProfileStore.legacyAccount(for: url)
        let legacyCLIAcc = ProfileStore.legacyCLIAccount(for: url)

        // Verify the format is what we expect.
        XCTAssertEqual(legacyCLIAcc, "lda-\(standardAcc)")

        // Clean up any stale keys from a previous run.
        try? ProfileStore.deleteKeychainKey(account: standardAcc)
        try? ProfileStore.deleteKeychainKey(account: legacyAcc)
        try? ProfileStore.deleteKeychainKey(account: legacyCLIAcc)

        // Register cleanup unconditionally so it runs even if save fails or throws.
        defer {
            try? ProfileStore.deleteKeychainKey(account: standardAcc)
            try? ProfileStore.deleteKeychainKey(account: legacyAcc)
            try? ProfileStore.deleteKeychainKey(account: legacyCLIAcc)
        }

        // Save using the legacy CLI account directly.
        do {
            try ProfileStore.save(profile, to: url, protection: .keychain(account: legacyCLIAcc))
        } catch let DocumentIOError.keychainError(status) {
            try skipIfKeychainUnavailable(status)
            XCTFail("Keychain save failed with status \(status)")
            return
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

    // MARK: - Keychain fallback: legacy MCP account

    /// Saves under the legacy MCP account ("ai.openclaw.lda.mcp.profile." prefix)
    /// and then loads via loadWithAccountFallback. Proves the legacy-MCP fallback
    /// path. Skipped when the unsigned test process cannot access the Keychain.
    func testKeychainFallbackFromLegacyMCPAccountOrSkip() throws {
        let url = tempURL()
        let profile = sampleProfile()
        let standardAcc = ProfileStore.standardAccount(for: url)
        let legacyAcc = ProfileStore.legacyAccount(for: url)
        let legacyMCPAcc = ProfileStore.legacyMCPAccount(for: url)

        // Verify the format is what we expect.
        XCTAssertEqual(legacyMCPAcc, "ai.openclaw.lda.mcp.profile.\(standardAcc)")

        // Clean up any stale keys from a previous run.
        try? ProfileStore.deleteKeychainKey(account: standardAcc)
        try? ProfileStore.deleteKeychainKey(account: legacyAcc)
        try? ProfileStore.deleteKeychainKey(account: legacyMCPAcc)

        // Register cleanup unconditionally so it runs even if save fails or throws.
        defer {
            try? ProfileStore.deleteKeychainKey(account: standardAcc)
            try? ProfileStore.deleteKeychainKey(account: legacyAcc)
            try? ProfileStore.deleteKeychainKey(account: legacyMCPAcc)
        }

        // Save using the legacy MCP account directly.
        do {
            try ProfileStore.save(profile, to: url, protection: .keychain(account: legacyMCPAcc))
        } catch let DocumentIOError.keychainError(status) {
            try skipIfKeychainUnavailable(status)
            XCTFail("Keychain save failed with status \(status)")
            return
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

    // MARK: - Keychain fallback: decryption error takes priority

    /// Saves a profile under the STANDARD Keychain account, tampers the file
    /// bytes, then calls loadWithAccountFallback. Even though the standard
    /// account succeeds at the Keychain lookup, the tampered ciphertext causes
    /// decryptionFailed; the subsequent legacy-account lookups yield keychainError
    /// ("item not found"). The method must surface decryptionFailed, not the
    /// trailing keychainError. Skipped when the unsigned test process cannot
    /// access the Keychain.
    func testFallbackPrefersDecryptionFailureOverMissingKeys() throws {
        let url = tempURL()
        let profile = sampleProfile()
        let standardAcc = ProfileStore.standardAccount(for: url)
        let legacyAcc = ProfileStore.legacyAccount(for: url)
        let legacyCLIAcc = ProfileStore.legacyCLIAccount(for: url)
        let legacyMCPAcc = ProfileStore.legacyMCPAccount(for: url)

        // Pre-cleanup.
        try? ProfileStore.deleteKeychainKey(account: standardAcc)
        try? ProfileStore.deleteKeychainKey(account: legacyAcc)
        try? ProfileStore.deleteKeychainKey(account: legacyCLIAcc)
        try? ProfileStore.deleteKeychainKey(account: legacyMCPAcc)

        // Register cleanup unconditionally before any save.
        defer {
            try? ProfileStore.deleteKeychainKey(account: standardAcc)
            try? ProfileStore.deleteKeychainKey(account: legacyAcc)
            try? ProfileStore.deleteKeychainKey(account: legacyCLIAcc)
            try? ProfileStore.deleteKeychainKey(account: legacyMCPAcc)
        }

        // Save under the standard account.
        do {
            try ProfileStore.save(profile, to: url, protection: .keychain(account: standardAcc))
        } catch let DocumentIOError.keychainError(status) {
            try skipIfKeychainUnavailable(status)
            XCTFail("Keychain save failed with status \(status)")
            return
        }

        // Tamper the file: flip a byte deep in the ciphertext region so
        // AES-GCM authentication fails on load.
        var bytes = try Data(contentsOf: url)
        let tamperIndex = bytes.count - 4
        XCTAssertGreaterThan(tamperIndex, 0)
        bytes[tamperIndex] ^= 0xFF
        try bytes.write(to: url)

        // loadWithAccountFallback must throw decryptionFailed. The standard
        // account finds the key but the ciphertext is tampered. The legacy
        // accounts produce keychainError (item not found). The first
        // high-priority error wins.
        do {
            _ = try ProfileStore.loadWithAccountFallback(from: url)
            XCTFail("Expected loadWithAccountFallback to throw for a tampered file")
        } catch let DocumentIOError.keychainError(status) {
            // If the Keychain itself is unavailable (CI, unsigned process), skip.
            try skipIfKeychainUnavailable(status)
            XCTFail("Expected decryptionFailed for tampered file, got keychainError(\(status))")
        } catch DocumentIOError.decryptionFailed {
            // Correct: the tampered-file error surfaces, not a keychainError.
        } catch {
            XCTFail("Expected decryptionFailed for tampered file, got \(error)")
        }
    }

    // MARK: - Keychain fallback: all accounts fail

    /// Verifies that loadWithAccountFallback throws when no account holds a key.
    /// Uses a passphrase-mode file so all Keychain lookups will fail with a
    /// decryption error rather than a Keychain API error, making this test
    /// reliable in environments where the Keychain is available but the key is
    /// genuinely absent.
    func testLoadWithAccountFallbackThrowsWhenAllFail() throws {
        let url = tempURL()
        // Save with a passphrase; no Keychain key is stored.
        try ProfileStore.save(sampleProfile(), to: url, protection: .passphrase("some-pass"))

        // loadWithAccountFallback tries each Keychain account in turn. Because
        // the file was saved with a passphrase and no Keychain key was written,
        // every Keychain attempt will fail. The method must throw.
        do {
            _ = try ProfileStore.loadWithAccountFallback(from: url)
            XCTFail("Expected loadWithAccountFallback to throw when no Keychain key exists")
        } catch let DocumentIOError.keychainError(status) {
            // Acceptable: Keychain item not found (-25300) or unavailable
            // in this process. Either means all accounts failed as expected.
            _ = status
        } catch DocumentIOError.decryptionFailed {
            // Also acceptable: the Keychain returned some other key or a
            // placeholder that does not decrypt the file.
        } catch {
            // Any error from the final attempt is fine; just confirm it throws.
            _ = error
        }
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
