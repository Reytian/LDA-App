//
//  SpanMergerTests.swift
//  LDACoreTests
//
//  Tests for SpanMerger.merge(deterministic:llm:).
//
//  Offsets are UTF-16 code-unit offsets, NSRange-compatible. Overlap means
//  start < other.end && end > other.start, so boundary-touching spans do not
//  overlap.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class SpanMergerTests: XCTestCase {

    // MARK: - Builders

    /// Builds a deterministic span with the high priority that validated
    /// structured PII carries (here 100), unless a different priority is given.
    private func det(
        _ start: Int,
        _ end: Int,
        _ type: EntityType,
        _ text: String,
        priority: Int = 100,
        confidence: Double = 1.0
    ) -> Span {
        Span(
            start: start,
            end: end,
            type: type,
            text: text,
            source: .deterministic,
            confidence: confidence,
            priority: priority
        )
    }

    /// Builds an LLM span with the lower priority LLM detections carry (here 10),
    /// unless a different priority is given.
    private func llm(
        _ start: Int,
        _ end: Int,
        _ type: EntityType,
        _ text: String,
        priority: Int = 10,
        confidence: Double = 0.8
    ) -> Span {
        Span(
            start: start,
            end: end,
            type: type,
            text: text,
            source: .llm,
            confidence: confidence,
            priority: priority
        )
    }

    // MARK: - Required: priority wins on conflict

    func testNationalIDOverlappingDateLetsNationalIDWin() {
        // A checksum-valid NATIONAL_ID (priority 100) overlaps an LLM DATE span.
        // The deterministic NATIONAL_ID must win and the DATE must be dropped.
        let nationalID = det(10, 21, .nationalID, "12345678901", priority: 100)
        let date = llm(14, 24, .date, "5678901234", priority: 10)

        let result = SpanMerger.merge(deterministic: [nationalID], llm: [date])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.type, .nationalID)
        XCTAssertEqual(result.first?.source, .deterministic)
        XCTAssertEqual(result.first?.start, 10)
        XCTAssertEqual(result.first?.end, 21)
    }

    func testDeterministicWinsEvenWhenLLMSpanIsLonger() {
        // Priority dominates length: even a longer LLM span loses to a shorter
        // deterministic span when the two overlap.
        let shortDet = det(5, 10, .nationalID, "ABCDE", priority: 100)
        let longLLM = llm(0, 30, .date, "0123456789012345678901234567890", priority: 10)

        let result = SpanMerger.merge(deterministic: [shortDet], llm: [longLLM])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.type, .nationalID)
        XCTAssertEqual(result.first?.source, .deterministic)
    }

    // MARK: - Required: equal priority, longer wins

    func testTwoOverlappingEqualPrioritySpansLongerWins() {
        // Two overlapping spans with equal priority: the longer span wins.
        let shorter = llm(0, 5, .person, "Alice", priority: 10)
        let longer = llm(2, 12, .company, "ice Corp Ltd", priority: 10)

        let result = SpanMerger.merge(deterministic: [], llm: [shorter, longer])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.start, 2)
        XCTAssertEqual(result.first?.end, 12)
        XCTAssertEqual(result.first?.type, .company)
    }

    func testEqualPriorityEqualLengthEarlierStartWins() {
        // Equal priority and equal length: the earlier start wins.
        let earlier = llm(0, 5, .person, "Alice", priority: 10)
        let later = llm(5, 10, .person, "Bobby", priority: 10)
        // These do not overlap (touch at boundary 5), so use a real overlap.
        let earlierOverlap = llm(0, 6, .person, "Alicex", priority: 10)
        let laterOverlap = llm(3, 9, .person, "cexBob", priority: 10)

        let nonOverlapResult = SpanMerger.merge(
            deterministic: [],
            llm: [earlier, later]
        )
        XCTAssertEqual(nonOverlapResult.count, 2)

        let overlapResult = SpanMerger.merge(
            deterministic: [],
            llm: [laterOverlap, earlierOverlap]
        )
        XCTAssertEqual(overlapResult.count, 1)
        XCTAssertEqual(overlapResult.first?.start, 0)
        XCTAssertEqual(overlapResult.first?.end, 6)
    }

    // MARK: - Required: role-label span dropped

    func testRoleLabelSpanFromLLMIsDropped() {
        // An LLM span whose text is a role label (here "Buyer") must be dropped.
        let roleLabel = llm(0, 5, .person, "Buyer", priority: 10)
        let realPerson = llm(10, 15, .person, "Alice", priority: 10)

        let result = SpanMerger.merge(deterministic: [], llm: [roleLabel, realPerson])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.text, "Alice")
    }

    func testRoleLabelDroppedCaseInsensitiveAndTrimmed() {
        // Role-label matching is case-insensitive and whitespace-trimmed.
        let lowerCased = llm(0, 6, .person, " buyer", priority: 10)
        let mixedCase = det(20, 26, .company, "SeLLeR", priority: 100)

        let result = SpanMerger.merge(deterministic: [mixedCase], llm: [lowerCased])

        XCTAssertTrue(result.isEmpty)
    }

    func testRoleLabelDroppedFromDeterministicListToo() {
        // The role-label filter applies to deterministic spans as well.
        let roleLabel = det(0, 7, .person, "Tenant", priority: 100)
        let realPerson = det(10, 15, .person, "Alice", priority: 100)

        let result = SpanMerger.merge(deterministic: [roleLabel, realPerson], llm: [])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.text, "Alice")
    }

    // MARK: - Required: non-overlapping survive, sorted by start

    func testNonOverlappingSpansAllSurviveSortedByStart() {
        // Non-overlapping spans all survive and come back sorted by start.
        let a = det(20, 25, .person, "Alice", priority: 100)
        let b = llm(0, 5, .company, "Acorp", priority: 10)
        let c = llm(10, 15, .email, "x@example", priority: 10)
        let d = det(30, 36, .phone, "555111", priority: 100)

        let result = SpanMerger.merge(deterministic: [a, d], llm: [b, c])

        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.map { $0.start }, [0, 10, 20, 30])
        XCTAssertEqual(result.map { $0.type }, [.company, .email, .person, .phone])
    }

    // MARK: - De-duplication

    func testIdenticalSpansAreDeduplicated() {
        // Identical (start, end, text) spans collapse into one.
        let one = llm(0, 5, .person, "Alice", priority: 10)
        let two = llm(0, 5, .person, "Alice", priority: 10)

        let result = SpanMerger.merge(deterministic: [], llm: [one, two])

        XCTAssertEqual(result.count, 1)
    }

    func testSpansWithSameRangeButDifferentTextAreNotDeduplicated() {
        // Same range, different text: not identical, so they collide as overlap
        // and exactly one survives (priority resolves the conflict).
        let detSpan = det(0, 5, .nationalID, "ABCDE", priority: 100)
        let llmSpan = llm(0, 5, .person, "VWXYZ", priority: 10)

        let result = SpanMerger.merge(deterministic: [detSpan], llm: [llmSpan])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.source, .deterministic)
        XCTAssertEqual(result.first?.priority, 100)
    }

    // MARK: - Boundary touching is not overlap

    func testBoundaryTouchingSpansBothSurvive() {
        // end of one equals start of the next: not an overlap, both survive.
        let first = llm(0, 5, .person, "Alice", priority: 10)
        let second = llm(5, 10, .person, "Bobby", priority: 10)

        let result = SpanMerger.merge(deterministic: [], llm: [first, second])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map { $0.start }, [0, 5])
    }

    // MARK: - Determinism regardless of input order

    func testResultIsIndependentOfInputOrder() {
        let a = det(10, 21, .nationalID, "12345678901", priority: 100)
        let b = llm(14, 24, .date, "5678901234", priority: 10)
        let c = llm(0, 5, .company, "Acorp", priority: 10)
        let d = llm(30, 35, .email, "x@e.x", priority: 10)

        let forward = SpanMerger.merge(deterministic: [a], llm: [b, c, d])
        let reversed = SpanMerger.merge(deterministic: [a], llm: [d, c, b])

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.map { $0.start }, [0, 10, 30])
    }

    // MARK: - Empty inputs

    func testBothListsEmptyReturnsEmpty() {
        let result = SpanMerger.merge(deterministic: [], llm: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testEmptyDeterministicKeepsLLMSpans() {
        let only = llm(0, 5, .person, "Alice", priority: 10)
        let result = SpanMerger.merge(deterministic: [], llm: [only])
        XCTAssertEqual(result, [only])
    }
}
