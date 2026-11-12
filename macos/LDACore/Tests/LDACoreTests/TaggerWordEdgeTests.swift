//
//  TaggerWordEdgeTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, T1. The LDA V4 tagger sometimes ends a span inside a
//  word: "Mr. Mateo Ash" of "Mr. Mateo Ashdown" (inputs/perf/five.txt). The
//  fragment could not be anchored, so the whole document was refused, even
//  with --auto-protect, and the read-only `lda detect` said "Nothing was
//  written".
//
//  A Latin span edge that falls inside a word is now moved out to the word's
//  boundary, so the whole word is redacted and the value anchors; detect
//  words its refusal as the read-only command it is.
//
//  Every value is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDACLI

final class TaggerWordEdgeTests: XCTestCase {

    private static let text = "Signed by Mr. Mateo Ashdown on Monday. Mateo Ashdown agreed. 王小明签字。"

    private func covered(_ spans: [Span], _ range: NSRange) -> Bool {
        spans.contains { $0.start <= range.location && $0.end >= NSMaxRange(range) }
    }

    func testASpanThatEndsInsideAWordIsWidenedToTheWholeWord() {
        let ns = Self.text as NSString
        let fragment = ns.range(of: "Mr. Mateo Ash")
        let result = LDAV4Extractor.result(
            forTaggerSpans: [(fragment.location, NSMaxRange(fragment), "PERSON")], in: Self.text
        )
        XCTAssertTrue(covered(result.spans, ns.range(of: "Mr. Mateo Ashdown")), "\(result.spans.map(\.text))")
        XCTAssertTrue(result.unlocatedEntities.isEmpty, "\(result.unlocatedEntities.count) unlocated")
    }

    func testASpanThatStartsInsideAWordIsWidenedToTheWholeWord() {
        let ns = Self.text as NSString
        let fragment = ns.range(of: "teo Ashdown", options: .backwards)
        let result = LDAV4Extractor.result(
            forTaggerSpans: [(fragment.location, NSMaxRange(fragment), "PERSON")], in: Self.text
        )
        XCTAssertTrue(covered(result.spans, ns.range(of: "Mateo Ashdown", options: .backwards)), "\(result.spans.map(\.text))")
        XCTAssertTrue(result.unlocatedEntities.isEmpty)
    }

    // MARK: - A name glued to another word is not widened (independent review)

    /// The independent review of T1: widening took in the glued characters,
    /// so "signed byMarek Okafor2" gave {PERSON_1} = "byMarek Okafor2" beside
    /// {PERSON_2} = "Marek Okafor", one person under two placeholders, and an
    /// AI reply restored "byMarek Okafor2". A lowercase letter before a
    /// capital ("by|Marek") and a letter beside a digit ("Okafor|2") are word
    /// boundaries: the span is left as reported, the glued place stays a
    /// run-in (refused, or protected under --auto-protect with the same
    /// placeholder, as in 2.0).
    func testANameGluedToAnotherWordOrANumberIsNotWidened() {
        let text = "The letter was signed byMarek Okafor2 on 3 May. Marek Okafor confirmed it."
        let ns = text as NSString
        let glued = NSRange(location: ns.range(of: "byMarek").location + 2, length: "Marek Okafor".utf16.count)
        XCTAssertEqual(ns.substring(with: glued), "Marek Okafor")
        let result = LDAV4Extractor.result(forTaggerSpans: [(glued.location, NSMaxRange(glued), "PERSON")], in: text)
        XCTAssertFalse(result.spans.contains { $0.text.contains("by") || $0.text.contains("2") },
                       "nothing glued is taken into the value: \(result.spans.map(\.text))")
        XCTAssertTrue(result.spans.allSatisfy { $0.text == "Marek Okafor" }, "\(result.spans.map(\.text))")
    }

    func testAFootnoteNumberGluedToANameIsNotWidened() {
        let text = "Cross-examination of Marek Okafor2 followed, and Marek Okafor was released."
        let ns = text as NSString
        let glued = ns.range(of: "Marek Okafor")
        let result = LDAV4Extractor.result(forTaggerSpans: [(glued.location, NSMaxRange(glued), "PERSON")], in: text)
        XCTAssertFalse(result.spans.contains { $0.text.hasSuffix("2") }, "\(result.spans.map(\.text))")
    }

    /// The second independent review of T1 (probe t03_glue_right.txt): a
    /// name glued to the next word ("Marek Okaforand witnessed") or written
    /// in capitals against the previous one ("SIGNED BYMAREK OKAFOR") still
    /// widened into the glue, a lowercase or a capital pair being one word,
    /// so "Marek Okaforand" and "BYMAREK OKAFOR" became placeholders of their
    /// own. The characters alone cannot tell this from "Mateo Ash" cut inside
    /// "Ashdown"; the document can. An edge is not widened when the value as
    /// reported also stands on its own elsewhere in the document.
    func testANameGluedToTheNextWordIsNotWidened() {
        let text = "(Fictional) The letter was signed by Marek Okaforand witnessed by Jane Doe. Marek Okafor confirmed it."
        let ns = text as NSString
        let glued = ns.range(of: "Marek Okafor")
        let alone = ns.range(of: "Marek Okafor", options: .backwards)
        let result = LDAV4Extractor.result(forTaggerSpans: [
            (glued.location, NSMaxRange(glued), "PERSON"), (alone.location, NSMaxRange(alone), "PERSON"),
        ], in: text)
        XCTAssertFalse(result.spans.contains { $0.text.contains("Okaforand") }, "\(result.spans.map(\.text))")
        XCTAssertTrue(result.spans.allSatisfy { $0.text == "Marek Okafor" }, "\(result.spans.map(\.text))")
    }

