//
//  LLMExtractorDriftTests.swift
//  LDACoreTests
//
//  Tests that a model value carrying CJK script-boundary space drift is still
//  anchored back to the source, and that a value that anchors nowhere is
//  counted rather than silently dropped.
//
//  Space drift is a measured fine-tune failure mode: the model reports a correct
//  Chinese address or date with spaces inserted around embedded digits. The
//  literal locator never matches it, so the value was reported, never located,
//  and therefore never redacted, while recall still counted it as found.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class LLMExtractorDriftTests: XCTestCase {

    // MARK: - Mock completer

    /// Returns one canned completion for every prompt.
    private struct FixedCompleter: TextCompleter {
        let output: String

        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return output
        }
    }

    // MARK: - Helpers

    /// Slices text by a span's UTF-16 range, mirroring downstream consumers.
    private func slice(_ text: String, _ span: Span) -> String {
        let ns = text as NSString
        return ns.substring(with: NSRange(location: span.start, length: span.end - span.start))
    }

    // MARK: - Drifted values are recovered

    func testLocatesCJKAddressReportedWithDigitBoundarySpaces() throws {
        let text = "本合同签署地为杭州市西湖区文三路化工路口98号云汇大厦12层。"
        let json = """
        {"entities":[{"value":"杭州市西湖区文三路化工路口 98 号云汇大厦 12 层","type":"ADDRESS"}],"redacted_text":""}
        """
        let extractor = LLMExtractor(completer: FixedCompleter(output: json))

        let result = try extractor.extractDetailed(from: text)

        XCTAssertEqual(result.spans.count, 1, "the drifted address must still be located")
        let span = try XCTUnwrap(result.spans.first)
        XCTAssertEqual(
            slice(text, span),
            "杭州市西湖区文三路化工路口98号云汇大厦12层",
            "the located span must slice back to the source form, not the drifted form"
        )
        XCTAssertEqual(result.unlocatableEntityCount, 0)
    }

    // MARK: - Faithful values are not broken by the repair

    func testStillLocatesValueWhenSourceGenuinelyContainsTheSpaces() throws {
        // Some Chinese typography really does space Latin digits. A faithful
        // report of such a source must keep matching, which is why the repair is
        // a fallback and not an unconditional rewrite of the reported value.
        let text = "地址为北京市朝阳区建国路 88 号。"
        let json = """
        {"entities":[{"value":"北京市朝阳区建国路 88 号","type":"ADDRESS"}],"redacted_text":""}
        """
        let extractor = LLMExtractor(completer: FixedCompleter(output: json))

        let result = try extractor.extractDetailed(from: text)

        XCTAssertEqual(result.spans.count, 1)
        let span = try XCTUnwrap(result.spans.first)
        XCTAssertEqual(slice(text, span), "北京市朝阳区建国路 88 号")
        XCTAssertEqual(result.unlocatableEntityCount, 0)
    }

    // MARK: - Unanchorable values are counted, and classified

    // An unanchored value is one of two very different things and only one is a
    // privacy problem, so they are counted separately. Measured on the
    // full-document benchmark, after the CJK repair every remaining unanchored
    // value across all eight models was a phantom, and none was a leak. Counting
    // them together would block clean documents over invented names.

    func testInventedValueIsCountedAsPhantomNotAsLeak() throws {
        let text = "This agreement is between Acme Corp and John Smith."
        let json = """
        {"entities":[{"value":"John Smith","type":"PERSON"},\
        {"value":"Hallucinated Holdings","type":"COMPANY"}],"redacted_text":""}
        """
        let extractor = LLMExtractor(completer: FixedCompleter(output: json))

        let result = try extractor.extractDetailed(from: text)

        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(
            result.phantomEntityCount,
            1,
            "a value the document does not contain must be counted, not silently dropped"
        )
        XCTAssertEqual(
            result.unlocatableEntityCount,
            0,
            "nothing can leak a value the document does not contain"
        )
        XCTAssertTrue(result.fullyAnchored)
    }

    func testValuePresentButUnanchorableIsCountedAsLeak() throws {
        // The document really does contain this person; the model reflowed the
        // whitespace, so the literal locator cannot find it and it survives into
        // the output un-redacted.
        let text = "This agreement is between Acme Corp and John Smith."
        let json = """
        {"entities":[{"value":"John  Smith","type":"PERSON"}],"redacted_text":""}
        """
        let extractor = LLMExtractor(completer: FixedCompleter(output: json))

        let result = try extractor.extractDetailed(from: text)

        XCTAssertEqual(result.spans.count, 0, "the drifted form does not anchor")
        XCTAssertEqual(result.unlocatableEntityCount, 1)
        XCTAssertEqual(result.phantomEntityCount, 0)
        XCTAssertFalse(
            result.fullyAnchored,
            "a value the document contains but that cannot be redacted is a leak"
        )
    }

    // MARK: - The clean gate

    // LJE-001 says a document must not be presented as cleanly anonymized when
    // it is not guaranteed PII-free. An entity the model reported but that
    // anchors nowhere is exactly that: seen, and impossible to redact. It fails
    // the gate for a different reason than a truncated scan, so the two signals
    // stay separate and only the combined property gates.

    func testUnlocatableEntityFailsTheCleanGateEvenWhenEverySegmentWasScanned() {
        let result = ExtractionResult(
            spans: [], incompleteSegmentCount: 0, unlocatableEntityCount: 1
        )
        XCTAssertTrue(result.fullyCovered, "no segment was truncated")
        XCTAssertFalse(result.fullyAnchored)
        XCTAssertFalse(
            result.fullyAnchored,
            "a value that cannot be redacted must not pass as cleanly anonymized"
        )
    }

    func testTruncatedScanFailsTheCleanGateEvenWhenEveryReportedValueAnchored() {
        let result = ExtractionResult(
            spans: [], incompleteSegmentCount: 2, unlocatableEntityCount: 0
        )
        XCTAssertTrue(result.fullyAnchored, "nothing was left unanchored")
        XCTAssertFalse(result.fullyCovered, "but a segment was never scanned")
    }

    func testFullyScannedAndFullyAnchoredResultPassesTheCleanGate() {
        let result = ExtractionResult(
            spans: [], incompleteSegmentCount: 0, unlocatableEntityCount: 0
        )
        XCTAssertTrue(result.fullyCovered)
        XCTAssertTrue(result.fullyAnchored)
    }

    func testFullyAnchoredDocumentReportsNoUnlocatableEntities() throws {
        let text = "This agreement is between Acme Corp and John Smith."
        let json = """
        {"entities":[{"value":"John Smith","type":"PERSON"},\
        {"value":"Acme Corp","type":"COMPANY"}],"redacted_text":""}
        """
        let extractor = LLMExtractor(completer: FixedCompleter(output: json))

        let result = try extractor.extractDetailed(from: text)

        XCTAssertEqual(result.spans.count, 2)
        XCTAssertEqual(result.unlocatableEntityCount, 0)
        XCTAssertEqual(result.phantomEntityCount, 0)
    }
}
