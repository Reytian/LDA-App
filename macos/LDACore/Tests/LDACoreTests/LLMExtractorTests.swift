//
//  LLMExtractorTests.swift
//  LDACoreTests
//
//  Tests for LLMExtractor.extract(from:). A mock TextCompleter returns canned
//  v2 single-shot JSON so the orchestration is exercised without loading the
//  GGUF model. The tests verify that:
//   - PERSON and COMPANY values are located at the correct UTF-16 offsets;
//   - structured types in the mock JSON (EMAIL, DATE) are dropped because the
//     DeterministicEngine owns them;
//   - a contract role label (Buyer) is dropped even when reported as a PERSON;
//   - a chunk whose completion is garbage is skipped without failing the run.
//
//  Offsets are UTF-16 code-unit offsets, NSRange-compatible. The fixtures here
//  are pure ASCII so UTF-16 offsets equal Character offsets, which keeps the
//  expected numbers easy to read.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class LLMExtractorTests: XCTestCase {

    // MARK: - Mock completer

    /// A small TextCompleter that returns canned output. It can either return one
    /// fixed string for every call, or route by a substring of the prompt so a
    /// specific chunk can be given garbage while others get valid JSON. It can
    /// also be configured to throw for a chunk matching a substring.
    private struct MockCompleter: TextCompleter {
        /// Returned when no routing rule matches.
        var defaultOutput: String = "{\"entities\":[],\"redacted_text\":\"\"}"
        /// promptSubstring -> canned completion to return when the prompt contains it.
        var routes: [(needle: String, output: String)] = []
        /// Prompt substrings that should make complete(...) throw.
        var throwOn: [String] = []

        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            if throwOn.contains(where: { prompt.contains($0) }) {
                throw MockError.completionFailed
            }
            for route in routes where prompt.contains(route.needle) {
                return route.output
            }
            return defaultOutput
        }
    }

    private enum MockError: Error {
        case completionFailed
    }

    // MARK: - Helpers

    /// UTF-16 offset of the first occurrence of needle in text, as an Int. Fails
    /// the test when the needle is absent so a typo in a fixture is loud.
    private func utf16Offset(
        of needle: String,
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        let ns = text as NSString
        let range = ns.range(of: needle)
        if range.location == NSNotFound {
            XCTFail("needle \(needle) not found in fixture", file: file, line: line)
            return -1
        }
        return range.location
    }

    // MARK: - PERSON and COMPANY are located at the right offsets

    func testLocatesPersonAndCompanyAtCorrectOffsets() throws {
        let text = "This Engagement Letter is between Acme Corp and John Smith."
        let json = """
        {"entities":[{"value":"John Smith","type":"PERSON"},\
        {"value":"Acme Corp","type":"COMPANY"}],"redacted_text":""}
        """
        let extractor = LLMExtractor(completer: MockCompleter(defaultOutput: json))

        let spans = try extractor.extract(from: text)

        XCTAssertEqual(spans.count, 2, "expected one span each for the person and the company")

        let person = try XCTUnwrap(spans.first { $0.type == .person })
        let company = try XCTUnwrap(spans.first { $0.type == .company })

        let personStart = utf16Offset(of: "John Smith", in: text)
        XCTAssertEqual(person.start, personStart)
        XCTAssertEqual(person.end, personStart + ("John Smith" as NSString).length)
        XCTAssertEqual(person.text, "John Smith")
        XCTAssertEqual(person.source, .llm)

        let companyStart = utf16Offset(of: "Acme Corp", in: text)
        XCTAssertEqual(company.start, companyStart)
        XCTAssertEqual(company.end, companyStart + ("Acme Corp" as NSString).length)
        XCTAssertEqual(company.text, "Acme Corp")
        XCTAssertEqual(company.source, .llm)
    }

    // MARK: - Structured types are dropped

    func testDropsStructuredTypesEmailAndDate() throws {
        let text = "Contact John Smith at john@acme.com on January 15, 2026."
        let json = """
        {"entities":[\
        {"value":"John Smith","type":"PERSON"},\
        {"value":"john@acme.com","type":"EMAIL"},\
        {"value":"January 15, 2026","type":"DATE"}],"redacted_text":""}
        """
        let extractor = LLMExtractor(completer: MockCompleter(defaultOutput: json))

        let spans = try extractor.extract(from: text)

        // Only the PERSON survives; EMAIL and DATE belong to the DeterministicEngine.
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.type, .person)
        XCTAssertFalse(spans.contains { $0.type == .email })
        XCTAssertFalse(spans.contains { $0.type == .date })
    }

    // MARK: - Role labels are dropped

    func testDropsRoleLabelValue() throws {
        // "Buyer" is a contract role label; even reported as a PERSON it must not
        // be redacted. "Jane Doe" is a real person and must survive.
        let text = "The Buyer is Jane Doe."
        let json = """
        {"entities":[\
        {"value":"Buyer","type":"PERSON"},\
        {"value":"Jane Doe","type":"PERSON"}],"redacted_text":""}
        """
        let extractor = LLMExtractor(completer: MockCompleter(defaultOutput: json))

        let spans = try extractor.extract(from: text)

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.text, "Jane Doe")
        XCTAssertFalse(
            spans.contains { $0.text == "Buyer" },
            "the Buyer role label must never be redacted"
        )
    }

    func testDropsFinancingRoleLabels() throws {
        // "Investor" / "Investors" are party roles (terms of art), not people, even
        // when the model reports them as PERSON. Only the real name survives.
        let text = "The Investor and the Investors appointed Maria Chen."
        let json = """
        {"entities":[\
        {"value":"Investor","type":"PERSON"},\
        {"value":"Investors","type":"PERSON"},\
        {"value":"Maria Chen","type":"PERSON"}],"redacted_text":""}
        """
        let extractor = LLMExtractor(completer: MockCompleter(defaultOutput: json))

        let spans = try extractor.extract(from: text)

        XCTAssertEqual(spans.map { $0.text }, ["Maria Chen"])
        XCTAssertFalse(spans.contains { $0.text == "Investor" || $0.text == "Investors" })
    }

    // MARK: - A garbage chunk is skipped without failing

    func testSkipsChunkWithGarbageCompletionWithoutFailing() throws {
        // Two well-separated paragraphs so the chunker yields more than one chunk.
        // The first chunk returns garbage; the second returns valid JSON. The run
        // must not throw, and must still surface the entity from the good chunk.
        let firstParagraph = String(repeating: "Alpha clause text. ", count: 200)
        let secondParagraph = "The seller is Acme Corp and the signer is Robert King."
        let text = firstParagraph + "\n\n" + secondParagraph

        let goodJSON = """
        {"entities":[{"value":"Robert King","type":"PERSON"},\
        {"value":"Acme Corp","type":"COMPANY"}],"redacted_text":""}
        """
        // Route by content: any chunk containing "Robert King" gets valid JSON;
        // every other chunk gets unparseable garbage.
        let completer = MockCompleter(
            defaultOutput: "}}}}not json at all{{{{",
            routes: [(needle: "Robert King", output: goodJSON)]
        )
        let extractor = LLMExtractor(completer: completer)

        // Sanity: the fixture really does chunk into more than one window so the
        // garbage path is actually exercised.
        XCTAssertGreaterThan(Chunker.chunk(text).count, 1)

        let spans = try extractor.extract(from: text)

        XCTAssertEqual(spans.count, 2)
        XCTAssertTrue(spans.contains { $0.text == "Robert King" && $0.type == .person })
        XCTAssertTrue(spans.contains { $0.text == "Acme Corp" && $0.type == .company })
    }

    // MARK: - A throwing chunk is skipped without failing

    func testSkipsChunkWhoseCompletionThrowsWithoutFailing() throws {
        let firstParagraph = String(repeating: "Beta recital text. ", count: 200)
        let secondParagraph = "The lender is Globex LLC and the agent is Mary Stone."
        let text = firstParagraph + "\n\n" + secondParagraph

        let goodJSON = """
        {"entities":[{"value":"Mary Stone","type":"PERSON"}],"redacted_text":""}
        """
        // The chunk carrying the recital filler throws; the chunk carrying
        // "Mary Stone" returns valid JSON.
        let completer = MockCompleter(
            defaultOutput: goodJSON,
            routes: [(needle: "Mary Stone", output: goodJSON)],
            throwOn: ["Beta recital text. Beta recital text."]
        )
        let extractor = LLMExtractor(completer: completer)

        let spans = try extractor.extract(from: text)

        XCTAssertTrue(spans.contains { $0.text == "Mary Stone" && $0.type == .person })
    }

    // MARK: - Truncation handling (LJE-001)

    /// A completer that truncates (returns a cut-off JSON array) until the caller
    /// asks for at least `succeedAtOrAbove` tokens, at which point it returns a
    /// complete JSON object. Records every maxTokens it was asked for so a test
    /// can assert that a larger-cap retry actually happened.
    private final class TruncatingCompleter: TextCompleter {
        let truncatedOutput: String
        let fullOutput: String
        let succeedAtOrAbove: Int
        private(set) var requestedMaxTokens: [Int?] = []

        init(truncatedOutput: String, fullOutput: String, succeedAtOrAbove: Int) {
            self.truncatedOutput = truncatedOutput
            self.fullOutput = fullOutput
            self.succeedAtOrAbove = succeedAtOrAbove
        }

        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            requestedMaxTokens.append(maxTokens)
            if let maxTokens, maxTokens >= succeedAtOrAbove {
                return fullOutput
            }
            return truncatedOutput
        }
    }

    /// A completer that ALWAYS truncates, regardless of the requested cap, so the
    /// extractor cannot fully scan the segment no matter how it retries or splits.
    private struct AlwaysTruncatingCompleter: TextCompleter {
        let truncatedOutput: String
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return truncatedOutput
        }
    }

    func testRetriesWithLargerCapWhenSegmentTruncates() throws {
        // The first attempt (default cap) returns a cut-off array carrying one
        // complete entity. A retry with a larger cap returns the full object with
        // both entities. The extractor must surface BOTH, proving it retried.
        let text = "The seller is Acme Corp and the signer is Robert King."
        let truncated = #"{"entities":[{"value":"Acme Corp","type":"COMPANY"},{"value":"Robert Ki"#
        let full = """
        {"entities":[{"value":"Acme Corp","type":"COMPANY"},\
        {"value":"Robert King","type":"PERSON"}],"redacted_text":""}
        """
        let completer = TruncatingCompleter(
            truncatedOutput: truncated,
            fullOutput: full,
            succeedAtOrAbove: 2048
        )
        let extractor = LLMExtractor(completer: completer)

        let spans = try extractor.extract(from: text)

        XCTAssertTrue(spans.contains { $0.text == "Acme Corp" && $0.type == .company })
        XCTAssertTrue(
            spans.contains { $0.text == "Robert King" && $0.type == .person },
            "the larger-cap retry must recover the entity that was cut off on the first attempt"
        )
        XCTAssertGreaterThanOrEqual(
            completer.requestedMaxTokens.count, 2,
            "a truncated segment must be retried at least once"
        )
        let maxRequested = completer.requestedMaxTokens.compactMap { $0 }.max() ?? 0
        XCTAssertGreaterThan(
            maxRequested, 1024,
            "the retry must request a larger token cap than the first attempt"
        )
    }

    func testReportsIncompleteWhenSegmentStillTruncatesAfterRetry() throws {
        // The completer always truncates. extractDetailed must still salvage the
        // leading complete entity AND report the segment as incomplete, so the
        // caller does not present a fully-scanned result.
        let text = "The seller is Acme Corp and the signer is Robert King."
        let truncated = #"{"entities":[{"value":"Acme Corp","type":"COMPANY"},{"value":"Robert Ki"#
        let completer = AlwaysTruncatingCompleter(truncatedOutput: truncated)
        let extractor = LLMExtractor(completer: completer)

        let result = try extractor.extractDetailed(from: text)

        XCTAssertTrue(
            result.spans.contains { $0.text == "Acme Corp" && $0.type == .company },
            "the complete leading entity must still be salvaged"
        )
        XCTAssertFalse(
            result.fullyCovered,
            "a segment that never stops truncating must be reported as not fully scanned"
        )
        XCTAssertGreaterThanOrEqual(result.incompleteSegmentCount, 1)
    }

    func testCleanRunReportsFullCoverage() throws {
        // A normal, well-formed completion must report full coverage and zero
        // incomplete segments, so the legitimate path is unaffected.
        let text = "This Engagement Letter is between Acme Corp and John Smith."
        let json = """
        {"entities":[{"value":"John Smith","type":"PERSON"},\
        {"value":"Acme Corp","type":"COMPANY"}],"redacted_text":""}
        """
        let extractor = LLMExtractor(completer: MockCompleter(defaultOutput: json))

        let result = try extractor.extractDetailed(from: text)

        XCTAssertTrue(result.fullyCovered)
        XCTAssertEqual(result.incompleteSegmentCount, 0)
        XCTAssertEqual(result.spans.count, 2)
    }

    func testGenuinelyEmptyExtractionIsFullyCovered() throws {
        // The model genuinely found no PII (well-formed empty array). This must be
        // full coverage with no spans, NOT flagged incomplete.
        let text = "This clause contains no sensitive information whatsoever."
        let extractor = LLMExtractor(
            completer: MockCompleter(defaultOutput: #"{"entities":[],"redacted_text":""}"#)
        )

        let result = try extractor.extractDetailed(from: text)

        XCTAssertTrue(result.fullyCovered, "genuine emptiness is full coverage, not truncation")
        XCTAssertEqual(result.incompleteSegmentCount, 0)
        XCTAssertTrue(result.spans.isEmpty)
    }

    // MARK: - Duplicate reports collapse to one span set

    func testDedupsRepeatedEntityReports() throws {
        // The same value appearing once in the text but reported by the model in
        // duplicate must produce exactly one span, not two.
        let text = "Memo from Acme Corp."
        let json = """
        {"entities":[\
        {"value":"Acme Corp","type":"COMPANY"},\
        {"value":"acme corp","type":"COMPANY"}],"redacted_text":""}
        """
        let extractor = LLMExtractor(completer: MockCompleter(defaultOutput: json))

        let spans = try extractor.extract(from: text)

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.text, "Acme Corp")
    }

    // MARK: - Casing mismatch between report and document (leak guard)

    func testCaseMismatchedReportStillLocatesEntity() throws {
        // The model reports the company upcased while the document spells it in
        // title case. Dedup keeps only the upcased report; location must still
        // find the document occurrence or the name leaks through anonymization.
        let text = "Engagement letter for Acme Corp, attention John Smith."
        let json = """
        {"entities":[\
        {"value":"ACME CORP","type":"COMPANY"},\
        {"value":"JOHN SMITH","type":"PERSON"}],"redacted_text":""}
        """
        let extractor = LLMExtractor(completer: MockCompleter(defaultOutput: json))

        let spans = try extractor.extract(from: text)

        XCTAssertEqual(spans.count, 2, "case-mismatched reports must still locate")
        XCTAssertEqual(
            Set(spans.map { $0.text }),
            ["Acme Corp", "John Smith"],
            "spans must carry the document surface, not the report casing"
        )
    }

    func testMixedCasingDocumentOccurrencesAllLocatedDespiteDedup() throws {
        // The document uses two casings; the model reports both, dedup collapses
        // them to one report. Every occurrence must still be located.
        let text = "Acme Corp signed first. ACME CORP countersigned later."
        let json = """
        {"entities":[\
        {"value":"ACME CORP","type":"COMPANY"},\
        {"value":"Acme Corp","type":"COMPANY"}],"redacted_text":""}
        """
        let extractor = LLMExtractor(completer: MockCompleter(defaultOutput: json))

        let spans = try extractor.extract(from: text)

        XCTAssertEqual(spans.count, 2, "both casing variants in the document must be found")
        XCTAssertEqual(Set(spans.map { $0.text }), ["Acme Corp", "ACME CORP"])
    }
}