    func testANameGluedInCapitalsIsNotWidened() {
        let text = "SIGNED BYMAREK OKAFOR ON 3 MAY 2026. Marek Okafor will attend."
        let ns = text as NSString
        let glued = ns.range(of: "MAREK OKAFOR")
        let alone = ns.range(of: "Marek Okafor")
        let result = LDAV4Extractor.result(forTaggerSpans: [
            (glued.location, NSMaxRange(glued), "PERSON"), (alone.location, NSMaxRange(alone), "PERSON"),
        ], in: text)
        XCTAssertFalse(result.spans.contains { $0.text.contains("BYMAREK") }, "\(result.spans.map(\.text))")
    }

    /// Left unwidened, the glued place was neither pinned nor a run-in the
    /// locator recognizes ("Okafor|and" and "BY|MAREK" look like ordinary
    /// words to it), and the value anchored at its other mentions, so the
    /// probe exported with the name in clear there and no refusal. The
    /// tagger's own place is now a run-in: its value is unlocated (refused
    /// by default) and the place is reported, so --auto-protect and a batch
    /// redact exactly it with the name's placeholder.
    static let gluedText = "(Fictional) The letter was signed by Marek Okaforand witnessed by Jane Doe. "
        + "Marek Okafor confirmed it.\nSIGNED BYMAREK OKAFOR ON 3 MAY 2026. Marek Okafor will attend."

    static func taggerSpans(in text: String) -> [(start: Int, end: Int, label: String)] {
        let ns = text as NSString
        var spans: [(start: Int, end: Int, label: String)] = []
        var from = 0
        while true {
            let found = ns.range(of: "Marek Okafor", options: [.caseInsensitive],
                                 range: NSRange(location: from, length: ns.length - from))
            guard found.location != NSNotFound else { break }
            spans.append((found.location, NSMaxRange(found), "PERSON"))
            from = NSMaxRange(found)
        }
        return spans
    }

    func testAGluedPlaceIsReportedAsARunInAndItsValueIsUnlocated() {
        let text = Self.gluedText
        let ns = text as NSString
        let result = LDAV4Extractor.result(forTaggerSpans: Self.taggerSpans(in: text), in: text)
        let right = ns.range(of: "Marek Okafor")
        let caps = ns.range(of: "MAREK OKAFOR")
        XCTAssertEqual(result.reportedRunIns.map { NSRange(location: $0.start, length: $0.end - $0.start) }, [right, caps])
        XCTAssertFalse(result.fullyAnchored, "the glued places are a leak until protected")
        XCTAssertEqual(Set(result.unlocatedEntities.map(\.value)), ["Marek Okafor", "MAREK OKAFOR"])
    }

    func testTheDefaultRefusesAndAutoProtectRedactsTheGluedPlaces() throws {
        let text = Self.gluedText
        let ns = text as NSString
        let tagger = FixedTagger(spans: Self.taggerSpans(in: text))
        let refusing = LDAService.Detector(extractor: tagger, unlocatedPolicy: .refuse)
        XCTAssertThrowsError(try refusing.detectText(text)) { error in
            guard case LDAServiceError.unanchoredEntities = error else {
                return XCTFail("expected a refusal, got \(error)")
            }
        }
        let protecting = LDAService.Detector(extractor: tagger, unlocatedPolicy: .protect)
        let spans = try protecting.detectText(text)
        for place in [ns.range(of: "Marek Okafor"), ns.range(of: "MAREK OKAFOR")] {
            XCTAssertTrue(spans.contains { $0.start == place.location && $0.end == NSMaxRange(place) },
                          "\(ns.substring(with: place)) at \(place.location): \(spans.map(\.text))")
        }
        XCTAssertFalse(spans.contains { $0.text.contains("Okaforand") || $0.text.contains("BYMAREK") },
                       "\(spans.map(\.text))")
    }

    func testAChineseSpanIsNotWidened() {
        let ns = Self.text as NSString
        let name = ns.range(of: "王小明")
        let result = LDAV4Extractor.result(forTaggerSpans: [(name.location, NSMaxRange(name), "PERSON")], in: Self.text)
        XCTAssertTrue(result.spans.contains { $0.start == name.location && $0.end == NSMaxRange(name) },
                      "\(result.spans.map(\.text))")
        XCTAssertFalse(result.spans.contains { $0.text.contains("签") })
    }

    func testTheReadOnlyDetectDoesNotSayItWroteNothing() {
        let error = LDAServiceError.unanchoredEntities(unlocatableEntityCount: 1)
        let detect = CLIRuntimeError(error, readOnly: true).description
        XCTAssertFalse(detect.contains("Nothing was written"), detect)
        XCTAssertTrue(detect.contains("1 detected value"), detect)
        XCTAssertTrue(CLIRuntimeError(error).description.contains("Nothing was written"),
                      "anonymize still says nothing was written")
    }
}

/// A tagger that reports fixed spans, through the LDA V4 extractor's own
/// handling of them.
private final class FixedTagger: EntityExtracting {
    let spans: [(start: Int, end: Int, label: String)]
    init(spans: [(start: Int, end: Int, label: String)]) { self.spans = spans }
    func extract(from text: String, onProgress: ((Int, Int) -> Void)?) throws -> [Span] {
        try extractDetailed(from: text, onProgress: onProgress).spans
    }
    func extractDetailed(from text: String, onProgress: ((Int, Int) -> Void)?) throws -> ExtractionResult {
        LDAV4Extractor.result(forTaggerSpans: spans, in: text)
    }
}
