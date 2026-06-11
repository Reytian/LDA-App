//
//  TokenizerSeedMappingTests.swift
//  LDACoreTests
//
//  Tests for seeded tokenization: a tokenize call that starts from an existing
//  Mapping (a prior document in the same session, or a client profile's stored
//  mapping) must reuse the seed's tokens for known surface values, continue the
//  per-type counters past the seed's maxima, and return the union mapping.
//
//  This is the engine half of multi-document sessions (R12) and client-profile
//  identity persistence (R10): the same value always maps to the same
//  placeholder across every document the seed mapping has seen.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class TokenizerSeedMappingTests: XCTestCase {

    private let stamp = "2026-06-11T00:00:00Z"

    /// Build a one-entry seed mapping.
    private func seed(_ entries: [MappingEntry]) -> Mapping {
        Mapping(
            entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.token, $0) }),
            createdAtISO8601: stamp,
            sourceFile: "doc1.txt"
        )
    }

    private func entry(
        token: String,
        value: String,
        type: EntityType,
        aliases: [String] = []
    ) -> MappingEntry {
        MappingEntry(
            token: token,
            value: value,
            type: type,
            surfaceText: value,
            aliases: aliases
        )
    }

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

    // MARK: - Reuse

    func testSeedReusesTokenForKnownValue() {
        let text = "John Smith met Acme Corp."
        let spans = [
            span("John Smith", in: text, type: .person),
            span("Acme Corp", in: text, type: .company)
        ]
        let seedMapping = seed([entry(token: "{PERSON_1}", value: "John Smith", type: .person)])

        let result = Tokenizer.tokenize(
            text: text,
            spans: spans,
            sourceFile: "doc2.txt",
            createdAtISO8601: stamp,
            seedMapping: seedMapping
        )

        XCTAssertEqual(result.tokenizedText, "{PERSON_1} met {COMPANY_1}.")
        XCTAssertEqual(result.mapping.entries["{PERSON_1}"]?.value, "John Smith")
        XCTAssertEqual(result.mapping.entries["{COMPANY_1}"]?.value, "Acme Corp")
    }

    func testSeedAliasReusesToken() {
        let text = "Payment goes to J. Smith."
        let spans = [span("J. Smith", in: text, type: .person)]
        let seedMapping = seed([
            entry(token: "{PERSON_1}", value: "John Smith", type: .person, aliases: ["J. Smith"])
        ])

        let result = Tokenizer.tokenize(
            text: text,
            spans: spans,
            sourceFile: "doc2.txt",
            createdAtISO8601: stamp,
            seedMapping: seedMapping
        )

        XCTAssertEqual(result.tokenizedText, "Payment goes to {PERSON_1}.")
        // The seed entry is untouched: it still restores to the canonical value.
        XCTAssertEqual(result.mapping.entries["{PERSON_1}"]?.value, "John Smith")
    }

    func testSeedReuseWinsEvenWhenNewTypeDiffers() {
        // A second document's detector may classify the same surface differently
        // (for example COMPANY instead of PERSON). Identity follows the seed.
        let text = "Garcia Holdings signed."
        let spans = [span("Garcia Holdings", in: text, type: .person)]
        let seedMapping = seed([
            entry(token: "{COMPANY_2}", value: "Garcia Holdings", type: .company)
        ])

        let result = Tokenizer.tokenize(
            text: text,
            spans: spans,
            sourceFile: "doc2.txt",
            createdAtISO8601: stamp,
            seedMapping: seedMapping
        )

        XCTAssertEqual(result.tokenizedText, "{COMPANY_2} signed.")
    }

    // MARK: - Counter continuation

    func testCountersContinuePastSeedMaximum() {
        let text = "Maria Garcia and Acme Holdings."
        let spans = [
            span("Maria Garcia", in: text, type: .person),
            span("Acme Holdings", in: text, type: .company)
        ]
        let seedMapping = seed([
            entry(token: "{PERSON_3}", value: "John Smith", type: .person),
            entry(token: "{COMPANY_1}", value: "Acme Corp", type: .company)
        ])

        let result = Tokenizer.tokenize(
            text: text,
            spans: spans,
            sourceFile: "doc2.txt",
            createdAtISO8601: stamp,
            seedMapping: seedMapping
        )

        // New person continues after {PERSON_3}; new company after {COMPANY_1}.
        XCTAssertEqual(result.tokenizedText, "{PERSON_4} and {COMPANY_2}.")
        XCTAssertEqual(result.mapping.entries.count, 4)
    }

    // MARK: - Union mapping

    func testResultMappingContainsSeedAndNewEntries() {
        let text = "Acme Corp hired Maria Garcia."
        let spans = [
            span("Acme Corp", in: text, type: .company),
            span("Maria Garcia", in: text, type: .person)
        ]
        let seedMapping = seed([
            entry(token: "{PERSON_1}", value: "John Smith", type: .person)
        ])

        let result = Tokenizer.tokenize(
            text: text,
            spans: spans,
            sourceFile: "doc2.txt",
            createdAtISO8601: stamp,
            seedMapping: seedMapping
        )

        // Seed entry survives even though "John Smith" never appears in doc2,
        // so one session mapping restores every document in the session.
        XCTAssertEqual(result.mapping.entries["{PERSON_1}"]?.value, "John Smith")
        XCTAssertNotNil(result.mapping.entries["{COMPANY_1}"])
        XCTAssertEqual(result.mapping.entries["{PERSON_2}"]?.value, "Maria Garcia")
    }

    // MARK: - Source-literal collision

    func testSeedTokenPresentAsSourceLiteralIsNotReused() {
        // The document itself contains the literal "{PERSON_1}" (for example a
        // template fill-in field). Reusing the seed token {PERSON_1} for a real
        // entity would make the literal and the minted token byte-identical, so
        // a fresh token must be minted for this document instead.
        let text = "Use {PERSON_1} here. John Smith signs."
        let spans = [span("John Smith", in: text, type: .person)]
        let seedMapping = seed([
            entry(token: "{PERSON_1}", value: "John Smith", type: .person)
        ])

        let result = Tokenizer.tokenize(
            text: text,
            spans: spans,
            sourceFile: "doc2.txt",
            createdAtISO8601: stamp,
            seedMapping: seedMapping
        )

        XCTAssertFalse(
            result.tokenizedText.contains("{PERSON_1} signs"),
            "seed token must not be emitted when it collides with a source literal"
        )
        XCTAssertTrue(result.tokenizedText.hasPrefix("Use {PERSON_1} here. "))
        // The fresh token restores to the same value, so restore stays correct.
        let minted = result.mapping.entries.values.first {
            $0.value == "John Smith" && $0.token != "{PERSON_1}"
        }
        XCTAssertNotNil(minted)
    }

    // MARK: - Backward compatibility

    func testNilSeedMatchesUnseededBehavior() {
        let text = "John Smith of Acme Corp emailed."
        let spans = [
            span("John Smith", in: text, type: .person),
            span("Acme Corp", in: text, type: .company)
        ]

        let unseeded = Tokenizer.tokenize(
            text: text,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: stamp
        )
        let nilSeeded = Tokenizer.tokenize(
            text: text,
            spans: spans,
            sourceFile: "doc.txt",
            createdAtISO8601: stamp,
            seedMapping: nil
        )

        XCTAssertEqual(unseeded.tokenizedText, nilSeeded.tokenizedText)
        XCTAssertEqual(unseeded.mapping, nilSeeded.mapping)
    }

    func testSeededTokenizationIsDeterministic() {
        // Seed entries arrive as an unordered dictionary; the seeded walk must
        // still be deterministic run over run.
        let text = "Acme Corp and Beta LLC and Gamma Inc."
        let spans = [
            span("Acme Corp", in: text, type: .company),
            span("Beta LLC", in: text, type: .company),
            span("Gamma Inc", in: text, type: .company)
        ]
        let seedMapping = seed([
            entry(token: "{COMPANY_7}", value: "Old Co", type: .company),
            entry(token: "{COMPANY_2}", value: "Older Co", type: .company)
        ])

        let first = Tokenizer.tokenize(
            text: text, spans: spans, sourceFile: "d.txt",
            createdAtISO8601: stamp, seedMapping: seedMapping
        )
        for _ in 0..<10 {
            let again = Tokenizer.tokenize(
                text: text, spans: spans, sourceFile: "d.txt",
                createdAtISO8601: stamp, seedMapping: seedMapping
            )
            XCTAssertEqual(again.tokenizedText, first.tokenizedText)
            XCTAssertEqual(again.mapping, first.mapping)
        }
        // Counters continue past the seed maximum of 7.
        XCTAssertTrue(first.tokenizedText.contains("{COMPANY_8}"))
    }
}
