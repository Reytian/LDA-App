//
//  ProfileExtractorTests.swift
//  LDACoreTests
//
//  Unit tests for ProfileExtractor.extract(sources:onProgress:). A fake
//  TextCompleter returns queued responses so the orchestration is exercised
//  without loading the 2.7 GB GGUF model.
//
//  Tests verify: grounded snippet lookup, confidence capping for ungrounded
//  snippets, duplicate dedup across documents, conflicting values are both
//  kept, unparseble output triggers retry/split/incomplete marking, retry
//  doubles maxTokens, unknown model keys become .custom, progress callback
//  shape, dedup keeps higher-confidence provenance, and completer errors
//  propagate.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class ProfileExtractorTests: XCTestCase {

    // MARK: - Fake completer

    /// A fake TextCompleter returning queued responses and recording prompts.
    private final class FakeCompleter: TextCompleter {
        var queue: [String]
        var prompts: [String] = []
        var maxTokensSeen: [Int?] = []
        init(_ queue: [String]) { self.queue = queue }
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            prompts.append(prompt)
            maxTokensSeen.append(maxTokens)
            return queue.isEmpty ? "[]" : queue.removeFirst()
        }
    }

    private enum FakeError: Error { case boom }

    /// Fake completer that always throws.
    private final class ThrowingCompleter: TextCompleter {
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            throw FakeError.boom
        }
    }

    // MARK: - Helpers

    private func row(
        _ key: String,
        _ value: String,
        snippet: String,
        confidence: Double = 0.9
    ) -> String {
        "{\"key\": \"\(key)\", \"value\": \"\(value)\", \"snippet\": \"\(snippet)\", \"confidence\": \(confidence)}"
    }

    // MARK: - Tests

    func testExtractsGroundedField() throws {
        let text = "I certify that the name of the company is Acme Holdings Limited."
        let fake = FakeCompleter([
            "[\(row("companyName", "Acme Holdings Limited", snippet: "the name of the company is Acme Holdings Limited"))]"
        ])
        let extractor = ProfileExtractor(completer: fake)
        let result = try extractor.extract(sources: [("cert.pdf", text)])
        XCTAssertEqual(result.fields.count, 1)
        XCTAssertEqual(result.fields[0].key, .companyName)
        XCTAssertTrue(result.fields[0].snippetVerified)
        XCTAssertEqual(result.fields[0].sourceDocument, "cert.pdf")
        XCTAssertEqual(result.incompleteSegmentCount, 0)
    }

    func testUngroundedSnippetCapsConfidence() throws {
        let text = "irrelevant text"
        let fake = FakeCompleter([
            "[\(row("companyName", "Acme", snippet: "not in the document", confidence: 0.95))]"
        ])
        let result = try ProfileExtractor(completer: fake).extract(sources: [("cert.pdf", text)])
        XCTAssertFalse(result.fields[0].snippetVerified)
        XCTAssertLessThanOrEqual(result.fields[0].confidence, ProfileExtractor.ungroundedConfidenceCap)
    }

    func testDuplicateAcrossDocumentsDeduped() throws {
        let fake = FakeCompleter([
            "[\(row("companyName", "Acme Holdings Limited", snippet: "Acme Holdings Limited"))]",
            "[\(row("companyName", "ACME HOLDINGS  LIMITED", snippet: "ACME HOLDINGS  LIMITED"))]"
        ])
        let result = try ProfileExtractor(completer: fake).extract(sources: [
            ("cert.pdf", "Acme Holdings Limited"),
            ("articles.pdf", "ACME HOLDINGS  LIMITED")
        ])
        XCTAssertEqual(result.fields.filter { $0.key == .companyName }.count, 1)
    }

    func testConflictingValuesBothKept() throws {
        let fake = FakeCompleter([
            "[\(row("companyName", "Acme Holdings Limited", snippet: "Acme Holdings Limited"))]",
            "[\(row("companyName", "Acme Holdings (HK) Limited", snippet: "Acme Holdings (HK) Limited"))]"
        ])
        let result = try ProfileExtractor(completer: fake).extract(sources: [
            ("cert.pdf", "Acme Holdings Limited"),
            ("articles.pdf", "Acme Holdings (HK) Limited")
        ])
        XCTAssertEqual(result.fields.filter { $0.key == .companyName }.count, 2)
    }

    func testUnparseableRetriesThenSplitsThenMarksIncomplete() throws {
        // Contract: initial call fails, retry fails; split into two halves,
        // each half gets ONE attempt; both fail here.
        let fake = FakeCompleter(["garbage", "garbage", "garbage", "garbage"])
        let result = try ProfileExtractor(completer: fake).extract(sources: [("cert.pdf", "short doc")])
        XCTAssertEqual(result.fields.count, 0)
        XCTAssertGreaterThan(result.incompleteSegmentCount, 0)
    }

    func testRetryDoublesMaxTokens() throws {
        let fake = FakeCompleter(["garbage", "[]"])
        _ = try ProfileExtractor(completer: fake).extract(sources: [("cert.pdf", "short doc")])
        XCTAssertEqual(fake.maxTokensSeen.count, 2)
        if let first = fake.maxTokensSeen[0], let second = fake.maxTokensSeen[1] {
            XCTAssertEqual(second, first * 2)
        } else {
            XCTFail("expected explicit maxTokens on both calls")
        }
    }

    func testUnknownKeyBecomesCustomField() throws {
        let text = "seal number 778899"
        let fake = FakeCompleter([
            "[\(row("sealNumber", "778899", snippet: "seal number 778899"))]"
        ])
        let result = try ProfileExtractor(completer: fake).extract(sources: [("cert.pdf", text)])
        XCTAssertEqual(result.fields[0].key, .custom("sealNumber"))
    }

    func testDedupeKeepsHigherConfidence() throws {
        // Same key, same normalized value: the second row has higher confidence.
        // The kept entry should carry the second row's confidence and provenance.
        let text1 = "Acme Holdings Limited"
        let text2 = "ACME HOLDINGS  LIMITED"
        let fake = FakeCompleter([
            "[\(row("companyName", "Acme Holdings Limited", snippet: "Acme Holdings Limited", confidence: 0.7))]",
            "[\(row("companyName", "ACME HOLDINGS  LIMITED", snippet: "ACME HOLDINGS  LIMITED", confidence: 0.95))]"
        ])
        let result = try ProfileExtractor(completer: fake).extract(sources: [
            ("cert.pdf", text1),
            ("articles.pdf", text2)
        ])
        let kept = result.fields.filter { $0.key == .companyName }
        XCTAssertEqual(kept.count, 1)
        XCTAssertGreaterThan(kept[0].confidence, 0.9)
        XCTAssertEqual(kept[0].sourceDocument, "articles.pdf")
    }

    func testProgressCallback() throws {
        let text = "Company name: Acme Holdings Limited"
        let fake = FakeCompleter([
            "[\(row("companyName", "Acme Holdings Limited", snippet: "Company name: Acme Holdings Limited"))]"
        ])
        var calls: [(Int, Int)] = []
        let extractor = ProfileExtractor(completer: fake)
        _ = try extractor.extract(sources: [("cert.pdf", text)]) { done, total in
            calls.append((done, total))
        }
        // Single short source yields 1 segment: expect (0,1) then (1,1).
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].0, 0)
        XCTAssertEqual(calls[0].1, 1)
        XCTAssertEqual(calls[1].0, 1)
        XCTAssertEqual(calls[1].1, 1)
    }

    func testCompleterErrorPropagates() throws {
        let throwing = ThrowingCompleter()
        let extractor = ProfileExtractor(completer: throwing)
        XCTAssertThrowsError(try extractor.extract(sources: [("cert.pdf", "some text")]))
    }
}
