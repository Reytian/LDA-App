//
//  LLMExtractorKeptTypesTests.swift
//  LDACoreTests
//
//  Which model-reported types the extractor keeps. The structured types the
//  DeterministicEngine owns outright (EMAIL, PHONE, DATE, and the rest) stay
//  dropped, because the engine finds them itself and wins the merge. National
//  identifiers are the exception since US SSNs came into scope: the
//  deterministic engine has no pattern for every national format the model can
//  recognise, so a model-reported NATIONAL_ID is kept and left to the
//  deterministic engine and the anchoring rules to arbitrate (a value the
//  source does not contain anchors nowhere and is never redacted; one the
//  engine also found is merged by priority).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class LLMExtractorKeptTypesTests: XCTestCase {

    private struct FixedCompleter: TextCompleter {
        let output: String
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return output
        }
    }

    func testModelReportedNationalIDSurvivesKeptTypes() throws {
        let text = "Employee record. SSN: 123-45-6789. Manager: Alice Smith."
        let json = #"""
        {"entities":[{"value":"123-45-6789","type":"NATIONAL_ID"},{"value":"Alice Smith","type":"PERSON"}],"redacted_text":""}
        """#

        let result = try LLMExtractor(completer: FixedCompleter(output: json)).extractDetailed(from: text)

        XCTAssertTrue(
            LLMExtractor.keptTypes.contains(.nationalID),
            "US SSNs are in scope, so a model-reported NATIONAL_ID is kept for the deterministic engine and the anchoring rules to arbitrate"
        )
        XCTAssertTrue(
            result.spans.contains { $0.type == .nationalID && $0.text == "123-45-6789" },
            "the reported SSN must anchor as a NATIONAL_ID span, got \(result.spans.map { "\($0.type):\($0.text)" })"
        )
        XCTAssertTrue(result.spans.contains { $0.type == .person && $0.text == "Alice Smith" })
        XCTAssertTrue(result.fullyAnchored)
    }

    func testStructuredTypesTheDeterministicEngineOwnsOutrightAreStillDropped() throws {
        let text = "Contact alice@example.com on 2026-09-07."
        let json = #"""
        {"entities":[{"value":"alice@example.com","type":"EMAIL"},{"value":"2026-09-07","type":"DATE"}],"redacted_text":""}
        """#

        let result = try LLMExtractor(completer: FixedCompleter(output: json)).extractDetailed(from: text)

        XCTAssertTrue(result.spans.isEmpty, "EMAIL and DATE belong to the deterministic engine")
        XCTAssertFalse(LLMExtractor.keptTypes.contains(.email))
        XCTAssertFalse(LLMExtractor.keptTypes.contains(.date))
    }
}
