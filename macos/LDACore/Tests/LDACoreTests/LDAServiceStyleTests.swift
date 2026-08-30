//
//  LDAServiceStyleTests.swift
//  LDACoreTests
//
//  Service-facade tests for the output styles: anonymize and restore with
//  .pseudonym and .asterisk across the txt and docx edit surfaces, the
//  session path with a shared style, and the cross-document pseudonym
//  uniqueness guarantee.
//
//  Detection here is deterministic-only (no model), so fixtures use the
//  structured PII the deterministic engine recognizes (emails, CN mobiles,
//  national IDs).
//
//  House rules: all comments and strings in English. Fixture strings and
//  generated pseudonyms may be Chinese. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class LDAServiceStyleTests: XCTestCase {

    private static let email = "jane.doe@example.com"
    private static let cnMobile = "13912345678"
    private static let createdAt = "2026-08-30T00:00:00Z"
    private static let passphrase = "style-service-passphrase"

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDAServiceStyleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        try super.tearDownWithError()
    }

    private func writeText(_ text: String, name: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: - Pseudonym, txt round trip

    func testTextPseudonymAnonymizeThenRestoreIsByteIdentical() throws {
        let original = "Reach the client at \(Self.email) or \(Self.cnMobile). Buyer agrees."
        let input = try writeText(original, name: "letter.txt")
        let outputDir = workDir.appendingPathComponent("out", isDirectory: true)

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: .passphrase(Self.passphrase),
            createdAtISO8601: Self.createdAt,
            style: .pseudonym
        )

        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertFalse(redacted.contains(Self.email))
        XCTAssertFalse(redacted.contains(Self.cnMobile))
        XCTAssertFalse(redacted.contains("{"), "pseudonym output must carry no brace tokens")
        XCTAssertTrue(redacted.contains("contact1@example.com"))
        XCTAssertTrue(redacted.contains("Phone 1"))

        // The sidecar remembers its style.
        let loaded = try MappingStore.load(
            from: result.mappingFileURL,
            protection: .passphrase(Self.passphrase)
        )
        XCTAssertEqual(loaded.style, .pseudonym)

        let restoredURL = workDir.appendingPathComponent("restored.txt")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase(Self.passphrase),
            output: restoredURL
        )
        XCTAssertEqual(try String(contentsOf: restoredURL, encoding: .utf8), original)
        XCTAssertEqual(report.restoredCount, 2)
        XCTAssertTrue(report.orphanTokens.isEmpty)
        XCTAssertTrue(report.ambiguousReplacements.isEmpty)
    }

    // MARK: - Asterisk, txt round trip with a collision

    func testTextAsteriskRestoreRefusesAmbiguousMask() throws {
        // Two CN mobiles that mask to the same 138****5678, plus one email
        // whose mask is unique. Restore must bring back the email and refuse
        // both phones.
        let phoneA = "13812345678"
        let phoneB = "13887655678"
        let original = "A: \(phoneA) B: \(phoneB) mail \(Self.email)."
        let input = try writeText(original, name: "contacts.txt")
        let outputDir = workDir.appendingPathComponent("out-ast", isDirectory: true)

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: .passphrase(Self.passphrase),
            createdAtISO8601: Self.createdAt,
            style: .asterisk
        )

        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertFalse(redacted.contains(phoneA))
        XCTAssertFalse(redacted.contains(phoneB))
        XCTAssertFalse(redacted.contains(Self.email))
        XCTAssertTrue(redacted.contains("138****5678"))

        let restoredURL = workDir.appendingPathComponent("restored-ast.txt")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase(Self.passphrase),
            output: restoredURL
        )

        let restored = try String(contentsOf: restoredURL, encoding: .utf8)
        XCTAssertTrue(restored.contains(Self.email), "the unique mask restores")
        XCTAssertTrue(restored.contains("138****5678"), "the colliding mask stays masked")
        XCTAssertFalse(restored.contains(phoneA), "an ambiguous mask must never be guessed")
        XCTAssertFalse(restored.contains(phoneB), "an ambiguous mask must never be guessed")
        XCTAssertEqual(report.ambiguousReplacements, ["138****5678"])
        XCTAssertEqual(report.restoredCount, 1)
    }

    // MARK: - Pseudonym, docx round trip

    func testDocxPseudonymAnonymizeThenRestoreRoundTrips() throws {
        let original = "Contact \(Self.email) about the engagement. Phone \(Self.cnMobile)."
        let input = workDir.appendingPathComponent("engagement.docx")
        try SimpleDocxWriter.write(original, to: input)
        let outputDir = workDir.appendingPathComponent("out-docx", isDirectory: true)

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: .passphrase(Self.passphrase),
            createdAtISO8601: Self.createdAt,
            style: .pseudonym
        )
        XCTAssertEqual(result.redactedFileURL.pathExtension.lowercased(), "docx")

        // The redacted docx text carries pseudonyms, not brace tokens.
        let redactedText = try DocxImporter().importDocument(result.redactedFileURL).text
        XCTAssertFalse(redactedText.contains(Self.email))
        XCTAssertFalse(redactedText.contains(Self.cnMobile))
        XCTAssertTrue(redactedText.contains("contact1@example.com"))
        XCTAssertFalse(redactedText.contains("{EMAIL_1}"))

        let restoredURL = workDir.appendingPathComponent("restored.docx")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase(Self.passphrase),
            output: restoredURL
        )

        let restoredText = try DocxImporter().importDocument(restoredURL).text
        XCTAssertTrue(restoredText.contains(Self.email))
        XCTAssertTrue(restoredText.contains(Self.cnMobile))
        XCTAssertEqual(report.restoredCount, 2)
        XCTAssertTrue(report.orphanTokens.isEmpty)
    }

    // MARK: - Session with a shared style

    func testSessionPseudonymSharesPseudonymsAcrossDocuments() throws {
        let doc1 = try writeText("First: reach \(Self.email) today.", name: "one.txt")
        let doc2 = try writeText("Second: \(Self.email) confirms receipt.", name: "two.txt")

        let session = try LDAService.anonymizeSession(
            inputs: [doc1, doc2],
            createdAtISO8601: Self.createdAt,
            style: .pseudonym
        )

        XCTAssertEqual(session.mapping.style, .pseudonym)
        XCTAssertEqual(session.documents.count, 2)
        for document in session.documents {
            XCTAssertFalse(document.redactedMarkdown.contains(Self.email))
            XCTAssertTrue(
                document.redactedMarkdown.contains("contact1@example.com"),
                "the same surface must carry the same pseudonym in every document"
            )
        }

        // The one shared mapping restores both intermediates.
        for (document, expected) in zip(
            session.documents,
            ["First: reach \(Self.email) today.", "Second: \(Self.email) confirms receipt."]
        ) {
            let restored = Restorer.restore(text: document.redactedMarkdown, mapping: session.mapping)
            XCTAssertEqual(restored.text, expected)
        }
    }

    func testSessionPseudonymAvoidsCompanionDocumentCollision() throws {
        // Document two contains the literal string "Phone 1" as prose. The
        // phone pseudonym minted for document one must skip it, otherwise
        // restoring document two would corrupt that prose.
        let doc1 = try writeText("Call \(Self.cnMobile) now.", name: "call.txt")
        let doc2 = try writeText("The Phone 1 extension list is attached.", name: "list.txt")

        let session = try LDAService.anonymizeSession(
            inputs: [doc1, doc2],
            createdAtISO8601: Self.createdAt,
            style: .pseudonym
        )

        XCTAssertTrue(session.documents[0].redactedMarkdown.contains("Phone 2"))
        XCTAssertFalse(session.documents[0].redactedMarkdown.contains(Self.cnMobile))

        // Restoring the untouched document two leaves its prose intact.
        let restored = Restorer.restore(
            text: session.documents[1].redactedMarkdown,
            mapping: session.mapping
        )
        XCTAssertEqual(restored.text, "The Phone 1 extension list is attached.")
    }

    // MARK: - Default stays token

    func testDefaultStyleRemainsTokenEndToEnd() throws {
        let original = "Mail \(Self.email)."
        let input = try writeText(original, name: "default.txt")
        let outputDir = workDir.appendingPathComponent("out-default", isDirectory: true)

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: .passphrase(Self.passphrase),
            createdAtISO8601: Self.createdAt
        )
        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertTrue(redacted.contains("{EMAIL_1}"), "omitting style must keep the token behavior")

        let loaded = try MappingStore.load(
            from: result.mappingFileURL,
            protection: .passphrase(Self.passphrase)
        )
        XCTAssertEqual(loaded.style, .token)
    }
}
