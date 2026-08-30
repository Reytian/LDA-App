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

    // MARK: - Unanchorable values are counted, not silently dropped

    func testCountsEntityThatCannotBeAnchoredAnywhere() throws {
        let text = "This agreement is between Acme Corp and John Smith."
        let json = """
        {"entities":[{"value":"John Smith","type":"PERSON"},\
        {"value":"Hallucinated Holdings","type":"COMPANY"}],"redacted_text":""}
        """
        let extractor = LLMExtractor(completer: FixedCompleter(output: json))

        let result = try extractor.extractDetailed(from: text)

        XCTAssertEqual(result.spans.count, 1)
        XCTAssertEqual(
            result.unlocatableEntityCount,
            1,
            "a reported value that anchors nowhere must be counted, not silently dropped"
        )
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
    }
}
