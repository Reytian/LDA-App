//
//  CLIKeychainRoundTripTests.swift
//  LDACoreTests
//
//  The CLI round trip WITHOUT --passphrase, which is the recommended way to
//  use it: the mapping is protected by a per-document key in the macOS
//  Keychain instead of a passphrase on the command line.
//
//  Why this file exists: every existing CLI round-trip test passes an explicit
//  passphrase, so the Keychain branch of protectionFor was never exercised end
//  to end. anonymize derived its account from the SOURCE file's base name while
//  restore derived its account from the EDITED REDACTED file's base name, which
//  are different strings ("doc" against "doc_redacted"), so the key was written
//  under one account and looked up under another and every keychain-protected
//  restore failed with errSecItemNotFound.
//
//  The account is now derived from the MAPPING file's base name at both ends,
//  which is the one name both commands can see, matching what the MCP server
//  already did.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import Security
@testable import LDACLI
@testable import LDACore

final class CLIKeychainRoundTripTests: XCTestCase {

    private var tempDir: URL!
    private let sampleText = """
    ENGAGEMENT LETTER

    Client: Jane Aoife Smith
    Email: jane.smith@example.test
    Date: 2024-01-15

    The Buyer shall pay the Seller on completion.
    """
    private var createdAccounts: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIKeychainRoundTrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        createdAccounts = []
    }

    override func tearDownWithError() throws {
        for account in createdAccounts {
            try? MappingStore.deleteKeychainKey(account: account)
        }
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    /// Write the sample under a PROCESS-UNIQUE base name, and return both the
    /// URL and that base.
    ///
    /// The CLI derives the sidecar's Keychain account from the document base
    /// name ("lda-<mapping base>"). A fixed name such as "doc.txt" is therefore
    /// one Keychain account for the whole machine, and this suite deletes those
    /// accounts in tearDown, which would destroy a concurrent run's key while
    /// that run is still restoring with it.
    private func writeSample(_ label: String) throws -> (url: URL, base: String) {
        let base = TestNamespace.fileBaseName(label)
        let url = tempDir.appendingPathComponent("\(base).txt")
        try Data(sampleText.utf8).write(to: url)
        return (url, base)
    }

    // MARK: - The round trip

    func testAnonymizeThenRestoreWithNoPassphraseRoundTrips() throws {
        // Arrange
        let input = try writeSample("doc").url

        // Act: anonymize with NO passphrase, so the Keychain path is used.
        let anonymized: AnonymizeResult
        do {
            anonymized = try LDACLI.runAnonymize(
                input: input,
                outputDir: tempDir,
                passphrase: nil,
                timestamp: { "2026-08-27T00:00:00Z" }
            )
        } catch DocumentIOError.keychainError(let status) {
            throw XCTSkip("Keychain unavailable in this environment (status \(status))")
        }
        createdAccounts.append(
            LDACLI.keychainAccount(
                forMappingBaseName: anonymized.mappingFileURL
                    .deletingPathExtension().lastPathComponent
            )
        )

        // Act: restore, also with no passphrase.
        let output = tempDir.appendingPathComponent("restored.txt")
        let report = try LDACLI.runRestore(
            input: anonymized.redactedFileURL,
            mapping: anonymized.mappingFileURL,
            output: output,
            passphrase: nil
        )

        // Assert
        let restored = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(
            restored, sampleText,
            "the keychain-protected round trip must return the original byte for byte"
        )
        XCTAssertGreaterThan(report.restoredCount, 0)
        XCTAssertEqual(report.orphanTokens, [])
    }

    func testTheAccountIsDerivedFromTheMappingNameAtBothEnds() throws {
        // The two commands see different files. The mapping's base name is the
        // one name both of them have, which is why it is the account source.
        let input = URL(fileURLWithPath: "/tmp/doc.txt")
        let mapping = URL(fileURLWithPath: "/tmp/doc_redacted.ldamap")

        let anonymizeAccount = LDACLI.protectionFor(
            passphrase: nil,
            derivedAccount: LDACLI.mappingBaseName(forInput: input)
        )
        let restoreAccount = LDACLI.protectionFor(
            passphrase: nil,
            derivedAccount: mapping.deletingPathExtension().lastPathComponent
        )

        guard case .keychain(let writeAccount) = anonymizeAccount,
              case .keychain(let readAccount) = restoreAccount else {
            return XCTFail("expected keychain protection on both sides")
        }
        XCTAssertEqual(
            writeAccount, readAccount,
            "a key written under one account and read under another can never be found"
        )
    }

    func testAPassphraseStillOverridesTheKeychain() throws {
        let input = try writeSample("doc2").url

        let anonymized = try LDACLI.runAnonymize(
            input: input,
            outputDir: tempDir,
            passphrase: "the pass phrase",
            timestamp: { "2026-08-27T00:00:00Z" }
        )
        let output = tempDir.appendingPathComponent("restored2.txt")
        let report = try LDACLI.runRestore(
            input: anonymized.redactedFileURL,
            mapping: anonymized.mappingFileURL,
            output: output,
            passphrase: "the pass phrase"
        )

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), sampleText)
        XCTAssertGreaterThan(report.restoredCount, 0)
    }

    // MARK: - Backward compatibility

    func testASidecarWrittenUnderTheOldAccountStillRestores() throws {
        // Sidecars produced by earlier builds have their key under the SOURCE
        // base name ("lda-<source>"), not the mapping base name
        // ("lda-<source>_redacted"). Those files must keep restoring.
        let (input, legacyBase) = try writeSample("legacy")

        // Produce the artifacts, then re-save the mapping under the OLD account
        // to simulate a sidecar from a previous build.
        let anonymized = try LDACLI.runAnonymize(
            input: input,
            outputDir: tempDir,
            passphrase: "temporary",
            timestamp: { "2026-08-27T00:00:00Z" }
        )
        let mapping = try MappingStore.load(
            from: anonymized.mappingFileURL,
            protection: .passphrase("temporary")
        )
        let legacyAccount = LDACLI.keychainAccount(forMappingBaseName: legacyBase)
        do {
            try MappingStore.save(
                mapping,
                to: anonymized.mappingFileURL,
                protection: .keychain(account: legacyAccount)
            )
        } catch DocumentIOError.keychainError(let status) {
            throw XCTSkip("Keychain unavailable in this environment (status \(status))")
        }
        createdAccounts.append(legacyAccount)

        // Act
        let output = tempDir.appendingPathComponent("legacy_restored.txt")
        let report = try LDACLI.runRestore(
            input: anonymized.redactedFileURL,
            mapping: anonymized.mappingFileURL,
            output: output,
            passphrase: nil
        )

        // Assert
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), sampleText)
        XCTAssertGreaterThan(report.restoredCount, 0)
    }

    func testAMissingKeyOnBothAccountsReportsBothFailures() throws {
        // When the per-document key is gone AND the legacy fallback fails too,
        // the user must see both facts. Reporting only the second attempt hides
        // that a silent retry ran, the same masking the MCP edge was fixed for.
        let (input, sourceBase) = try writeSample("bothgone")
        let anonymized: AnonymizeResult
        do {
            anonymized = try LDACLI.runAnonymize(
                input: input,
                outputDir: tempDir,
                passphrase: nil,
                timestamp: { "2026-08-27T00:00:00Z" }
            )
        } catch DocumentIOError.keychainError {
            throw XCTSkip("Keychain unavailable in this environment")
        }
        let mappingBase = anonymized.mappingFileURL.deletingPathExtension().lastPathComponent
        // Remove the per-document key and make sure no legacy key exists either.
        try? MappingStore.deleteKeychainKey(
            account: LDACLI.keychainAccount(forMappingBaseName: mappingBase)
        )
        try? MappingStore.deleteKeychainKey(
            account: LDACLI.keychainAccount(forMappingBaseName: sourceBase)
        )

        XCTAssertThrowsError(
            try LDACLI.runRestore(
                input: anonymized.redactedFileURL,
                mapping: anonymized.mappingFileURL,
                output: tempDir.appendingPathComponent("nope2.txt"),
                passphrase: nil
            )
        ) { error in
            guard case CLIError.restoreFailedAfterLegacyRetry = error else {
                XCTFail("Expected the both-failures report, got \(error)")
                return
            }
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Per-document key"), "got: \(message)")
            XCTAssertTrue(message.contains("Legacy account"), "got: \(message)")
        }
    }

    func testAGenuinelyMissingKeyStillFails() throws {
        // The legacy fallback must not turn a missing key into a silent success
        // or an unrelated error.
        let input = try writeSample("orphan").url
        let anonymized = try LDACLI.runAnonymize(
            input: input,
            outputDir: tempDir,
            passphrase: "temporary",
            timestamp: { "2026-08-27T00:00:00Z" }
        )

        XCTAssertThrowsError(
            try LDACLI.runRestore(
                input: anonymized.redactedFileURL,
                mapping: anonymized.mappingFileURL,
                output: tempDir.appendingPathComponent("nope.txt"),
                passphrase: nil
            )
        ) { error in
            // A passphrase container read with keychain protection is a
            // decryption failure, and it must surface as one.
            switch error {
            case DocumentIOError.decryptionFailed, DocumentIOError.keychainError:
                break
            default:
                XCTFail("Expected a decrypt or keychain failure, got \(error)")
            }
        }
    }
}
