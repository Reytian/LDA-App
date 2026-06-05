//
//  TokenizerTests.swift
//  LDACoreTests
//
//  Tests for Tokenizer.tokenize. Covers the one-string-one-original invariant,
//  per-type counters, the token grammar contract, UTF-16 offset correctness for
//  multibyte and CJK text, overlap resolution, and the guarantee that no
//  original surface substring survives in the tokenized text for tokenized
//  spans.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class TokenizerTests: XCTestCase {
    // A fixed timestamp and source file so results are deterministic.
    private let timestamp = "2026-01-01T00:00:00Z"
    private let sourceFile = "contract.txt"

    // MARK: - Helpers

    /// Build a Span using UTF-16 offsets derived from the surface text's first
    /// occurrence in `text`, to keep the test fixtures readable.
    private func span(
        in text: String,
        surface: String,
        type: EntityType,
        source: DetectionSource = .llm,
        confidence: Double = 0.9,
        priority: Int = 0
    ) -> Span {
        let nsText = text as NSString
        let range = nsText.range(of: surface)
        precondition(range.location != NSNotFound, "surface not found in text")
        return Span(
            start: range.location,
            end: range.location + range.length,
            type: type,
            text: surface,
            source: source,
            confidence: confidence,
            priority: priority
        )
    }

    /// Returns true when the whole token is a single placeholder matching the
    /// contract grammar. The pattern is anchored so partial matches fail.
    private func matchesTokenGrammar(_ token: String) -> Bool {
        let anchored = "^" + TokenGrammar.placeholderPattern + "$"
        guard let regex = try? NSRegularExpression(pattern: anchored) else {
            return false
        }
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        return regex.firstMatch(in: token, range: range) != nil
    }

    // MARK: - One-string-one-original invariant

    func testTwoOccurrencesOfSameSurfaceShareOneToken() {
        let text = "John Smith met John Smith again."
        let nsText = text as NSString

        // Two distinct spans, same surface text "John Smith".
        let first = nsText.range(of: "John Smith")
        let secondSearchStart = first.location + first.length
        let secondRange = nsText.range(
            of: "John Smith",
            options: [],
            range: NSRange(location: secondSearchStart, length: nsText.length - secondSearchStart)
        )

        let spans = [
            Span(
                start: first.location, end: first.location + first.length,
                type: .person, text: "John Smith",
                source: .llm, confidence: 0.9, priority: 0
            ),
            Span(
                start: secondRange.location, end: secondRange.location + secondRange.length,
                type: .person, text: "John Smith",
                source: .llm, confidence: 0.9, priority: 0
            ),
        ]

        let result = Tokenizer.tokenize(
            text: text, spans: spans,
            sourceFile: sourceFile, createdAtISO8601: timestamp
        )

        // Exactly one mapping entry for the single distinct surface text.
        XCTAssertEqual(result.mapping.entries.count, 1)

        // Both occurrences became the same token.
        XCTAssertEqual(result.tokenizedText, "{PERSON_1} met {PERSON_1} again.")

        let entry = result.mapping.entries["{PERSON_1}"]
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.surfaceText, "John Smith")
        XCTAssertEqual(entry?.value, "John Smith")
        XCTAssertEqual(entry?.type, .person)
        XCTAssertEqual(entry?.aliases, [])
    }

    // MARK: - Distinct surfaces get distinct tokens

    func testTwoDifferentSurfacesGetDifferentTokens() {
        let text = "John Smith and Jane Doe signed."
        let spans = [
            span(in: text, surface: "John Smith", type: .person),
            span(in: text, surface: "Jane Doe", type: .person),
        ]

        let result = Tokenizer.tokenize(
            text: text, spans: spans,
            sourceFile: sourceFile, createdAtISO8601: timestamp
        )

        XCTAssertEqual(result.mapping.entries.count, 2)
        XCTAssertEqual(result.tokenizedText, "{PERSON_1} and {PERSON_2} signed.")

        XCTAssertEqual(result.mapping.entries["{PERSON_1}"]?.surfaceText, "John Smith")
        XCTAssertEqual(result.mapping.entries["{PERSON_2}"]?.surfaceText, "Jane Doe")
    }

    // MARK: - Per-type counters are independent

    func testPerTypeCountersAreIndependent() {
        let text = "John Smith at Acme Corp paid Jane Doe at Globex LLC."
        let spans = [
            span(in: text, surface: "John Smith", type: .person),
            span(in: text, surface: "Acme Corp", type: .company),
            span(in: text, surface: "Jane Doe", type: .person),
            span(in: text, surface: "Globex LLC", type: .company),
        ]

        let result = Tokenizer.tokenize(
            text: text, spans: spans,
            sourceFile: sourceFile, createdAtISO8601: timestamp
        )

        XCTAssertEqual(
            result.tokenizedText,
            "{PERSON_1} at {COMPANY_1} paid {PERSON_2} at {COMPANY_2}."
        )

        XCTAssertNotNil(result.mapping.entries["{PERSON_1}"])
        XCTAssertNotNil(result.mapping.entries["{PERSON_2}"])
        XCTAssertNotNil(result.mapping.entries["{COMPANY_1}"])
        XCTAssertNotNil(result.mapping.entries["{COMPANY_2}"])
    }

    // MARK: - Tokens match the grammar contract

    func testAllTokensMatchPlaceholderPattern() {
        let text = "John Smith owes USD 5,000 to Acme Corp on 2026-01-01."
        let spans = [
            span(in: text, surface: "John Smith", type: .person),
            span(in: text, surface: "USD 5,000", type: .amount),
            span(in: text, surface: "Acme Corp", type: .company),
            span(in: text, surface: "2026-01-01", type: .date),
        ]

        let result = Tokenizer.tokenize(
            text: text, spans: spans,
            sourceFile: sourceFile, createdAtISO8601: timestamp
        )

        XCTAssertFalse(result.mapping.entries.isEmpty)
        for token in result.mapping.entries.keys {
            XCTAssertTrue(
                matchesTokenGrammar(token),
                "token \(token) does not match the placeholder grammar"
            )
        }
    }

    // MARK: - Multibyte / CJK offsets

    func testCJKTextTokenizesAtCorrectOffsets() {
        // CJK characters are each one UTF-16 code unit, but the surrounding
        // ASCII plus the BMP characters exercise UTF-16 offset slicing.
        let text = "甲方为张三，乙方为李四。"
        let spans = [
            span(in: text, surface: "张三", type: .person),
            span(in: text, surface: "李四", type: .person),
        ]

        let result = Tokenizer.tokenize(
            text: text, spans: spans,
            sourceFile: sourceFile, createdAtISO8601: timestamp
        )

        XCTAssertEqual(result.tokenizedText, "甲方为{PERSON_1}，乙方为{PERSON_2}。")
        XCTAssertFalse(result.tokenizedText.contains("张三"))
        XCTAssertFalse(result.tokenizedText.contains("李四"))
    }

    func testSurrogatePairOffsetsAreHandled() {
        // An emoji outside the BMP occupies two UTF-16 code units. The name that
        // follows must still be sliced at the correct UTF-16 offset.
        let text = "Report 📄 by John Smith filed."
        let spans = [
            span(in: text, surface: "John Smith", type: .person),
        ]

        let result = Tokenizer.tokenize(
            text: text, spans: spans,
            sourceFile: sourceFile, createdAtISO8601: timestamp
        )

        XCTAssertEqual(result.tokenizedText, "Report 📄 by {PERSON_1} filed.")
        XCTAssertFalse(result.tokenizedText.contains("John Smith"))
    }

    // MARK: - No original surface substrings survive

    func testTokenizedTextContainsNoOriginalSurfaceSubstrings() {
        let text = "John Smith and Jane Doe both work at Acme Corp."
        let surfaces = ["John Smith", "Jane Doe", "Acme Corp"]
        let spans = [
            span(in: text, surface: "John Smith", type: .person),
            span(in: text, surface: "Jane Doe", type: .person),
            span(in: text, surface: "Acme Corp", type: .company),
        ]

        let result = Tokenizer.tokenize(
            text: text, spans: spans,
            sourceFile: sourceFile, createdAtISO8601: timestamp
        )

        for surface in surfaces {
            XCTAssertFalse(
                result.tokenizedText.contains(surface),
                "tokenized text still contains surface \(surface)"
            )
        }
    }

    // MARK: - Overlap resolution: longest then earliest

    func testRemainingOverlapsLongestWins() {
        // "John Smith Jr" overlaps "John Smith". The longer span must win and
        // the shorter overlapping span must be skipped.
        let text = "Contact John Smith Jr today."
        let longRange = (text as NSString).range(of: "John Smith Jr")
        let shortRange = (text as NSString).range(of: "John Smith")

        let spans = [
            Span(
                start: shortRange.location, end: shortRange.location + shortRange.length,
                type: .person, text: "John Smith",
                source: .llm, confidence: 0.8, priority: 0
            ),
            Span(
                start: longRange.location, end: longRange.location + longRange.length,
                type: .person, text: "John Smith Jr",
                source: .llm, confidence: 0.9, priority: 0
            ),
        ]

        let result = Tokenizer.tokenize(
            text: text, spans: spans,
            sourceFile: sourceFile, createdAtISO8601: timestamp
        )

        // Only the longest span is tokenized; the shorter overlap is dropped.
        XCTAssertEqual(result.mapping.entries.count, 1)
        XCTAssertEqual(result.tokenizedText, "Contact {PERSON_1} today.")
        XCTAssertEqual(result.mapping.entries["{PERSON_1}"]?.surfaceText, "John Smith Jr")
    }

    // MARK: - Type sanitization in tokens

    func testSanitizedTypeAppearsInToken() {
        // BANK_ACCOUNT sanitizes to BANKACCOUNT (underscores stripped).
        let text = "Account 12345678 is closed."
        let spans = [
            span(in: text, surface: "12345678", type: .bankAccount),
        ]

        let result = Tokenizer.tokenize(
            text: text, spans: spans,
            sourceFile: sourceFile, createdAtISO8601: timestamp
        )

        XCTAssertEqual(result.tokenizedText, "Account {BANKACCOUNT_1} is closed.")
        XCTAssertNotNil(result.mapping.entries["{BANKACCOUNT_1}"])
    }

    // MARK: - Mapping metadata passthrough

    func testMappingMetadataComesFromArguments() {
        let text = "John Smith."
        let spans = [span(in: text, surface: "John Smith", type: .person)]

        let result = Tokenizer.tokenize(
            text: text, spans: spans,
            sourceFile: "my-source.docx",
            createdAtISO8601: "2030-12-31T23:59:59Z"
        )

        XCTAssertEqual(result.mapping.sourceFile, "my-source.docx")
        XCTAssertEqual(result.mapping.createdAtISO8601, "2030-12-31T23:59:59Z")
    }

    // MARK: - Empty and degenerate inputs

    func testNoSpansReturnsOriginalTextAndEmptyMapping() {
        let text = "Nothing sensitive here."
        let result = Tokenizer.tokenize(
            text: text, spans: [],
            sourceFile: sourceFile, createdAtISO8601: timestamp
        )

        XCTAssertEqual(result.tokenizedText, text)
        XCTAssertTrue(result.mapping.entries.isEmpty)
    }

    func testOutOfBoundsAndInvertedSpansAreSkipped() {
        let text = "John Smith."
        let valid = span(in: text, surface: "John Smith", type: .person)
        let outOfBounds = Span(
            start: 100, end: 200, type: .person, text: "Ghost",
            source: .llm, confidence: 0.9, priority: 0
        )
        let inverted = Span(
            start: 5, end: 2, type: .person, text: "Bad",
            source: .llm, confidence: 0.9, priority: 0
        )

        let result = Tokenizer.tokenize(
            text: text, spans: [valid, outOfBounds, inverted],
            sourceFile: sourceFile, createdAtISO8601: timestamp
        )

        XCTAssertEqual(result.mapping.entries.count, 1)
        XCTAssertEqual(result.tokenizedText, "{PERSON_1}.")
    }

    func testSpanAtStartAndEndOfText() {
        let text = "John Smith"
        let spans = [span(in: text, surface: "John Smith", type: .person)]

        let result = Tokenizer.tokenize(
            text: text, spans: spans,
            sourceFile: sourceFile, createdAtISO8601: timestamp
        )

        XCTAssertEqual(result.tokenizedText, "{PERSON_1}")
    }

    // MARK: - Same surface, different spans across the document

    func testSameSurfaceMultipleSpansReuseTokenAndNumberingIsStable() {
        let text = "Acme Corp, Beta Inc, Acme Corp, Beta Inc."
        let nsText = text as NSString

        func allRanges(of needle: String) -> [NSRange] {
            var ranges: [NSRange] = []
            var searchStart = 0
            while searchStart < nsText.length {
                let found = nsText.range(
                    of: needle, options: [],
                    range: NSRange(location: searchStart, length: nsText.length - searchStart)
                )
                if found.location == NSNotFound { break }
                ranges.append(found)
                searchStart = found.location + found.length
            }
            return ranges
        }

        var spans: [Span] = []
        for range in allRanges(of: "Acme Corp") {
            spans.append(Span(
                start: range.location, end: range.location + range.length,
                type: .company, text: "Acme Corp",
                source: .llm, confidence: 0.9, priority: 0
            ))
        }
        for range in allRanges(of: "Beta Inc") {
            spans.append(Span(
                start: range.location, end: range.location + range.length,
                type: .company, text: "Beta Inc",
                source: .llm, confidence: 0.9, priority: 0
            ))
        }

        let result = Tokenizer.tokenize(
            text: text, spans: spans,
            sourceFile: sourceFile, createdAtISO8601: timestamp
        )

        // Two distinct surfaces, two tokens, numbered by first appearance.
        XCTAssertEqual(result.mapping.entries.count, 2)
        XCTAssertEqual(
            result.tokenizedText,
            "{COMPANY_1}, {COMPANY_2}, {COMPANY_1}, {COMPANY_2}."
        )
        XCTAssertEqual(result.mapping.entries["{COMPANY_1}"]?.surfaceText, "Acme Corp")
        XCTAssertEqual(result.mapping.entries["{COMPANY_2}"]?.surfaceText, "Beta Inc")
    }
}
