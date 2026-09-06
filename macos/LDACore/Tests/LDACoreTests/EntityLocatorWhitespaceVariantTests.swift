//
//  EntityLocatorWhitespaceVariantTests.swift
//  LDACoreTests
//
//  One exact occurrence of a name must not hide its whitespace variants. The
//  model reports "Alice Smith" once; the document spells it once exactly and
//  once broken across a line ("Alice\nSmith"). Before these tests the literal
//  locator anchored only the exact hit, the unanchored-value safeguard never
//  ran (it fired only on ZERO exact hits), and the result was called fully
//  anchored while the wrapped occurrence survived into the output.
//
//  The repaired contract extends the existing anchoring mechanism (the literal
//  locator plus CJKSpacing's script-boundary rule) instead of adding a second
//  one: after the exact pass, every whitespace run inside the reported value
//  is matched against a bounded run of source whitespace (spaces, tabs, line
//  and page breaks, no-break and ideographic spaces), and at a CJK-to-ASCII
//  script boundary the run may be empty, which subsumes the old tighten-and-
//  retry fallback. Each span still carries the source's own slice, so restore
//  stays byte-identical, and SpanSplitter keeps splitting a span that crosses
//  a line or page break into per-part tokens downstream.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class EntityLocatorWhitespaceVariantTests: XCTestCase {

    private struct FixedCompleter: TextCompleter {
        let output: String
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return output
        }
    }

    /// The review's reproduction text, verbatim.
    private static let reviewText = "Alice Smith signed. Contact Alice\nSmith for details."

    private static let aliceJSON = #"{"entities":[{"value":"Alice Smith","type":"PERSON"}],"redacted_text":""}"#

    private func utf16Range(of needle: String, in text: String) -> NSRange {
        return (text as NSString).range(of: needle)
    }

    override func tearDown() {
        LDAService.makeExtractorForTesting = nil
        super.tearDown()
    }

    // MARK: - Locator

    func testWrappedOccurrenceIsAnchoredAlongsideTheExactOne() {
        let spans = EntityLocator.spans(forValue: "Alice Smith", type: .person, in: Self.reviewText)

        XCTAssertEqual(spans.count, 2, "one exact hit must not hide the line-wrapped occurrence")
        XCTAssertEqual(
            spans.map(\.text), ["Alice Smith", "Alice\nSmith"],
            "each span carries the source's own slice, so restore stays byte-identical"
        )
        guard spans.count == 2 else { return }
        let wrapped = utf16Range(of: "Alice\nSmith", in: Self.reviewText)
        XCTAssertEqual(spans[1].start, wrapped.location)
        XCTAssertEqual(spans[1].end, wrapped.location + wrapped.length)
    }

    func testRunsOfSpacesTabsBreaksAndNoBreakSpacesAreWhitespaceVariants() {
        let gaps = ["  ", "\t", "\u{00A0}", "\u{3000}", " \n ", "\r\n", "\n\u{000C}\n"]
        for gap in gaps {
            let text = "Signed by Alice\(gap)Smith today."
            let spans = EntityLocator.spans(forValue: "Alice Smith", type: .person, in: text)
            let label = gap.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " ")
            XCTAssertEqual(spans.count, 1, "gap [\(label)] must anchor")
            XCTAssertEqual(spans.first?.text, "Alice\(gap)Smith", "gap [\(label)] must keep the source slice")
        }
    }

    func testMissingWhitespaceInLatinTextIsNotAVariant() {
        // A space inside Latin text is real (CJKSpacing's rule): "AliceSmith" is
        // a different surface and must not be claimed by "Alice Smith".
        let spans = EntityLocator.spans(forValue: "Alice Smith", type: .person, in: "Login: AliceSmith")

        XCTAssertTrue(spans.isEmpty)
    }

    func testVariantMatchesRespectLatinWordBoundaries() {
        XCTAssertTrue(
            EntityLocator.spans(forValue: "Alice Smith", type: .person, in: "Alice\nSmithson signed.").isEmpty
        )
        XCTAssertTrue(
            EntityLocator.spans(forValue: "Alice Smith", type: .person, in: "Malice\nSmith signed.").isEmpty
        )
    }

    func testWhitespaceVariantsAreCaseInsensitiveLikeExactMatches() {
        let spans = EntityLocator.spans(forValue: "Alice Smith", type: .person, in: "ALICE\nSMITH signed.")

        XCTAssertEqual(spans.map(\.text), ["ALICE\nSMITH"])
    }

    func testValueWithRegexMetacharactersIsStillALiteral() {
        let text = "Vendor: Acme (HK)\nLtd. and Acme (HK) Ltd."
        let spans = EntityLocator.spans(forValue: "Acme (HK) Ltd.", type: .company, in: text)

        XCTAssertEqual(spans.map(\.text), ["Acme (HK)\nLtd.", "Acme (HK) Ltd."])
    }

    func testCJKScriptBoundaryDriftAnchorsEveryOccurrence() {
        // The model reports "化工路口 98 号" (spaces at the script boundary); the
        // source carries the tight form once and the spaced form once. Both are
        // the same address and both must be redacted.
        let text = "地址一：杭州市化工路口98号。地址二：杭州市化工路口 98 号。"
        let spans = EntityLocator.spans(forValue: "化工路口 98 号", type: .address, in: text)

        XCTAssertEqual(spans.map(\.text), ["化工路口98号", "化工路口 98 号"])
    }

    func testAGapLongerThanTheBoundIsNotAVariant() {
        // The whitespace run between two words is bounded so the pattern cannot
        // bridge a whole blank region of the page.
        let text = "Alice" + String(repeating: " ", count: 200) + "Smith"

        XCTAssertTrue(EntityLocator.spans(forValue: "Alice Smith", type: .person, in: text).isEmpty)
    }

    func testVariantSearchStaysFastOnLongWhitespaceRuns() {
        // Perf guard in the style of RestorerSuspectTests: a document made of
        // the first word followed by long whitespace runs must not backtrack.
        let block = "Alice" + String(repeating: " \n", count: 40) + "Alicia "
        let text = String(repeating: block, count: 2_000) + "Smith"

        let started = CFAbsoluteTimeGetCurrent()
        _ = EntityLocator.spans(forValue: "Alice Smith", type: .person, in: text)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertLessThan(elapsed, 1.5)
    }

    // MARK: - Extractor

    func testExtractorAnchorsTheWrappedOccurrenceAndStaysFullyAnchored() throws {
        let extractor = LLMExtractor(completer: FixedCompleter(output: Self.aliceJSON))

        let result = try extractor.extractDetailed(from: Self.reviewText)

        XCTAssertEqual(result.spans.map(\.text), ["Alice Smith", "Alice\nSmith"])
        XCTAssertTrue(result.fullyAnchored)
        XCTAssertEqual(result.unlocatableEntityCount, 0)
        XCTAssertEqual(result.phantomEntityCount, 0)
    }

    // MARK: - Rescan

    func testFullDocumentRescanSweepsTheWrappedOccurrence() {
        let exact = utf16Range(of: "Alice Smith", in: Self.reviewText)
        let confirmed = [
            Span(
                start: exact.location,
                end: exact.location + exact.length,
                type: .person,
                text: "Alice Smith",
                source: .llm,
                confidence: 0.7,
                priority: EntityLocator.llmPriority
            )
        ]

        let expanded = EntityRescan.expand(confirmed, in: Self.reviewText)

        XCTAssertTrue(
            expanded.contains { $0.text == "Alice\nSmith" && $0.type == .person },
            "the literal rescan must sweep the wrapped repeat mention, got \(expanded.map(\.text))"
        )
    }

    // MARK: - End to end: the review's evidence

    func testAnonymizeLeavesNoHalfOfTheWrappedNameVisibleAndRestoresExactly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EntityLocatorWhitespaceVariantTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("source.txt")
        try Data(Self.reviewText.utf8).write(to: input)
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: FixedCompleter(output: Self.aliceJSON))
        }
        let protection = MappingProtection.passphrase("pw")

        let result = try LDAService.anonymize(
            input: input,
            outputDir: dir.appendingPathComponent("out", isDirectory: true),
            protection: protection,
            createdAtISO8601: "2026-09-07T00:00:00Z",
            llmModelPath: "/nonexistent.gguf"
        )

        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertFalse(redacted.contains("Alice"), "redacted surface still shows the first name: \(redacted)")
        XCTAssertFalse(redacted.contains("Smith"), "redacted surface still shows the surname: \(redacted)")

        let restoredURL = dir.appendingPathComponent("restored.txt")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: protection,
            output: restoredURL
        )
        XCTAssertEqual(
            try String(contentsOf: report.outputURL, encoding: .utf8), Self.reviewText,
            "the wrapped slice must restore byte-identically, line break included"
        )
    }
}
