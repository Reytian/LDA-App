//
//  LLMExtractorKeptTypesTests.swift
//  LDACoreTests
//
//  Which model-reported types the extractor keeps. The structured types the
//  DeterministicEngine recognises outright (EMAIL, PHONE, DATE, and the rest)
//  stay dropped, because the engine finds them itself and wins the merge.
//  National identifiers are the exception since US documents came into scope:
//  the engine knows the Chinese 18-character ID and the hyphenated US SSN, but
//  not every national format the model can recognise, so a model-reported
//  NATIONAL_ID is kept and the existing rules arbitrate. A value the source
//  does not contain anchors nowhere and is never redacted; one the engine also
//  found loses the overlap to the deterministic span by priority, so nothing
//  is redacted twice; one only the model knows is redacted instead of being
//  discarded and left in the document (the review found "SSN: 123-45-6789"
//  dropped this way before the engine learned the SSN shape).
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

    private static let createdAt = "2026-09-07T00:00:00Z"

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
    }

    override func tearDown() {
        LDAService.makeExtractorForTesting = nil
        super.tearDown()
    }

    private func writeFixture(_ text: String) throws -> (dir: URL, input: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMExtractorKeptTypesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("source.txt")
        try Data(text.utf8).write(to: input)
        return (dir, input)
    }

    private func nationalIDSpans(in spans: [Span]) -> [Span] {
        return spans.filter { $0.type == .nationalID }
    }

    // MARK: - Extractor

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

    // MARK: - Detector: the merge arbitrates

    func testNationalIDInAFormatThePatternsDoNotKnowIsRedactedFromTheModelReport() throws {
        // A UK National Insurance number: two letters, six digits, one letter.
        // No structured pattern claims it (plates need a province character,
        // WeChat needs a cue or wxid_, USCC is 18 characters, bank accounts
        // need 12 digits or more), which the first assertion pins so the test
        // cannot pass for the wrong reason.
        let nino = "QQ123456C"
        let text = "Employee record. National Insurance number \(nino). Manager: Alice Smith."
        XCTAssertTrue(
            nationalIDSpans(in: DeterministicEngine().detect(text)).isEmpty
                && !DeterministicEngine().detect(text).contains { $0.text.contains(nino) },
            "precondition: the deterministic engine must not know this format"
        )
        let fixture = try writeFixture(text)
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: FixedCompleter(output: #"""
            {"entities":[{"value":"\#(nino)","type":"NATIONAL_ID"},{"value":"Alice Smith","type":"PERSON"}],"redacted_text":""}
            """#))
        }

        let spans = try LDAService.detect(input: fixture.input, llmModelPath: "/nonexistent.gguf")

        let ids = nationalIDSpans(in: spans)
        XCTAssertEqual(ids.map(\.text), [nino], "the model-only national id must be redacted, got \(spans.map(\.text))")
        XCTAssertEqual(ids.first?.source, .llm)
    }

    func testDeterministicSSNWinsTheOverlapSoNothingIsRedactedTwice() throws {
        let ssn = "123-45-6789"
        let text = "Employee record. SSN: \(ssn). Manager: Alice Smith."
        let fixture = try writeFixture(text)
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: FixedCompleter(output: #"""
            {"entities":[{"value":"\#(ssn)","type":"NATIONAL_ID"},{"value":"Alice Smith","type":"PERSON"}],"redacted_text":""}
            """#))
        }

        let spans = try LDAService.detect(input: fixture.input, llmModelPath: "/nonexistent.gguf")

        let ids = nationalIDSpans(in: spans)
        XCTAssertEqual(ids.count, 1, "one SSN in the text must be one entity, got \(spans.map { "\($0.type):\($0.text)" })")
        XCTAssertEqual(ids.first?.text, ssn)
        XCTAssertEqual(ids.first?.source, .deterministic, "the validated deterministic span outranks the model report")
        XCTAssertEqual(ids.first?.priority, 92)
        XCTAssertEqual(spans.filter { $0.text == ssn }.count, 1, "no second span of any type may cover the same digits")
    }
}
