//
//  EntityLocatorCanonicalVariantTests.swift
//  LDACoreTests
//
//  R5 (2026-09-07): the residual half of review finding 13. NSString's exact
//  search is canonically equivalent, so an NFC needle finds an NFD occurrence.
//  ICU's regex engine is not, so the whitespace-variant pattern was blind to a
//  name that is BOTH decomposed and wrapped.
//
//  The evidence: for "René Martin signed. Contact Rene\u{301}\nMartin for
//  details." the model correctly returns "René Martin". Only the first
//  occurrence anchored, coverage and anchoring both reported complete because
//  the no-anchor safeguard fires only on ZERO hits, and the facade exported the
//  second full name in decomposed form across the line break.
//
//  The repaired contract: every literal piece of EntityVariantPattern is built
//  as an alternation of its canonical spellings, per grapheme cluster, so a
//  decomposed or precomposed wrapped repeat anchors either way and a source
//  that mixes the two forms inside one name still anchors. The span still
//  carries the matched slice, the source's own bytes, so restore stays
//  byte-identical. The branches of each alternation begin with different code
//  units and every gap stays bounded, so nothing here can backtrack.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class EntityLocatorCanonicalVariantTests: XCTestCase {

    private struct FixedCompleter: TextCompleter {
        let output: String
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return output
        }
    }

    /// The reviewer's reproduction text, verbatim: the first mention is
    /// precomposed, the wrapped repeat is decomposed.
    private static let reviewText = "René Martin signed. Contact Rene\u{301}\nMartin for details."

    /// What the model returns for that text: the precomposed name.
    private static let composedNeedle = "René Martin"

    private static let martinJSON =
        #"{"entities":[{"value":"René Martin","type":"PERSON"}],"redacted_text":""}"#

    override func tearDown() {
        LDAService.makeExtractorForTesting = nil
        super.tearDown()
    }

    // MARK: - Locator

    func testDecomposedWrappedRepeatIsAnchoredAlongsideThePrecomposedExactHit() {
        let spans = EntityLocator.spans(
            forValue: Self.composedNeedle,
            type: .person,
            in: Self.reviewText
        )

        XCTAssertEqual(spans.count, 2, "the decomposed wrapped repeat must anchor too")
        guard spans.count == 2 else { return }
        XCTAssertEqual(spans[0].text, "René Martin")
        XCTAssertEqual(
            spans[1].text.unicodeScalars.map(\.value),
            "Rene\u{301}\nMartin".unicodeScalars.map(\.value),
            "the span must carry the source's own bytes, decomposed and wrapped"
        )
        let wrapped = (Self.reviewText as NSString).range(of: "Rene\u{301}\nMartin")
        XCTAssertEqual(spans[1].start, wrapped.location)
        XCTAssertEqual(spans[1].end, wrapped.location + wrapped.length)
    }

    /// The needle itself may arrive decomposed: the model may answer in NFD
    /// for a source that is precomposed.
    func testDecomposedNeedleAnchorsAPrecomposedWrappedSource() {
        let text = "René Martin signed. Contact René\nMartin for details."
        let spans = EntityLocator.spans(
            forValue: "Rene\u{301} Martin",
            type: .person,
            in: text
        )

        XCTAssertEqual(spans.count, 2, "a decomposed needle must find the precomposed wrap")
        XCTAssertEqual(spans.map(\.text), ["René Martin", "René\nMartin"])
    }

    /// A wrapped occurrence that mixes the two forms INSIDE one word still
    /// anchors, because the alternation is built per grapheme cluster rather
    /// than per whole piece. Here the first accent is decomposed and the
    /// second is precomposed, which no whole-piece NFC-or-NFD alternative
    /// would match.
    func testMixedCanonicalFormsInsideOneWordAnchorWhenWrapped() {
        let text = "Améliè Zoé signed. Contact Ame\u{301}liè\nZoé for details."

        let spans = EntityLocator.spans(forValue: "Améliè Zoé", type: .person, in: text)

        XCTAssertEqual(spans.count, 2, "got \(spans.map(\.text))")
        guard spans.count == 2 else { return }
        XCTAssertEqual(
            spans[1].text.unicodeScalars.map(\.value),
            "Ame\u{301}liè\nZoé".unicodeScalars.map(\.value)
        )
    }

    func testAnAccentedNameWithNoVariantStillAnchorsOnce() {
        let text = "Only René Martin here."

        let spans = EntityLocator.spans(forValue: "Rene\u{301} Martin", type: .person, in: text)

        XCTAssertEqual(spans.map(\.text), ["René Martin"])
    }

    func testTheBoundedGapStillAppliesToCanonicalVariants() {
        let text = "Rene\u{301}" + String(repeating: " ", count: 200) + "Martin"

        XCTAssertTrue(
            EntityLocator.spans(forValue: Self.composedNeedle, type: .person, in: text).isEmpty,
            "a canonically tolerant piece must not widen the whitespace bound"
        )
    }

    func testCanonicalVariantSearchStaysFastOnLongWhitespaceRuns() {
        // Perf guard in the style of RestorerSuspectTests: the alternation
        // branches start with different code units and every gap is bounded,
        // so a document of near misses must not backtrack.
        let block = "Rene\u{301}" + String(repeating: " \n", count: 40) + "Renata "
        let text = String(repeating: block, count: 2_000) + "Martin"

        let started = CFAbsoluteTimeGetCurrent()
        _ = EntityLocator.spans(forValue: Self.composedNeedle, type: .person, in: text)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertLessThan(elapsed, 1.5, "the canonical alternation must stay bounded, took \(elapsed)s")
    }

    // MARK: - Pattern

    func testThePatternCarriesBothCanonicalSpellingsOfAnAccentedPiece() throws {
        let pattern = try XCTUnwrap(EntityVariantPattern.pattern(for: Self.composedNeedle))

        // Compared as SCALARS on purpose: String.contains folds canonical
        // equivalence, so "René".contains("e\u{301}") is true and an
        // equivalence assertion written with it would pass vacuously.
        let scalars = pattern.unicodeScalars.map(\.value)
        XCTAssertTrue(scalars.contains(0x00E9), "the precomposed spelling must be an alternative: \(pattern)")
        XCTAssertTrue(scalars.contains(0x0301), "the decomposed spelling must be an alternative: \(pattern)")
        XCTAssertTrue(pattern.contains("(?:"), "the accented piece must be an alternation: \(pattern)")
    }

    func testAnAsciiOnlyPieceIsNotWrappedInAnAlternation() throws {
        let pattern = try XCTUnwrap(EntityVariantPattern.pattern(for: "Alice Smith"))

        XCTAssertFalse(pattern.contains("(?:A"), "an ASCII piece needs no alternation: \(pattern)")
        XCTAssertTrue(pattern.hasPrefix("Alice"))
    }

    // MARK: - Extractor

    func testExtractorAnchorsTheDecomposedWrapAndStaysFullyAnchored() throws {
        let extractor = LLMExtractor(completer: FixedCompleter(output: Self.martinJSON))

        let result = try extractor.extractDetailed(from: Self.reviewText)

        XCTAssertEqual(result.spans.count, 2, "got \(result.spans.map(\.text))")
        XCTAssertTrue(result.fullyAnchored)
        XCTAssertEqual(result.unlocatableEntityCount, 0)
        XCTAssertEqual(result.phantomEntityCount, 0)
    }

    // MARK: - End to end: the reviewer's evidence

    func testAnonymizeLeavesNoHalfOfTheDecomposedWrappedNameVisible() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntityLocatorCanonicalVariantTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("source.txt")
        try Data(Self.reviewText.utf8).write(to: input)
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: FixedCompleter(output: Self.martinJSON))
        }
        let protection = MappingProtection.passphrase("synthetic")

        let result = try LDAService.anonymize(
            input: input,
            outputDir: dir.appendingPathComponent("out", isDirectory: true),
            protection: protection,
            createdAtISO8601: "2026-09-07T00:00:00Z",
            llmModelPath: "/nonexistent.gguf"
        )

        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertFalse(redacted.contains("Martin"), "the surname is still visible: \(redacted)")
        XCTAssertFalse(redacted.contains("René"), "the given name is still visible: \(redacted)")
        XCTAssertFalse(
            redacted.unicodeScalars.contains(where: { $0.value == 0x301 }),
            "a decomposed spelling of the given name is still visible: \(redacted)"
        )

        let restoredURL = dir.appendingPathComponent("restored.txt")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: protection,
            output: restoredURL
        )
        XCTAssertEqual(
            try String(contentsOf: report.outputURL, encoding: .utf8).unicodeScalars.map(\.value),
            Self.reviewText.unicodeScalars.map(\.value),
            "the decomposed wrapped slice must restore byte-identically"
        )
    }
}
