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
            .appendingPathExtension("ldaprofile")
    }

    // MARK: - Sample fixture

    /// Build a profile with a stable UUID so round-trip equality works. Called
    /// once per test into a local let; never called twice and compared (UUID()
    /// would differ across calls).
    private func sampleProfile() -> CompanyProfile {
        CompanyProfile(
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
}
