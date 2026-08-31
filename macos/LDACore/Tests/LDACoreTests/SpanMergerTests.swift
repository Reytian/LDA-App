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
        // The deterministic NATIONAL_ID must win the IDENTITY of the merged
        // span. Its RANGE absorbs the DATE tail rather than dropping it: the
        // three characters past 21 are text a detector claimed as PII, and
        // leaving them uncovered is the leak this merger must not produce.
        let nationalID = det(10, 21, .nationalID, "12345678901", priority: 100)
        let date = llm(14, 24, .date, "5678901234", priority: 10)

        let result = SpanMerger.merge(deterministic: [nationalID], llm: [date])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.type, .nationalID)
        XCTAssertEqual(result.first?.source, .deterministic)
        XCTAssertEqual(result.first?.start, 10)
        XCTAssertEqual(result.first?.end, 24)
        XCTAssertEqual(result.first?.text, "12345678901234")
    }

    func testDeterministicWinsEvenWhenLLMSpanIsLonger() {
        // Priority dominates length: even a longer LLM span loses the IDENTITY
        // to a shorter deterministic span when the two overlap. Strict
        // containment, so the merged range is the container's.
        let shortDet = det(5, 10, .nationalID, "56789", priority: 100)
        let longLLM = llm(0, 30, .date, "012345678901234567890123456789", priority: 10)

        let result = SpanMerger.merge(deterministic: [shortDet], llm: [longLLM])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.type, .nationalID)
        XCTAssertEqual(result.first?.source, .deterministic)
        XCTAssertEqual(result.first?.start, 0)
        XCTAssertEqual(result.first?.end, 30)
    }

    // MARK: - Required: equal priority, longer wins

    func testTwoOverlappingEqualPrioritySpansLongerWins() {
        // Two overlapping spans with equal priority: the longer span wins the
        // identity, and its range absorbs the shorter one's head.
        let shorter = llm(0, 5, .person, "Alice", priority: 10)
        let longer = llm(2, 12, .company, "ice Corp L", priority: 10)

        let result = SpanMerger.merge(deterministic: [], llm: [shorter, longer])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.start, 0)
        XCTAssertEqual(result.first?.end, 12)
        XCTAssertEqual(result.first?.type, .company)
        XCTAssertEqual(result.first?.text, "Alice Corp L")
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

        // The earlier start wins the identity; the range absorbs the loser.
        let overlapResult = SpanMerger.merge(
            deterministic: [],
            llm: [laterOverlap, earlierOverlap]
        )
        XCTAssertEqual(overlapResult.count, 1)
        XCTAssertEqual(overlapResult.first?.start, 0)
        XCTAssertEqual(overlapResult.first?.end, 9)
        XCTAssertEqual(overlapResult.first?.text, "AlicexBob")
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

    // MARK: - Coverage invariant: a loser never leaves characters uncovered

    /// The UTF-16 offsets covered by a span list.
    private func coverage(_ spans: [Span]) -> Set<Int> {
        var covered = Set<Int>()
        for span in spans where span.end > span.start {
            covered.formUnion(span.start..<span.end)
        }
        return covered
    }

    /// The shipped defect in its general form: a higher priority span that is
    /// NARROWER on one side used to evict the wider one outright, leaving the
    /// uncovered remainder in cleartext. The winner must absorb it instead.
    func testHigherPriorityNarrowerSpanAbsorbsTheLoserCoverage() {
        // The real SEAL geometry: the deterministic span starts LATER and ends
        // LATER than the LLM claim, so neither contains the other.
        let seal = det(3, 8, .seal, "34567", priority: 56)
        let company = llm(0, 6, .company, "012345", priority: 30)

        let result = SpanMerger.merge(deterministic: [seal], llm: [company])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.type, .seal, "priority still decides identity")
        XCTAssertEqual(result.first?.start, 0, "the loser's head must stay covered")
        XCTAssertEqual(result.first?.end, 8)
        XCTAssertEqual(result.first?.text, "01234567")
    }

    /// Strict containment: the higher priority span sits INSIDE the loser, so
    /// the loser's coverage on both sides has to survive.
    func testHigherPriorityContainedSpanAbsorbsBothSides() {
        let inner = det(4, 7, .phone, "456", priority: 60)
        let outer = llm(0, 10, .address, "0123456789", priority: 30)

        let result = SpanMerger.merge(deterministic: [inner], llm: [outer])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.type, .phone)
        XCTAssertEqual(result.first?.start, 0)
        XCTAssertEqual(result.first?.end, 10)
        XCTAssertEqual(result.first?.text, "0123456789")
    }

    /// One candidate may bridge two already accepted spans. The bridge closes
    /// the gap rather than being dropped, and the three collapse into one.
    func testBridgingCandidateAbsorbsEveryAcceptedSpanItTouches() {
        let left = det(0, 3, .email, "012", priority: 80)
        let right = det(8, 11, .email, "89A", priority: 80)
        let bridge = llm(2, 9, .company, "2345678", priority: 30)

        let result = SpanMerger.merge(deterministic: [left, right], llm: [bridge])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.start, 0)
        XCTAssertEqual(result.first?.end, 11)
        XCTAssertEqual(result.first?.text, "0123456789A")
        XCTAssertEqual(result.first?.type, .email, "the best ranked contributor keeps identity")
    }

    /// The property-style form of the bug: over many pseudo random span sets,
    /// the merge must (a) return non overlapping spans whose text slices back
    /// out of the source, and (b) cover EXACTLY the characters the candidates
    /// claimed. Losing a character is the leak; gaining one is over redaction.
    func testMergeCoversExactlyTheCandidateUnion() {
        let source = String(repeating: "0123456789", count: 6)
        let sourceNS = source as NSString
        var generator = SeededGenerator(seed: 0x5EA1)

        for iteration in 0..<400 {
            let candidates = randomSpans(in: sourceNS, count: 1 + iteration % 8, using: &generator)
            let deterministic = candidates.filter { $0.source == .deterministic }
            let fuzzy = candidates.filter { $0.source == .llm }

            let result = SpanMerger.merge(deterministic: deterministic, llm: fuzzy)

            assertNoOverlap(result, iteration: iteration)
            for span in result {
                let sliced = sourceNS.substring(
                    with: NSRange(location: span.start, length: span.end - span.start))
                XCTAssertEqual(sliced, span.text, "text must slice back, iteration \(iteration)")
            }
            XCTAssertEqual(
                coverage(result),
                coverage(candidates),
                "coverage must equal the candidate union, iteration \(iteration)"
            )
        }
    }

    /// Assert the merged spans are pairwise non overlapping and start ordered.
    private func assertNoOverlap(_ spans: [Span], iteration: Int) {
        for index in spans.indices.dropFirst() {
            XCTAssertLessThanOrEqual(
                spans[index - 1].end,
                spans[index].start,
                "merged spans must not overlap, iteration \(iteration)"
            )
        }
    }

    /// Build pseudo random, well formed spans over the given source text.
    private func randomSpans(
        in sourceNS: NSString,
        count: Int,
        using generator: inout SeededGenerator
    ) -> [Span] {
        let types: [EntityType] = [.person, .company, .seal, .address, .phone, .email]
        let priorities = [10, 30, 45, 56, 80, 100]
        return (0..<count).map { _ in
            let start = Int.random(in: 0..<(sourceNS.length - 1), using: &generator)
            let maxLength = min(12, sourceNS.length - start)
            let length = Int.random(in: 1...maxLength, using: &generator)
            let priority = priorities[Int.random(in: 0..<priorities.count, using: &generator)]
            return Span(
                start: start,
                end: start + length,
                type: types[Int.random(in: 0..<types.count, using: &generator)],
                text: sourceNS.substring(with: NSRange(location: start, length: length)),
                source: priority >= 45 ? .deterministic : .llm,
                confidence: 0.9,
                priority: priority
            )
        }
    }
}

/// A reproducible generator so the property test fails identically every run.
/// Plain linear congruential parameters from Knuth; randomness quality does
/// not matter here, repeatability does.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed &* 6364136223846793005 &+ 1442695040888963407
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
