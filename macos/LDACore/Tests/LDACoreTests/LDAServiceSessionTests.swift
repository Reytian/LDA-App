//
//  LDAServiceSessionTests.swift
//  LDACoreTests
//
//  Tests for the session-level service API: anonymizeSession (N documents in,
//  N redacted Markdown intermediates out, ONE shared mapping) and restoreText
//  (paste-based restore of AI output against a saved mapping sidecar). This is
//  the headless half of the staged round-trip: redact, hand to AI, bring back,
//  restore.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class LDAServiceSessionTests: XCTestCase {

    private let stamp = "2026-06-11T00:00:00Z"
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDAServiceSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    func testAnonymizeSessionSharesOneMappingAcrossDocuments() throws {
        // Deterministic-only detection: emails are detected in both documents.
        let doc1 = try write("a.txt", "Contact john@acme.com for the contract.")
        let doc2 = try write("b.txt", "Send to john@acme.com and mary@beta.io.")

        let result = try LDAService.anonymizeSession(
            inputs: [doc1, doc2],
            createdAtISO8601: stamp
        )

        XCTAssertEqual(result.documents.count, 2)
        // The shared address uses ONE token in both documents.
        XCTAssertTrue(result.documents[0].redactedMarkdown.contains("{EMAIL_1}"))
        XCTAssertTrue(result.documents[1].redactedMarkdown.contains("{EMAIL_1}"))
        XCTAssertTrue(result.documents[1].redactedMarkdown.contains("{EMAIL_2}"))
        XCTAssertEqual(result.mapping.entries.count, 2)
        XCTAssertEqual(result.mapping.entries["{EMAIL_1}"]?.value, "john@acme.com")
        // No raw value survives in any intermediate.
        for document in result.documents {
            XCTAssertFalse(document.redactedMarkdown.contains("john@acme.com"))
            XCTAssertFalse(document.redactedMarkdown.contains("mary@beta.io"))
        }
    }

    func testSessionRoundTripThroughEditedMarkdown() throws {
        let doc1 = try write("a.txt", "Wire to account holder at john@acme.com today.")
        let doc2 = try write("b.txt", "CC mary@beta.io on everything.")

        let session = try LDAService.anonymizeSession(
            inputs: [doc1, doc2],
            createdAtISO8601: stamp
        )

        // Save the shared mapping like the app would, then simulate the AI
        // lightly editing each intermediate before restore.
        let mappingURL = workDir.appendingPathComponent("session.ldamap")
        try MappingStore.save(session.mapping, to: mappingURL, protection: .passphrase("pw"))

        let edited1 = "Edited draft: " + session.documents[0].redactedMarkdown
        let report1 = try LDAService.restoreText(
            edited1,
            mapping: mappingURL,
            protection: .passphrase("pw")
        )
        XCTAssertEqual(report1.text, "Edited draft: Wire to account holder at john@acme.com today.")
        XCTAssertEqual(report1.restoredCount, 1)

        let edited2 = session.documents[1].redactedMarkdown.replacingOccurrences(of: "CC", with: "Copy")
        let report2 = try LDAService.restoreText(
            edited2,
            mapping: mappingURL,
            protection: .passphrase("pw")
        )
        XCTAssertEqual(report2.text, "Copy mary@beta.io on everything.")
    }

    func testAnonymizeSessionWithSeedMappingKeepsClientIdentities() throws {
        let doc = try write("a.txt", "Email john@acme.com again.")
        let seedEntry = MappingEntry(
            token: "{EMAIL_7}",
            value: "john@acme.com",
            type: .email,
            surfaceText: "john@acme.com",
            aliases: []
        )
        let seed = Mapping(
            entries: [seedEntry.token: seedEntry],
            createdAtISO8601: stamp,
            sourceFile: "client-acme"
        )

        let result = try LDAService.anonymizeSession(
            inputs: [doc],
            createdAtISO8601: stamp,
            seedMapping: seed
        )

        XCTAssertTrue(result.documents[0].redactedMarkdown.contains("{EMAIL_7}"))
        XCTAssertEqual(result.mapping.entries.count, 1)
    }

    func testAnonymizeSessionRejectsEmptyInput() {
        XCTAssertThrowsError(
            try LDAService.anonymizeSession(inputs: [], createdAtISO8601: stamp)
        )
    }

    func testRestoreTextFlagsOrphansAndSuspects() throws {
        let doc = try write("a.txt", "Reach john@acme.com now.")
        let session = try LDAService.anonymizeSession(inputs: [doc], createdAtISO8601: stamp)
        let mappingURL = workDir.appendingPathComponent("session.ldamap")
        try MappingStore.save(session.mapping, to: mappingURL, protection: .passphrase("pw"))

        // The AI dropped one brace and invented a token-shaped string.
        let mangled = "Reach [EMAIL_1] or {EMAIL_9} now."
        let report = try LDAService.restoreText(
            mangled,
            mapping: mappingURL,
            protection: .passphrase("pw")
        )
        XCTAssertEqual(report.restoredCount, 0)
        XCTAssertEqual(report.orphanTokens, ["{EMAIL_9}"])
        XCTAssertEqual(report.suspectPlaceholders, ["[EMAIL_1]"])
    }
}
