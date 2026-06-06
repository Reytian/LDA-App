//
//  CustomPatternEngineTests.swift
//  Verifies the user vocabulary locates terms and stamps high-priority manual
//  spans that win conflicts during merging.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDACore

final class CustomPatternEngineTests: XCTestCase {

    func testLocatesAllOccurrencesCaseInsensitively() {
        let text = "Project Titan launched. project titan shipped. PROJECT TITAN won."
        let patterns = [CustomPattern(text: "Project Titan", type: .company)]

        let spans = CustomPatternEngine.detect(text, patterns: patterns)

        XCTAssertEqual(spans.count, 3)
        XCTAssertTrue(spans.allSatisfy { $0.type == .company })
        XCTAssertTrue(spans.allSatisfy { $0.source == .manual })
        XCTAssertTrue(spans.allSatisfy { $0.priority == CustomPatternEngine.priority })
        let ns = text as NSString
        for span in spans {
            XCTAssertEqual(ns.substring(with: NSRange(location: span.start, length: span.end - span.start)), span.text)
        }
    }

    func testCaseSensitiveMatchesExactCaseOnly() {
        let text = "ACME and acme and Acme"
        let patterns = [CustomPattern(text: "Acme", type: .company, caseSensitive: true)]

        let spans = CustomPatternEngine.detect(text, patterns: patterns)

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.text, "Acme")
    }

    func testEmptyTermAndEmptyTextProduceNothing() {
        XCTAssertTrue(CustomPatternEngine.detect("", patterns: [CustomPattern(text: "x")]).isEmpty)
        XCTAssertTrue(CustomPatternEngine.detect("hello", patterns: [CustomPattern(text: "   ")]).isEmpty)
        XCTAssertTrue(CustomPatternEngine.detect("hello", patterns: []).isEmpty)
    }

    func testRegexMatchesMatterNumbers() {
        let text = "See matters M-10293 and M-44810; M-1 is too short."
        let patterns = [CustomPattern(text: #"M-\d{5}"#, type: .unknown, isRegex: true)]

        let spans = CustomPatternEngine.detect(text, patterns: patterns)

        XCTAssertEqual(spans.map { $0.text }, ["M-10293", "M-44810"])
        XCTAssertTrue(spans.allSatisfy { $0.source == .manual })
    }

    func testInvalidRegexIsIgnoredNotCrashing() {
        let pattern = CustomPattern(text: "M-[", type: .unknown, isRegex: true)
        XCTAssertTrue(pattern.isInvalidRegex)
        XCTAssertTrue(CustomPatternEngine.detect("M-[ anything", patterns: [pattern]).isEmpty)
    }

    func testCustomTermWinsOverlapAgainstLLMSpan() {
        // A custom COMPANY term overlapping a lower-priority llm PERSON span: the
        // custom term must win after merging.
        let text = "Northwind Trading is the counterparty."
        let custom = CustomPatternEngine.detect(text, patterns: [CustomPattern(text: "Northwind Trading", type: .company)])
        let llm = EntityLocator.spans(forValue: "Northwind Trading", type: .person, in: text)

        let merged = SpanMerger.merge(deterministic: custom, llm: llm)

        let match = merged.first { $0.text == "Northwind Trading" }
        XCTAssertEqual(match?.type, .company, "the user's custom term wins the overlap")
    }
}
