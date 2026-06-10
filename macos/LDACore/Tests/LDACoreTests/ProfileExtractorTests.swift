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
        // Same key, same normalized value: the second row has higher confidence
        // AND snippetVerified. The kept entry should carry the second row's
        // confidence, provenance, and snippetVerified; but the id must equal the
        // FIRST field's id so downstream references stay stable (M1, M2).
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

    func testMergeFieldStableIdAndVerifiedFirstTieBreak() throws {
        // Direct test of mergeField's two behavioral contracts using known UUIDs.
        // mergeField is internal so @testable import exposes it.
        let extractor = ProfileExtractor(completer: FakeCompleter([]))

        let firstId  = UUID()
        let secondId = UUID()

        // Build two fields with the same key and same normalizedValue.
        let lowerConf = ProfileField(
            id: firstId,
            key: .companyName,
            value: "Acme Holdings Limited",
            sourceDocument: "cert.pdf",
            sourceSnippet: "Acme Holdings Limited",
            snippetVerified: true,
            confidence: 0.7,
            userEdited: false
        )
        let higherConf = ProfileField(
            id: secondId,
            key: .companyName,
            value: "acme holdings limited",  // same after normalizing
            sourceDocument: "articles.pdf",
            sourceSnippet: "acme holdings limited",
            snippetVerified: true,
            confidence: 0.9,
            userEdited: false
        )

        // M1: higher-confidence winner must keep the first-seen (lowerConf) id.
        var fields: [ProfileField] = [lowerConf]
        extractor.mergeField(higherConf, into: &fields)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].id, firstId,
            "winner must adopt the first-seen field's id so Blank.proposedFieldID does not dangle")
        XCTAssertEqual(fields[0].sourceDocument, "articles.pdf",
            "winner's provenance replaces the kept entry's provenance")
        XCTAssertEqual(fields[0].confidence, 0.9, accuracy: 0.001)

        // M2: verified beats unverified even at lower raw confidence.
        let unverifiedHigh = ProfileField(
            id: UUID(),
            key: .jurisdiction,
            value: "British Virgin Islands",
            sourceDocument: "cert.pdf",
            sourceSnippet: "not in any source",
            snippetVerified: false,
            confidence: 0.4,   // capped but still higher than verifiedLow
            userEdited: false
        )
        let verifiedLow = ProfileField(
            id: UUID(),
            key: .jurisdiction,
            value: "British Virgin Islands",
            sourceDocument: "articles.pdf",
            sourceSnippet: "incorporated in the British Virgin Islands",
            snippetVerified: true,
            confidence: 0.35,
            userEdited: false
        )
        var jFields: [ProfileField] = [unverifiedHigh]
        extractor.mergeField(verifiedLow, into: &jFields)
        XCTAssertEqual(jFields.count, 1)
        XCTAssertTrue(jFields[0].snippetVerified,
            "verified row at 0.35 must beat unverified row at 0.4")
        XCTAssertEqual(jFields[0].sourceDocument, "articles.pdf")
    }

    func testDedupeVerifiedBeatsUnverified() throws {
        // Verified 0.35 must win over unverified 0.4 (M2: verified-first tie-break).
        // Row 1: unverified (snippet not in text), confidence 0.4 (will be capped to 0.4).
        // Row 2: verified (snippet found case-insensitively), raw confidence 0.35.
        let text1 = "irrelevant text for first doc"
        let text2 = "Acme Holdings Limited is the registered name."
        let fake = FakeCompleter([
            "[\(row("companyName", "Acme Holdings Limited", snippet: "not in any document", confidence: 0.4))]",
            "[\(row("companyName", "Acme Holdings Limited", snippet: "Acme Holdings Limited is the registered name", confidence: 0.35))]"
        ])
        let result = try ProfileExtractor(completer: fake).extract(sources: [
            ("cert.pdf", text1),
            ("articles.pdf", text2)
        ])
        let kept = result.fields.filter { $0.key == .companyName }
        XCTAssertEqual(kept.count, 1, "same normalized value should collapse to one entry")
        XCTAssertTrue(kept[0].snippetVerified, "verified row must win even at lower raw confidence")
        XCTAssertEqual(kept[0].sourceDocument, "articles.pdf",
            "winner's provenance should come from the verified row")
    }

    func testSplitSalvagesGoodHalf() throws {
        // One-chunk document. FakeCompleter queue: first attempt garbage, retry
        // garbage, then both split halves attempted. Third response is valid JSON
        // whose snippet appears in the original source; fourth is garbage.
        // The valid half should survive with snippetVerified true; the bad half
        // should increment incompleteSegmentCount to exactly 1.
        let docText = "Acme Holdings Limited is incorporated in the British Virgin Islands."
        let validJSON = "[\(row("companyName", "Acme Holdings Limited", snippet: "Acme Holdings Limited is incorporated", confidence: 0.9))]"
        let fake = FakeCompleter(["garbage", "garbage", validJSON, "garbage"])
        let result = try ProfileExtractor(completer: fake).extract(sources: [("cert.pdf", docText)])
        XCTAssertEqual(result.incompleteSegmentCount, 1,
            "one split half failed so incompleteSegmentCount must be 1")
        let companyFields = result.fields.filter { $0.key == .companyName }
        XCTAssertEqual(companyFields.count, 1, "salvaged half should yield one companyName field")
        XCTAssertTrue(companyFields[0].snippetVerified,
            "snippet from the good half must be located in the whole source text")
    }

    func testGroundingIsCaseInsensitive() throws {
        // Source has mixed case; snippet is all-caps. snippetVerified must be
        // true and confidence must NOT be capped.
        let text = "Acme Holdings Limited is the company name."
        let fake = FakeCompleter([
            "[\(row("companyName", "Acme Holdings Limited", snippet: "ACME HOLDINGS LIMITED", confidence: 0.88))]"
        ])
        let result = try ProfileExtractor(completer: fake).extract(sources: [("cert.pdf", text)])
        XCTAssertEqual(result.fields.count, 1)
        XCTAssertTrue(result.fields[0].snippetVerified,
            "case-insensitive match must verify the snippet")
        XCTAssertGreaterThan(result.fields[0].confidence, ProfileExtractor.ungroundedConfidenceCap,
            "verified snippet must not have confidence capped")
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

    func testProgressNeverExceedsTotalOnRetryAndSplit() throws {
        // One short source yields 1 chunk. The FakeCompleter returns 4 consecutive
        // garbage responses, exercising the full first-attempt + retry + both
        // split-halves path. onProgress must never fire with done > total, the
        // first pair must be (0,1), and the last pair must be (1,1).
        let fake = FakeCompleter(["garbage", "garbage", "garbage", "garbage"])
        var calls: [(Int, Int)] = []
        _ = try ProfileExtractor(completer: fake).extract(sources: [("cert.pdf", "short doc")]) { done, total in
            calls.append((done, total))
        }
        XCTAssertFalse(calls.isEmpty, "expected at least one progress call")
        for (done, total) in calls {
            XCTAssertLessThanOrEqual(done, total, "progress overflowed: done=\(done) total=\(total)")
        }
        XCTAssertEqual(calls.first?.0, 0, "first done should be 0")
        XCTAssertEqual(calls.first?.1, 1, "first total should be 1")
        XCTAssertEqual(calls.last?.0, 1, "last done should be 1")
        XCTAssertEqual(calls.last?.1, 1, "last total should be 1")
    }
}
