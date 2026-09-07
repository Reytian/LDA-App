//
//  SessionEscapedLiteralReservationTests.swift
//  LDACoreTests
//
//  R6 (2026-09-07): the residual half of review finding 11. Reservation and
//  seam verification read the RAW text, while restore first decodes
//  Markdown-escaped tokens (PlaceholderForensics.decodeMarkdownEscapedTokens
//  turns "{PERSON\_1}" into "{PERSON_1}"). Every guard SessionLiteralReservation
//  pins for the plain spelling was therefore blind to the escaped one:
//
//  - In a two-document session, Alice minted {PERSON_1}; the untouched literal
//    "Fill in {PERSON\_1}." in document two restored as "Fill in Alice." with
//    no seam, orphan or ambiguity reported.
//  - A seeded single document spelling "{PERSON\_1}" passed
//    requireSafeForRelease and restored to the seed's value.
//  - The LDAService.anonymize facade accepted the same corruption.
//
//  The repaired contract: reservation unions the literals of the DECODED text
//  (this document and every companion), and the token-style seam audit
//  computes its restore sites over the decoded text with offsets mapped back
//  to the original. A pre-existing escaped literal then either stays literal
//  and is named as an orphan, or is refused with a seam issue. Never silent
//  corruption.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class SessionEscapedLiteralReservationTests: XCTestCase {

    private let stamp = "2026-09-07T00:00:00Z"

    /// The reviewer's exact literal: the exact token, Markdown-escaped.
    private static let escapedLiteral = #"Fill in {PERSON\_1}."#

    private struct FixedCompleter: TextCompleter {
        /// Answers only for the segment that actually contains the name, so a
        /// companion document is not handed a phantom entity to anchor.
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            guard prompt.contains("Alice Smith") else { return #"{"entities":[]}"# }
            return #"{"entities":[{"value":"Alice Smith","type":"PERSON"}]}"#
        }
    }

    private func span(_ text: String, in document: String, type: EntityType) -> Span {
        let range = (document as NSString).range(of: text)
        precondition(range.location != NSNotFound, "fixture span must exist")
        return Span(
            start: range.location,
            end: range.location + range.length,
            type: type,
            text: text,
            source: .llm,
            confidence: 0.9,
            priority: 10
        )
    }

    private func seed(_ entries: [MappingEntry]) -> Mapping {
        Mapping(
            entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.token, $0) }),
            createdAtISO8601: stamp,
            sourceFile: "earlier matter",
            style: .token
        )
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
    }

    override func tearDown() {
        LDAService.makeExtractorForTesting = nil
        super.tearDown()
    }

    // MARK: - Reservation covers the escaped spelling

    /// The reviewer's exact two-document session, driven through
    /// SessionTokenizer: a minted token must not spell the DECODED form of a
    /// companion's escaped literal.
    func testAMintedTokenNeverSpellsAnEscapedTemplateLiteralOfAnotherDocument() {
        let one = "Alice"
        let two = Self.escapedLiteral
        let session = SessionTokenizer.tokenize(
            documents: [
                SessionDocument(name: "one", text: one, spans: [span("Alice", in: one, type: .person)]),
                SessionDocument(name: "two", text: two, spans: [])
            ],
            sourceLabel: "Review",
            createdAtISO8601: stamp
        )

        XCTAssertEqual(
            session.documents[0].tokenizedText,
            "{PERSON_2}",
            "the escaped literal of document two decodes to {PERSON_1}, so it is reserved"
        )
        XCTAssertEqual(session.documents[1].tokenizedText, two, "the literal is left alone")
        XCTAssertTrue(session.seamIssues.isEmpty, "\(session.unresolvedSeams)")

        // The escape itself is normalized by the restore decode, which is a
        // deterministic decode of the exact token and not a substitution. What
        // matters is that no entity value lands in the template field.
        let restored = session.documents.map {
            Restorer.restore(text: $0.tokenizedText, mapping: session.mapping)
        }
        XCTAssertEqual(restored[0].text, one)
        XCTAssertEqual(restored[1].text, "Fill in {PERSON_1}.")
        XCTAssertFalse(restored[1].text.contains("Alice"), "the template field must not become an entity")
        XCTAssertEqual(restored[1].restoredCount, 0)
        XCTAssertEqual(
            restored[1].orphanTokens,
            ["{PERSON_1}"],
            "an unmapped literal is reported, never restored"
        )
    }

    /// Fold order does not matter: the escaped literal in the FIRST document
    /// is reserved before a later document mints.
    func testEscapedReservationHoldsWhenTheLiteralComesFirst() {
        let one = Self.escapedLiteral
        let two = "Alice"
        let session = SessionTokenizer.tokenize(
            documents: [
                SessionDocument(name: "one", text: one, spans: []),
                SessionDocument(name: "two", text: two, spans: [span("Alice", in: two, type: .person)])
            ],
            sourceLabel: "Review",
            createdAtISO8601: stamp
        )

        XCTAssertEqual(session.documents[1].tokenizedText, "{PERSON_2}")
        XCTAssertTrue(session.seamIssues.isEmpty, "\(session.unresolvedSeams)")
    }

    // MARK: - Verification covers the escaped spelling

    /// The reviewer's exact seeded single document: a carried seed token the
    /// document spells in escaped form cannot be reminted away, so the gate
    /// must refuse instead of returning an ordinary looking result.
    func testSeededEscapedLiteralIsRefusedForRelease() {
        let tokenized = Tokenizer.tokenize(
            text: Self.escapedLiteral,
            spans: [],
            sourceFile: "literal",
            createdAtISO8601: stamp,
            seedMapping: seed([
                MappingEntry(token: "{PERSON_1}", value: "Alice", type: .person, surfaceText: "Alice", aliases: [])
            ])
        )

        XCTAssertEqual(
            tokenized.seamIssues,
            [.unexpectedReplacement(documentIndex: 0, documentName: "literal", matchedReplacement: "{PERSON_1}")],
            "restore would put Alice into the template field, so the site must be named"
        )
        XCTAssertThrowsError(try Tokenizer.requireSafeForRelease(tokenized)) { error in
            guard case TokenizationSafetyError.unresolvedSeams(let seams) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(seams, tokenized.unresolvedSeams)
        }
        XCTAssertEqual(
            Restorer.restore(text: tokenized.tokenizedText, mapping: tokenized.mapping).text,
            "Fill in Alice.",
            "the mis-restore the refusal describes"
        )
    }

    /// The escaped literal sitting alongside a real entity is still refused,
    /// and the entity itself is minted clear of the reserved literal.
    func testSeededEscapedLiteralAlongsideAnEntityIsRefused() {
        let text = #"Use {PERSON\_1} here. John Smith signs."#
        let tokenized = Tokenizer.tokenize(
            text: text,
            spans: [span("John Smith", in: text, type: .person)],
            sourceFile: "doc2.txt",
            createdAtISO8601: stamp,
            seedMapping: seed([
                MappingEntry(
                    token: "{PERSON_1}",
                    value: "John Smith",
                    type: .person,
                    surfaceText: "John Smith",
                    aliases: []
                )
            ])
        )

        XCTAssertEqual(
            tokenized.seamIssues,
            [.unexpectedReplacement(documentIndex: 0, documentName: "doc2.txt", matchedReplacement: "{PERSON_1}")]
        )
        XCTAssertThrowsError(try Tokenizer.requireSafeForRelease(tokenized))
    }

    /// No false alarm: an ordinary document with no token-shaped literal at
    /// all still reports nothing once the audit reads decoded text.
    func testACleanDocumentReportsNoSeamAfterTheDecodedAudit() {
        let text = "Alice met Bob. A backslash \\_ on its own is not a token."
        let tokenized = Tokenizer.tokenize(
            text: text,
            spans: [span("Alice", in: text, type: .person), span("Bob", in: text, type: .person)],
            sourceFile: "clean.txt",
            createdAtISO8601: stamp
        )

        XCTAssertTrue(tokenized.seamIssues.isEmpty, "\(tokenized.unresolvedSeams)")
        XCTAssertNoThrow(try Tokenizer.requireSafeForRelease(tokenized))
        XCTAssertEqual(
            Restorer.restore(text: tokenized.tokenizedText, mapping: tokenized.mapping).text,
            text
        )
    }

    // MARK: - Restore round trip

    /// The escaped literal is never substituted when no mapping entry owns the
    /// token it decodes to.
    func testRestoreLeavesAnUnmappedEscapedLiteralUnsubstituted() {
        let mapping = Mapping(
            entries: [
                "{PERSON_2}": MappingEntry(
                    token: "{PERSON_2}",
                    value: "Alice",
                    type: .person,
                    surfaceText: "Alice",
                    aliases: []
                )
            ],
            createdAtISO8601: stamp,
            sourceFile: "session",
            style: .token
        )

        let restored = Restorer.restore(text: Self.escapedLiteral, mapping: mapping)

        XCTAssertEqual(restored.restoredCount, 0)
        XCTAssertFalse(restored.text.contains("Alice"))
        XCTAssertEqual(restored.orphanTokens, ["{PERSON_1}"])
    }

    // MARK: - The facade paths

    private func writeFixture(_ contents: [String]) throws -> (dir: URL, inputs: [URL]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionEscapedLiteralReservationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let inputs = try contents.enumerated().map { index, text -> URL in
            let url = dir.appendingPathComponent("doc\(index + 1).txt")
            try Data(text.utf8).write(to: url)
            return url
        }
        return (dir, inputs)
    }

    /// The reviewer's two-document session through the real session facade.
    func testAnonymizeSessionDoesNotRestoreTheEscapedLiteralToAnEntity() throws {
        let fixture = try writeFixture(["Alice Smith signed the deed.", Self.escapedLiteral])
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        LDAService.makeExtractorForTesting = { _ in LLMExtractor(completer: FixedCompleter()) }

        let result = try LDAService.anonymizeSession(
            inputs: fixture.inputs,
            createdAtISO8601: stamp,
            llmModelPath: "/nonexistent.gguf"
        )

        XCTAssertTrue(result.seamIssues.isEmpty, "\(result.seamIssues)")
        XCTAssertEqual(
            result.documents[0].redactedMarkdown,
            "{PERSON_2} signed the deed.",
            "the companion's escaped literal is reserved"
        )
        XCTAssertEqual(result.documents[1].redactedMarkdown, Self.escapedLiteral)

        let restored = Restorer.restore(
            text: result.documents[1].redactedMarkdown,
            mapping: result.mapping
        )
        XCTAssertEqual(restored.text, "Fill in {PERSON_1}.")
        XCTAssertFalse(restored.text.contains("Alice"))
        XCTAssertEqual(restored.orphanTokens, ["{PERSON_1}"])
    }

    /// The single-document facade run the reviewer also reproduced.
    func testAnonymizeDoesNotMintOverAnEscapedLiteralInTheSameDocument() throws {
        let fixture = try writeFixture([#"Alice Smith signed. Fill in {PERSON\_1}."#])
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        LDAService.makeExtractorForTesting = { _ in LLMExtractor(completer: FixedCompleter()) }
        let outputDir = fixture.dir.appendingPathComponent("out", isDirectory: true)

        let result = try LDAService.anonymize(
            input: fixture.inputs[0],
            outputDir: outputDir,
            protection: .passphrase("synthetic"),
            createdAtISO8601: stamp,
            llmModelPath: "/nonexistent.gguf"
        )

        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertEqual(redacted, #"{PERSON_2} signed. Fill in {PERSON\_1}."#)

        let mapping = try MappingStore.load(
            from: result.mappingFileURL,
            protection: .passphrase("synthetic")
        )
        let restored = Restorer.restore(text: redacted, mapping: mapping)
        XCTAssertEqual(
            restored.text,
            "Alice Smith signed. Fill in {PERSON_1}.",
            "the template field must not be filled with the entity value"
        )
        XCTAssertEqual(restored.orphanTokens, ["{PERSON_1}"])
    }
}
