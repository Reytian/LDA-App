//
//  LLMExtractorUnlocatedValuesTests.swift
//  LDACoreTests
//
//  A value the extractor reports, that the document contains, and that
//  anchors nowhere is left in the document. It used to be only counted, so
//  the review window could say "AI detected 2 values it could not locate
//  exactly" and not which ones. LLMExtractor.locate now keeps each one with
//  its type, and these tests pin what it keeps.
//
//  The shape that reached a user in LDA 1.3: LDA V4 reports exact slices of
//  the text, and the locator's Latin word-boundary guard refuses a slice
//  whose edge runs into a letter or a digit (a footnote marker, a missing
//  space). That guard is how LDA V4 was evaluated, so anchoring itself must
//  not change: the same values stay unanchored and unredacted, and are now
//  named.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class LLMExtractorUnlocatedValuesTests: XCTestCase {

    /// Returns one canned completion for every prompt.
    private struct FixedCompleter: TextCompleter {
        let output: String

        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            output
        }
    }

    // MARK: - The values are kept, not only counted

    func testAnExactSliceRunIntoAFootnoteDigitIsNamedWithItsType() {
        // What LDA V4 hands the locator: exact slices of the text. The
        // footnote "1" touches the surname, so the guard refuses the edge.
        let text = "Signed by Jordan Lee1 for Northwind Traders on 3 May."
        let raw = [
            ExtractedEntity(value: "Jordan Lee", type: .person),
            ExtractedEntity(value: "Northwind Traders", type: .company)
        ]

        let result = LLMExtractor.locate(raw, in: text, incompleteSegmentCount: 0)

        XCTAssertEqual(
            result.unlocatedEntities,
            [ExtractedEntity(value: "Jordan Lee", type: .person)],
            "the value left in the document must be named with the type it was reported as"
        )
        XCTAssertEqual(result.unlocatableEntityCount, 1, "the count is the number of named values")
        XCTAssertFalse(result.fullyAnchored)
        XCTAssertEqual(
            result.spans.map(\.text), ["Northwind Traders"],
            "anchoring is unchanged: the refused value gets no span"
        )
    }

    func testValuesAreListedOncePerValueAndTypeInReportOrder() {
        let text = "Ana Ruizz met Jordan Lee2 and later jordan lee2 at Northwind Traders."
        let raw = [
            ExtractedEntity(value: "Ana Ruiz", type: .person),
            ExtractedEntity(value: "Jordan Lee", type: .person),
            ExtractedEntity(value: "jordan lee", type: .person),
            ExtractedEntity(value: "Northwind Traders", type: .company)
        ]

        let result = LLMExtractor.locate(raw, in: text, incompleteSegmentCount: 0)

        XCTAssertEqual(
            result.unlocatedEntities,
            [
                ExtractedEntity(value: "Ana Ruiz", type: .person),
                ExtractedEntity(value: "Jordan Lee", type: .person)
            ],
            "a repeat report of the same value is one entry, kept in the order first seen"
        )
        XCTAssertEqual(result.unlocatableEntityCount, 2)
    }

    func testAnInventedValueIsNotListedBecauseNothingInTheDocumentCanLeakIt() {
        let text = "This agreement is between Acme Corp and Jordan Lee3."
        let raw = [
            ExtractedEntity(value: "Jordan Lee", type: .person),
            ExtractedEntity(value: "Hallucinated Holdings", type: .company)
        ]

        let result = LLMExtractor.locate(raw, in: text, incompleteSegmentCount: 0)

        XCTAssertEqual(result.unlocatedEntities, [ExtractedEntity(value: "Jordan Lee", type: .person)])
        XCTAssertEqual(result.phantomEntityCount, 1, "the invented value is still counted as a phantom")
    }

    func testAListedValueIsTrimmedOfSurroundingWhitespace() {
        let text = "Signed by Jordan Lee4."
        let result = LLMExtractor.locate(
            [ExtractedEntity(value: "  Jordan Lee\n", type: .person)],
            in: text,
            incompleteSegmentCount: 0
        )
        XCTAssertEqual(result.unlocatedEntities, [ExtractedEntity(value: "Jordan Lee", type: .person)])
    }

    func testAValueAnchoredOnceAndGluedElsewhereIsListedAndGates() {
        // The leak this list did not cover at first: the first mention
        // anchors, so the value was "located", and the footnoted repeat was
        // dropped without a count. It is listed now, and it gates.
        let text = "Jordan Lee signed the agreement. Witnessed by Jordan Lee2 on the same day."
        let result = LLMExtractor.locate(
            [ExtractedEntity(value: "Jordan Lee", type: .person)],
            in: text,
            incompleteSegmentCount: 0
        )
        XCTAssertEqual(result.spans.map(\.start), [0], "the anchored mention is redacted as before")
        XCTAssertEqual(result.unlocatedEntities, [ExtractedEntity(value: "Jordan Lee", type: .person)])
        XCTAssertFalse(result.fullyAnchored, "a glued repeat is not a clean result")
    }

    func testAnAnchoredValueInsideALongerWordElsewhereIsNotListed() {
        // "Lee" inside "Leeds" is another word, not a mention: no false alarm.
        let text = "Mr Lee signed at the Leeds office."
        let result = LLMExtractor.locate(
            [ExtractedEntity(value: "Lee", type: .person)],
            in: text,
            incompleteSegmentCount: 0
        )
        XCTAssertEqual(result.spans.count, 1)
        XCTAssertTrue(result.unlocatedEntities.isEmpty)
        XCTAssertTrue(result.fullyAnchored)
    }

    func testAFullyAnchoredDocumentListsNothing() {
        let text = "This agreement is between Northwind Traders and Jordan Lee."
        let result = LLMExtractor.locate(
            [
                ExtractedEntity(value: "Jordan Lee", type: .person),
                ExtractedEntity(value: "Northwind Traders", type: .company)
            ],
            in: text,
            incompleteSegmentCount: 0
        )
        XCTAssertTrue(result.unlocatedEntities.isEmpty)
        XCTAssertTrue(result.fullyAnchored)
    }

    func testTheGgufPathNamesTheValueAsTheModelReportedIt() throws {
        // A GGUF model's value goes through the same locate step.
        let text = "This agreement is between Acme Corp and John Smith."
        let json = #"{"entities":[{"value":"JohnSmith","type":"PERSON"}],"redacted_text":""}"#
        let extractor = LLMExtractor(completer: FixedCompleter(output: json))

        let result = try extractor.extractDetailed(from: text)

        XCTAssertEqual(result.unlocatedEntities, [ExtractedEntity(value: "JohnSmith", type: .person)])
        XCTAssertEqual(result.unlocatableEntityCount, 1)
    }

    // MARK: - The count and the values cannot disagree

    func testTheCountIsTakenFromTheValuesWhenNotGiven() {
        let result = ExtractionResult(
            spans: [],
            incompleteSegmentCount: 0,
            unlocatedEntities: [
                ExtractedEntity(value: "Jordan Lee", type: .person),
                ExtractedEntity(value: "Northwind Traders", type: .company)
            ]
        )
        XCTAssertEqual(result.unlocatableEntityCount, 2)
        XCTAssertFalse(result.fullyAnchored, "named values gate exactly as counted ones do")
    }

    func testWithoutValuesThereIsNoCountToGateOn() {
        // The count is derived, so a result cannot carry a count the review
        // window has no values for (which would bring back the count-only
        // warning this list replaced).
        let result = ExtractionResult(spans: [], incompleteSegmentCount: 0)
        XCTAssertEqual(result.unlocatableEntityCount, 0)
        XCTAssertTrue(result.fullyAnchored)
    }

    // MARK: - One value, one row

    func testAValueWithAZeroWidthSpaceAtItsEdgeIsTheSameValue() {
        // A tagger slice can start at a U+200B, which the tokenizer does not
        // treat as space. Both reports trim to "Jordan Lee" and both are
        // refused at the "e|C" edge; they are one value, so one row and a
        // count of one.
        let text = "Signed by\u{200B}Jordan LeeCEO of Northwind Traders. Countersigned by Jordan LeeCEO."
        let result = LLMExtractor.locate(
            [
                ExtractedEntity(value: "\u{200B}Jordan Lee", type: .person),
                ExtractedEntity(value: "Jordan Lee", type: .person)
            ],
            in: text,
            incompleteSegmentCount: 0
        )
        XCTAssertEqual(result.unlocatedEntities, [ExtractedEntity(value: "Jordan Lee", type: .person)])
        XCTAssertEqual(result.unlocatableEntityCount, 1)
    }

    // MARK: - A pass that examined nothing

    func testEverySegmentUnansweredWithNothingBackIsAPassThatScannedNothing() {
        let result = LLMExtractor.locate(
            [], in: "Signed by Jordan Lee.",
            incompleteSegmentCount: 1, segmentCount: 1, unansweredSegmentCount: 1
        )
        XCTAssertTrue(result.scannedNothing)
    }

    func testSomeSegmentsAnsweredIsNotNothing() {
        let result = LLMExtractor.locate(
            [], in: "Signed by Jordan Lee.",
            incompleteSegmentCount: 1, segmentCount: 3, unansweredSegmentCount: 1
        )
        XCTAssertFalse(result.scannedNothing, "two of three segments were read")
    }

    func testATruncatedReplyIsAnAnswer() {
        // The model read the segment and was cut off at the token cap: the
        // pass ran and stopped short, which is partial, not "did not run".
        let result = LLMExtractor.locate(
            [], in: "Signed by Jordan Lee.",
            incompleteSegmentCount: 1, segmentCount: 1, unansweredSegmentCount: 0
        )
        XCTAssertFalse(result.scannedNothing)
    }

    func testAnUnansweredSegmentThatStillReturnedAValueIsNotNothing() {
        let result = LLMExtractor.locate(
            [ExtractedEntity(value: "Jordan Lee", type: .person)],
            in: "Signed by Jordan Lee.",
            incompleteSegmentCount: 1,
            segmentCount: 1,
            unansweredSegmentCount: 1
        )
        XCTAssertFalse(result.scannedNothing, "a salvaged value was anchored")
    }

    func testAnUnknownSegmentCountNeverReadsAsNothing() {
        // The built-in tagger reads every window and does not report a
        // count; neither does a hand-built result.
        let result = ExtractionResult(spans: [], incompleteSegmentCount: 1)
        XCTAssertFalse(result.scannedNothing)
    }

    func testTheGgufPathReportsItsSegmentCount() throws {
        struct Failing: TextCompleter {
            struct Down: Error {}
            func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String { throw Down() }
        }
        let extractor = LLMExtractor(completer: Failing())
        let result = try extractor.extractDetailed(from: "Signed by Jordan Lee for Northwind Traders.")
        XCTAssertGreaterThan(result.segmentCount, 0)
        XCTAssertEqual(result.incompleteSegmentCount, result.segmentCount)
        XCTAssertEqual(result.unansweredSegmentCount, result.segmentCount)
        XCTAssertTrue(result.scannedNothing, "every completion failed, so nothing was examined")
    }

    func testTheGgufPathCountsATruncatedReplyAsAnswered() throws {
        struct Truncating: TextCompleter {
            func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
                #"{"entities":[{"value":"Jor"#
            }
        }
        let extractor = LLMExtractor(completer: Truncating())
        let result = try extractor.extractDetailed(from: "Signed by Jordan Lee for Northwind Traders.")
        XCTAssertGreaterThan(result.incompleteSegmentCount, 0)
        XCTAssertEqual(result.unansweredSegmentCount, 0)
        XCTAssertFalse(result.scannedNothing, "the model read the text and was cut off")
    }
}
