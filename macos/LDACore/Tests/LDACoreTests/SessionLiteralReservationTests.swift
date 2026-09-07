//
//  SessionLiteralReservationTests.swift
//  LDACoreTests
//
//  Review finding 11 (2026-09-06): token collision reservation read only the
//  CURRENT document, while restore reads the whole session through one shared
//  mapping. A token minted for document 1 could equal a literal template token
//  in document 2, so the literal restored as the entity value. The evidence:
//  document 1 "Alice" became {PERSON_1}; document 2 "Fill in {PERSON_1}." was
//  left unchanged by anonymization and restored as "Fill in Alice.", with no
//  orphan, ambiguity, or seam warning and a passing release gate.
//
//  Two rules are pinned here. Literals are reserved across the ENTIRE session
//  before any token is minted, so a minted token never spells a literal of a
//  companion document. And a carried seed token that a document spells
//  literally is REFUSED with a seam issue: minting a fresh token for the
//  entity does not remove the seed's restore entry, so nothing short of the
//  warning stops the literal from restoring to the seed's value.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class SessionLiteralReservationTests: XCTestCase {

    private let stamp = "2026-09-06T00:00:00Z"

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

    /// Restore every document of a session with its final shared mapping.
    private func restoreAll(
        _ session: SessionTokenizeResult
    ) -> [RestoreResult] {
        session.documents.map { Restorer.restore(text: $0.tokenizedText, mapping: session.mapping) }
    }

    // MARK: - The review's evidence

    /// A token minted in one document must not spell a literal template token
    /// of another document of the same session.
    func testAMintedTokenNeverSpellsATemplateLiteralOfAnotherDocument() throws {
        let one = "Alice"
        let two = "Fill in {PERSON_1}."
        let session = SessionTokenizer.tokenize(
            documents: [
                SessionDocument(name: "one", text: one, spans: [span("Alice", in: one, type: .person)]),
                SessionDocument(name: "two", text: two, spans: [])
            ],
            sourceLabel: "Review",
            createdAtISO8601: stamp
        )

        XCTAssertEqual(session.documents[0].tokenizedText, "{PERSON_2}", "the literal of document two is reserved")
        XCTAssertEqual(session.documents[1].tokenizedText, two)
        XCTAssertTrue(session.seamIssues.isEmpty, "\(session.unresolvedSeams)")

        let restored = restoreAll(session)
        XCTAssertEqual(restored[0].text, one)
        XCTAssertEqual(restored[1].text, two, "the template literal must survive the round trip")
        XCTAssertEqual(restored[1].restoredCount, 0)
        XCTAssertEqual(restored[1].orphanTokens, ["{PERSON_1}"], "an unmapped literal is reported, never restored")
        XCTAssertNoThrow(
            try OutboundReleasePreflight.requireSafe(
                texts: session.documents.map(\.tokenizedText),
                mapping: session.mapping
            )
        )
    }

    /// The reservation does not depend on fold order: a literal in the FIRST
    /// document is still reserved when a later document mints.
    func testReservationHoldsWhenTheLiteralComesBeforeTheEntity() {
        let one = "Fill in {PERSON_1}."
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
        XCTAssertEqual(restoreAll(session)[0].text, one)
    }

    // MARK: - Seed collisions are refused, not silently restored

    /// A seed token spelled literally by a document cannot be reminted away:
    /// the seed entry stays in the union for the earlier matter's documents.
    /// The session must say so instead of returning an ordinary looking result.
    func testACarriedSeedTokenSpelledByADocumentIsReportedAsASeam() {
        let one = "Alice signs."
        let two = "Fill in {PERSON_1}."
        let session = SessionTokenizer.tokenize(
            documents: [
                SessionDocument(name: "one", text: one, spans: [span("Alice", in: one, type: .person)]),
                SessionDocument(name: "two", text: two, spans: [])
            ],
            sourceLabel: "Review",
            createdAtISO8601: stamp,
            seedMapping: seed([
                MappingEntry(token: "{PERSON_1}", value: "Alice", type: .person, surfaceText: "Alice", aliases: [])
            ])
        )

        // The reservation still keeps the ENTITY clear of the literal.
        XCTAssertEqual(session.documents[0].tokenizedText, "{PERSON_2} signs.")
        // The carried entry cannot be moved, so restore WOULD put Alice into
        // the template; the session must report exactly that site.
        XCTAssertEqual(
            session.seamIssues,
            [.unexpectedReplacement(documentIndex: 1, documentName: "two", matchedReplacement: "{PERSON_1}")]
        )
        XCTAssertEqual(restoreAll(session)[1].text, "Fill in Alice.", "the mis-restore the warning describes")
    }

    /// The direct single-document path refuses release the same way the
    /// pseudonym style already does for an unrepairable carried collision.
    func testDirectTokenizerRefusesReleaseWhenASeedTokenIsSpelledByTheDocument() throws {
        let text = "Use {PERSON_1} here. John Smith signs."
        let tokenized = Tokenizer.tokenize(
            text: text,
            spans: [span("John Smith", in: text, type: .person)],
            sourceFile: "doc2.txt",
            createdAtISO8601: stamp,
            seedMapping: seed([
                MappingEntry(token: "{PERSON_1}", value: "John Smith", type: .person, surfaceText: "John Smith", aliases: [])
            ])
        )

        XCTAssertEqual(
            tokenized.seamIssues,
            [.unexpectedReplacement(documentIndex: 0, documentName: "doc2.txt", matchedReplacement: "{PERSON_1}")]
        )
        XCTAssertThrowsError(try Tokenizer.requireSafeForRelease(tokenized)) { error in
            guard case TokenizationSafetyError.unresolvedSeams(let seams) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(seams, tokenized.unresolvedSeams)
        }
    }

    /// The other replacement the token style cannot mint away: a pseudonym
    /// carried from an earlier style. The token-style restore scans for it
    /// too, so a document that spells it naturally would have that text
    /// replaced by the seed's value, and no minted token moves the entry.
    func testACarriedPseudonymSpelledNaturallyByADocumentIsReportedAsASeam() {
        let text = "Person A signs. Bob witnesses."
        let carried = Mapping(
            entries: [
                "Person A": MappingEntry(
                    token: "Person A",
                    value: "Alice",
                    type: .person,
                    surfaceText: "Alice",
                    aliases: []
                )
            ],
            createdAtISO8601: stamp,
            sourceFile: "earlier matter",
            style: .pseudonym
        )
        let tokenized = Tokenizer.tokenize(
            text: text,
            spans: [span("Bob", in: text, type: .person)],
            sourceFile: "template.txt",
            createdAtISO8601: stamp,
            seedMapping: carried,
            style: .token
        )

        XCTAssertEqual(tokenized.tokenizedText, "Person A signs. {PERSON_1} witnesses.")
        XCTAssertEqual(
            tokenized.seamIssues,
            [.unexpectedReplacement(documentIndex: 0, documentName: "template.txt", matchedReplacement: "Person A")]
        )
        XCTAssertEqual(
            Restorer.restore(text: tokenized.tokenizedText, mapping: tokenized.mapping).text,
            "Alice signs. Bob witnesses.",
            "the mis-restore the warning describes"
        )
    }

    // MARK: - No false alarms

    /// An ordinary token-style session, with shared values and reuse across
    /// documents, reports nothing.
    func testACleanTokenStyleSessionReportsNoSeams() {
        let one = "Alice met Acme Corp."
        let two = "Acme Corp paid Alice and Bob."
        let session = SessionTokenizer.tokenize(
            documents: [
                SessionDocument(name: "one", text: one, spans: [
                    span("Alice", in: one, type: .person),
                    span("Acme Corp", in: one, type: .company)
                ]),
                SessionDocument(name: "two", text: two, spans: [
                    span("Acme Corp", in: two, type: .company),
                    span("Alice", in: two, type: .person),
                    span("Bob", in: two, type: .person)
                ])
            ],
            sourceLabel: "Review",
            createdAtISO8601: stamp
        )

        XCTAssertTrue(session.seamIssues.isEmpty, "\(session.unresolvedSeams)")
        XCTAssertEqual(session.documents[1].tokenizedText, "{COMPANY_1} paid {PERSON_1} and {PERSON_2}.")
        let restored = restoreAll(session)
        XCTAssertEqual(restored[0].text, one)
        XCTAssertEqual(restored[1].text, two)
    }

    /// Alias reuse restores the canonical value where the document spelled an
    /// alias. That is deliberate normalization, not a seam: the check compares
    /// substitution SITES, never values.
    func testAliasNormalizationIsNotReportedAsASeam() {
        let text = "A. Smith signs."
        let tokenized = Tokenizer.tokenize(
            text: text,
            spans: [span("A. Smith", in: text, type: .person)],
            sourceFile: "doc2.txt",
            createdAtISO8601: stamp,
            seedMapping: seed([
                MappingEntry(
                    token: "{PERSON_1}",
                    value: "Alice Smith",
                    type: .person,
                    surfaceText: "Alice Smith",
                    aliases: ["A. Smith"]
                )
            ])
        )

        XCTAssertEqual(tokenized.tokenizedText, "{PERSON_1} signs.")
        XCTAssertTrue(tokenized.seamIssues.isEmpty, "\(tokenized.unresolvedSeams)")
        XCTAssertEqual(
            Restorer.restore(text: tokenized.tokenizedText, mapping: tokenized.mapping).text,
            "Alice Smith signs."
        )
    }
}
