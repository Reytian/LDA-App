//
//  EntityLocatorTests.swift
//  LDACoreTests
//
//  Tests for EntityLocator.spans(forValue:type:in:source:confidence:).
//
//  Offsets are UTF-16 code-unit offsets, NSRange-compatible: start is inclusive,
//  end is exclusive. Each emitted span must slice back to the searched value when
//  used as an NSRange against the source NSString.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class EntityLocatorTests: XCTestCase {

    // MARK: - Helpers

    /// Slices text by a span's UTF-16 range using NSString, mirroring how
    /// downstream consumers treat Span offsets.
    private func slice(_ text: String, _ span: Span) -> String {
        let ns = text as NSString
        let range = NSRange(location: span.start, length: span.end - span.start)
        return ns.substring(with: range)
    }

    // MARK: - Single occurrence

    func testSingleOccurrenceCorrectUTF16Offsets() {
        let text = "Contact Alice Wong about the deal."
        let value = "Alice Wong"

        let spans = EntityLocator.spans(forValue: value, type: .person, in: text)

        XCTAssertEqual(spans.count, 1)
        let span = try? XCTUnwrap(spans.first)
        XCTAssertNotNil(span)
        guard let span else { return }

        XCTAssertEqual(span.start, 8)
        XCTAssertEqual(span.end, 18)
        XCTAssertEqual(span.type, .person)
        XCTAssertEqual(span.text, value)
        XCTAssertEqual(span.source, .llm)
        XCTAssertEqual(span.confidence, 0.7, accuracy: 1e-9)
        XCTAssertEqual(slice(text, span), value)
    }

    func testPriorityIsLLMFuzzyAndBelowDeterministic() {
        let text = "Alice"
        let spans = EntityLocator.spans(forValue: "Alice", type: .person, in: text)

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.priority, EntityLocator.llmPriority)
        XCTAssertEqual(spans.first?.priority, 30)
        // Deterministic structured PII carries a high priority such as 100, so
        // the LLM priority must sit strictly below it.
        XCTAssertLessThan(spans.first?.priority ?? .max, 100)
    }

    func testCustomSourceAndConfidenceAreStamped() {
        let text = "Alice and Alice"
        let spans = EntityLocator.spans(
            forValue: "Alice",
            type: .person,
            in: text,
            source: .manual,
            confidence: 0.42
        )

        XCTAssertEqual(spans.count, 2)
        for span in spans {
            XCTAssertEqual(span.source, .manual)
            XCTAssertEqual(span.confidence, 0.42, accuracy: 1e-9)
        }
    }

    // MARK: - Multiple occurrences

    func testMultipleOccurrencesCorrectOffsetsSliceBack() {
        let text = "Acme, then Acme again, and Acme."
        let value = "Acme"

        let spans = EntityLocator.spans(forValue: value, type: .company, in: text)

        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans.map { $0.start }, [0, 11, 27])
        for span in spans {
            XCTAssertEqual(span.text, value)
            XCTAssertEqual(span.type, .company)
            XCTAssertEqual(slice(text, span), value)
        }
    }

    func testOccurrencesAreInDocumentOrder() {
        let text = "z X y X w X"
        let spans = EntityLocator.spans(forValue: "X", type: .unknown, in: text)

        XCTAssertEqual(spans.count, 3)
        let starts = spans.map { $0.start }
        XCTAssertEqual(starts, starts.sorted())
    }

    // MARK: - CJK offsets

    func testCJKValueOffsetsCorrect() {
        // BMP CJK characters are one UTF-16 code unit each.
        let text = "客户张伟与张伟签署"
        let value = "张伟"

        let spans = EntityLocator.spans(forValue: value, type: .person, in: text)

        XCTAssertEqual(spans.count, 2)
        // "客户" is 2 units, so the first "张伟" starts at offset 2.
        XCTAssertEqual(spans[0].start, 2)
        XCTAssertEqual(spans[0].end, 4)
        // Then "与" at 4, second "张伟" at 5.
        XCTAssertEqual(spans[1].start, 5)
        XCTAssertEqual(spans[1].end, 7)
        for span in spans {
            XCTAssertEqual(slice(text, span), value)
        }
    }

    func testValueWithEmojiUsesUTF16Offsets() {
        // An emoji outside the BMP occupies two UTF-16 code units, shifting later
        // offsets by two rather than one.
        let text = "Hi 🙂 Bob and Bob"
        let value = "Bob"

        let spans = EntityLocator.spans(forValue: value, type: .person, in: text)

        XCTAssertEqual(spans.count, 2)
        for span in spans {
            XCTAssertEqual(slice(text, span), value)
        }
        // "Hi " is 3 units, the emoji is 2 units, " " is 1 unit: first "Bob" at 6.
        XCTAssertEqual(spans[0].start, 6)
        XCTAssertEqual(spans[0].end, 9)
    }

    // MARK: - Absent value

    func testValueAbsentReturnsEmpty() {
        let text = "Nothing to anonymize here."
        let spans = EntityLocator.spans(forValue: "Charlie", type: .person, in: text)
        XCTAssertTrue(spans.isEmpty)
    }

    func testEmptyTextReturnsEmpty() {
        let spans = EntityLocator.spans(forValue: "Alice", type: .person, in: "")
        XCTAssertTrue(spans.isEmpty)
    }

    func testValueLongerThanTextReturnsEmpty() {
        let spans = EntityLocator.spans(
            forValue: "A very long needle",
            type: .person,
            in: "short"
        )
        XCTAssertTrue(spans.isEmpty)
    }

    // MARK: - Empty and whitespace value

    func testEmptyValueReturnsEmpty() {
        let spans = EntityLocator.spans(forValue: "", type: .person, in: "Alice")
        XCTAssertTrue(spans.isEmpty)
    }

    func testWhitespaceOnlyValueReturnsEmpty() {
        let spans = EntityLocator.spans(forValue: "   \n\t ", type: .person, in: "a b c")
        XCTAssertTrue(spans.isEmpty)
    }

    func testSurroundingWhitespaceIsTrimmedBeforeSearching() {
        let text = "Pay Alice now."
        let spans = EntityLocator.spans(
            forValue: "  Alice  ",
            type: .person,
            in: text
        )

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.text, "Alice")
        XCTAssertEqual(spans.first?.start, 4)
        XCTAssertEqual(spans.first?.end, 9)
        XCTAssertEqual(slice(text, spans.first!), "Alice")
    }

    // MARK: - Non-overlapping advancement

    func testOverlappingPatternEmitsNonOverlappingMatches() {
        // "aaaa" contains "aa" at offsets 0, 1, 2 if overlaps were allowed. The
        // locator must advance past each match, yielding non-overlapping spans at
        // offsets 0 and 2 only.
        let text = "aaaa"
        let spans = EntityLocator.spans(forValue: "aa", type: .unknown, in: text)

        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans.map { $0.start }, [0, 2])
        XCTAssertEqual(spans.map { $0.end }, [2, 4])

        // Verify no pair of emitted spans overlaps.
        for i in spans.indices {
            for j in spans.indices where j > i {
                let a = spans[i]
                let b = spans[j]
                let overlaps = a.start < b.end && a.end > b.start
                XCTAssertFalse(overlaps, "spans \(i) and \(j) must not overlap")
            }
        }
    }

    func testRepeatedSingleCharacterAdvancesPastEachMatch() {
        let text = "xxx"
        let spans = EntityLocator.spans(forValue: "x", type: .unknown, in: text)

        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans.map { $0.start }, [0, 1, 2])
        XCTAssertEqual(spans.map { $0.end }, [1, 2, 3])
    }

    // MARK: - NFC/NFD byte identity (offset-unicode-1)

    /// NSString.range does canonical (normalization-insensitive) matching: an NFC
    /// needle matches an NFD occurrence and the returned NSRange carries the
    /// HAYSTACK length, not the needle length. The emitted span's text must be the
    /// actual matched substring (the source's NFD bytes), not the needle, so the
    /// [start, end) UTF-16 bytes agree with span.text byte-for-byte. Byte-level
    /// (utf16) assertions are required here, because String== is canonical and
    /// would mask the divergence.
    func testSpanTextIsMatchedSubstringNotNeedleForNFDSource() {
        // Source 'é' is decomposed: base 'e' (U+0065) + combining acute (U+0301).
        let text = "Owner Rene\u{0301} Martin, attorney."
        // The model reports the value in precomposed NFC form.
        let needle = "Ren\u{00E9}"

        let spans = EntityLocator.spans(forValue: needle, type: .person, in: text)
        XCTAssertEqual(spans.count, 1)
        guard let span = spans.first else { return }

        let ns = text as NSString
        let matched = ns.substring(with: NSRange(location: span.start, length: span.end - span.start))

        // span.text must equal the matched source slice at the byte (UTF-16) level.
        XCTAssertEqual(
            Array(span.text.utf16),
            Array(matched.utf16),
            "span.text must carry the matched source bytes, not the NFC needle"
        )
        // Concretely, the matched slice is the NFD form of "Rene" (5 UTF-16
        // units: 'R','e','n','e' plus combining acute), not the NFC needle
        // "Ren\u{00E9}" (4 UTF-16 units).
        XCTAssertEqual(Array(span.text.utf16), Array("Rene\u{0301}".utf16))
        XCTAssertEqual((span.text as NSString).length, 5)
    }

    /// End-to-end: tokenizing then restoring an NFD source with an NFC needle must
    /// reproduce the original byte-for-byte (UTF-16 identical), not merely
    /// canonically equal.
    func testNFDSourceRoundTripsByteIdenticalThroughTokenizer() {
        let text = "Owner Rene\u{0301} Martin, attorney."
        let needle = "Ren\u{00E9}"

        let spans = EntityLocator.spans(forValue: needle, type: .person, in: text)
        let tok = Tokenizer.tokenize(
            text: text,
            spans: spans,
            sourceFile: "test.txt",
            createdAtISO8601: "2026-01-01T00:00:00Z"
        )
        let restored = Restorer.restore(text: tok.tokenizedText, mapping: tok.mapping)

        XCTAssertEqual(
            Array(restored.text.utf16),
            Array(text.utf16),
            "restore must be byte-identical (UTF-16), not just canonically equal"
        )
    }

    /// The ASCII path must be unaffected by capturing the matched substring.
    func testASCIIMatchedSubstringEqualsNeedle() {
        let text = "Pay Alice now."
        let spans = EntityLocator.spans(forValue: "Alice", type: .person, in: text)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(Array(spans.first!.text.utf16), Array("Alice".utf16))
    }

    // MARK: - Case-insensitive location (casing-mismatch leak)

    /// The model may report an entity in a different casing than the document
    /// ("ACME CORP" vs "Acme Corp"). The locator must still find the occurrence;
    /// a zero-span result here means the value survives anonymization (PII leak).
    func testCaseMismatchedValueLocatesDocumentSurface() {
        let text = "Contract with Acme Corp today."
        let spans = EntityLocator.spans(forValue: "ACME CORP", type: .company, in: text)

        XCTAssertEqual(spans.count, 1)
        guard let span = spans.first else { return }
        // span.text must carry the DOCUMENT's surface form, not the needle's
        // casing, so tokenize/restore stays byte-identical.
        XCTAssertEqual(Array(span.text.utf16), Array("Acme Corp".utf16))
        XCTAssertEqual(slice(text, span), "Acme Corp")
    }

    /// A document that mixes casings of the same name must have EVERY occurrence
    /// located in one pass, each span stamped with its own surface form.
    func testMixedCasingOccurrencesEachStampedWithOwnSurface() {
        let text = "Acme Corp signed. Later ACME CORP countersigned."
        let spans = EntityLocator.spans(forValue: "acme corp", type: .company, in: text)

        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans.map { $0.text }, ["Acme Corp", "ACME CORP"])
        for span in spans {
            XCTAssertEqual(slice(text, span), span.text)
        }
    }

    /// Case-insensitive matches must still round-trip byte-identically through
    /// tokenize + restore, because each span carries its matched surface bytes.
    func testCaseInsensitiveMatchRoundTripsByteIdentical() {
        let text = "Acme Corp signed. Later ACME CORP countersigned."
        let spans = EntityLocator.spans(forValue: "ACME CORP", type: .company, in: text)
        XCTAssertEqual(spans.count, 2)

        let tok = Tokenizer.tokenize(
            text: text,
            spans: spans,
            sourceFile: "test.txt",
            createdAtISO8601: "2026-01-01T00:00:00Z"
        )
        // The tokenized text must not contain either casing of the value.
        XCTAssertFalse(tok.tokenizedText.lowercased().contains("acme corp"))

        let restored = Restorer.restore(text: tok.tokenizedText, mapping: tok.mapping)
        XCTAssertEqual(
            Array(restored.text.utf16),
            Array(text.utf16),
            "restore must be byte-identical regardless of needle casing"
        )
    }
}
