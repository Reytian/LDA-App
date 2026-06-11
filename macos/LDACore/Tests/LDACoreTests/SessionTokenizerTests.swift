//
//  SessionTokenizerTests.swift
//  LDACoreTests
//
//  Tests for multi-document session tokenization (R12): N documents tokenized
//  against ONE shared mapping, so the same value carries the same placeholder
//  in every document and a single mapping restores the whole set.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class SessionTokenizerTests: XCTestCase {

    private let stamp = "2026-06-11T00:00:00Z"

    private func span(
        _ text: String,
        in document: String,
        type: EntityType
    ) -> Span {
        let nsDocument = document as NSString
        let range = nsDocument.range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, "test span text must exist")
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

    func testSameValueSharesOneTokenAcrossDocuments() {
        let doc1 = "Acme Corp retains John Smith."
        let doc2 = "Acme Corp shall pay Maria Garcia."
        let documents = [
            SessionDocument(
                name: "engagement.txt",
                text: doc1,
                spans: [
                    span("Acme Corp", in: doc1, type: .company),
                    span("John Smith", in: doc1, type: .person)
                ]
            ),
            SessionDocument(
                name: "payment.txt",
                text: doc2,
                spans: [
                    span("Acme Corp", in: doc2, type: .company),
                    span("Maria Garcia", in: doc2, type: .person)
                ]
            )
        ]

        let result = SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: stamp
        )

        XCTAssertEqual(result.documents.count, 2)
        XCTAssertEqual(result.documents[0].tokenizedText, "{COMPANY_1} retains {PERSON_1}.")
        XCTAssertEqual(result.documents[1].tokenizedText, "{COMPANY_1} shall pay {PERSON_2}.")
        XCTAssertEqual(result.mapping.entries.count, 3)
    }

    func testOneMappingRestoresEveryDocument() {
        let doc1 = "Garcia Holdings and Acme Corp agree."
        let doc2 = "Acme Corp pays Garcia Holdings $1,000."
        let documents = [
            SessionDocument(
                name: "a.txt",
                text: doc1,
                spans: [
                    span("Garcia Holdings", in: doc1, type: .company),
                    span("Acme Corp", in: doc1, type: .company)
                ]
            ),
            SessionDocument(
                name: "b.txt",
                text: doc2,
                spans: [
                    span("Acme Corp", in: doc2, type: .company),
                    span("Garcia Holdings", in: doc2, type: .company),
                    span("$1,000", in: doc2, type: .amount)
                ]
            )
        ]

        let result = SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: stamp
        )

        for (index, original) in [doc1, doc2].enumerated() {
            let restored = Restorer.restore(
                text: result.documents[index].tokenizedText,
                mapping: result.mapping
            )
            XCTAssertEqual(restored.text, original)
            XCTAssertTrue(restored.orphanTokens.isEmpty)
        }
    }

    func testSameTypeEntitiesStayDistinctAcrossDocuments() {
        // The validation scenario: Acme Corp vs Acme Holdings must never share
        // a token, even when they appear in different documents.
        let doc1 = "Acme Corp is the Seller."
        let doc2 = "Acme Holdings is the Buyer."
        let documents = [
            SessionDocument(name: "a.txt", text: doc1, spans: [span("Acme Corp", in: doc1, type: .company)]),
            SessionDocument(name: "b.txt", text: doc2, spans: [span("Acme Holdings", in: doc2, type: .company)])
        ]

        let result = SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: stamp
        )

        XCTAssertEqual(result.documents[0].tokenizedText, "{COMPANY_1} is the Seller.")
        XCTAssertEqual(result.documents[1].tokenizedText, "{COMPANY_2} is the Buyer.")
        XCTAssertEqual(result.mapping.entries["{COMPANY_1}"]?.value, "Acme Corp")
        XCTAssertEqual(result.mapping.entries["{COMPANY_2}"]?.value, "Acme Holdings")
    }

    func testSeedMappingCarriesIntoSession() {
        let doc = "John Smith signs."
        let seedEntry = MappingEntry(
            token: "{PERSON_4}",
            value: "John Smith",
            type: .person,
            surfaceText: "John Smith",
            aliases: []
        )
        let seed = Mapping(
            entries: [seedEntry.token: seedEntry],
            createdAtISO8601: stamp,
            sourceFile: "client"
        )

        let result = SessionTokenizer.tokenize(
            documents: [
                SessionDocument(name: "a.txt", text: doc, spans: [span("John Smith", in: doc, type: .person)])
            ],
            sourceLabel: "session",
            createdAtISO8601: stamp,
            seedMapping: seed
        )

        XCTAssertEqual(result.documents[0].tokenizedText, "{PERSON_4} signs.")
    }

    func testEmptySessionYieldsEmptyResult() {
        let result = SessionTokenizer.tokenize(
            documents: [],
            sourceLabel: "session",
            createdAtISO8601: stamp
        )
        XCTAssertTrue(result.documents.isEmpty)
        XCTAssertTrue(result.mapping.entries.isEmpty)
        XCTAssertEqual(result.mapping.sourceFile, "session")
    }

    func testDocumentNamesArePreserved() {
        let doc = "Nothing sensitive."
        let result = SessionTokenizer.tokenize(
            documents: [SessionDocument(name: "memo.txt", text: doc, spans: [])],
            sourceLabel: "session",
            createdAtISO8601: stamp
        )
        XCTAssertEqual(result.documents[0].name, "memo.txt")
        XCTAssertEqual(result.documents[0].tokenizedText, doc)
    }
}
