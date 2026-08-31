//
//  SpanMerger.swift
//  LDACore
//
//  Merges deterministic and LLM span lists into a single conflict-free list.
//
//  Mirrors the proven Python overlap-resolution logic in core/anonymizer.py
//  (sort candidates, greedily accept non-overlapping winners, drop overlappers),
//  extended here with a priority dimension so deterministic structured PII wins
//  conflicts against fuzzy LLM spans.
//
//  Offsets are UTF-16 code-unit offsets, NSRange-compatible: start inclusive,
//  end exclusive. Overlap is defined as start < other.end && end > other.start,
//  so spans that merely touch at a boundary do not overlap.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Combines deterministic and LLM detections into one ordered, conflict-free
/// list of spans. Pure and deterministic: the same inputs always produce the
/// same output, independent of input ordering.
public enum SpanMerger {

    /// Merge the deterministic and LLM span lists.
    ///
    /// Steps:
    /// 1. Drop any span whose trimmed surface text is a known role label.
    /// 2. De-duplicate spans that are identical in (start, end, text).
    /// 3. Resolve overlaps over the union of both lists. Candidates are ordered
    ///    so the winner is chosen by (a) higher priority, then (b) longer span
    ///    (end - start), then (c) earlier start. Winners are accepted greedily.
    ///    A candidate that collides with already-accepted spans does NOT
    ///    disappear: the best-ranked span it collides with GROWS to the union
    ///    of every colliding range, keeping its own type, source, confidence,
    ///    and priority. Priority therefore still decides identity, exactly as
    ///    before, while coverage is never lost.
    /// 4. Return the accepted spans sorted by start ascending.
    ///
    /// The coverage invariant, which is the whole point of step 3:
    ///
    ///   The accepted spans cover EXACTLY the characters the candidates
    ///   claimed. Never fewer, never more.
    ///
    /// Dropping a colliding candidate outright violates the "never fewer" half
    /// whenever the loser reaches past the winner on either side, and every
    /// uncovered character is PII in cleartext in a file about to be handed to
    /// an AI. That shipped once: a SEAL span whose backward walk stopped at the
    /// Latin initial of "ABC科技有限公司" evicted the wider COMPANY span and left
    /// "ABC" in the redacted output. Note the geometry: the winner was NOT
    /// contained in the loser and did not contain it either, so a containment
    /// rule alone would not have caught it. Absorption is the general fix.
    ///
    /// - Parameters:
    ///   - deterministic: Trusted, structured detections (high priority).
    ///   - llm: Fuzzy LLM detections (lower priority).
    /// - Returns: Accepted, non-overlapping spans sorted by start ascending.
    public static func merge(deterministic: [Span], llm: [Span]) -> [Span] {
        let candidates = deduplicated(deterministic + llm)
        let accepted = resolveOverlaps(candidates.sorted(by: winnerOrder))
        return accepted.sorted(by: documentOrder)
    }

    /// Steps 1 and 2: drop role-label spans, then collapse spans identical in
    /// (start, end, text). The first occurrence in the given order is kept, so
    /// redundant candidates never reach the resolver.
    private static func deduplicated(_ spans: [Span]) -> [Span] {
        var seenKeys = Set<DedupKey>()
        var deduped: [Span] = []
        deduped.reserveCapacity(spans.count)
        for span in spans where !RoleLabels.isRoleLabel(span.text) {
            let key = DedupKey(start: span.start, end: span.end, text: span.text)
            if seenKeys.insert(key).inserted {
                deduped.append(span)
            }
        }
        return deduped
    }

    /// The winner ordering, which decides which span keeps its IDENTITY when
    /// candidates collide:
    ///   (a) higher priority first       -> descending priority
    ///   (b) longer span first           -> descending (end - start)
    ///   (c) earlier start first         -> ascending start
    /// A final tie-break on end keeps the ordering total and stable so the
    /// result is fully deterministic regardless of input order.
    private static func winnerOrder(_ lhs: Span, _ rhs: Span) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        let lhsLength = lhs.end - lhs.start
        let rhsLength = rhs.end - rhs.start
        if lhsLength != rhsLength {
            return lhsLength > rhsLength
        }
        if lhs.start != rhs.start {
            return lhs.start < rhs.start
        }
        return lhs.end < rhs.end
    }

    /// Document order: by start ascending, then end. Keeps ordering total for
    /// spans that share a start (only zero-width or boundary-touching spans,
    /// which do not count as overlapping).
    private static func documentOrder(_ lhs: Span, _ rhs: Span) -> Bool {
        if lhs.start != rhs.start {
            return lhs.start < rhs.start
        }
        return lhs.end < rhs.end
    }

    /// Step 3: walk the candidates in winner order and accept greedily. A
    /// candidate that collides with accepted spans is ABSORBED into the
    /// best-ranked one it collides with rather than dropped, so its coverage
    /// survives even though its identity does not.
    ///
    /// The absorbed range can never reach an accepted span outside the
    /// collision set: every contributor overlaps the candidate, so the union is
    /// contiguous and every offset inside it belongs to the candidate or to a
    /// collision. An accepted span inside that range would therefore have to
    /// overlap the candidate (accepted spans never overlap each other), which
    /// would have put it in the set. No cascade is possible.
    private static func resolveOverlaps(_ ordered: [Span]) -> [Span] {
        var accepted: [Span] = []
        accepted.reserveCapacity(ordered.count)
        for candidate in ordered {
            let collisions = accepted.indices.filter { overlaps(accepted[$0], candidate) }
            guard let winnerIndex = collisions.first else {
                accepted.append(candidate)
                continue
            }
            // collisions.first is the earliest ACCEPTED index, and acceptance
            // follows the winner ordering, so it is the best-ranked span in the
            // collision set. It keeps its identity and takes the union range.
            let contributors = collisions.map { accepted[$0] } + [candidate]
            guard let absorbed = absorb(into: accepted[winnerIndex], contributors: contributors)
            else {
                continue
            }
            accepted[winnerIndex] = absorbed
            for index in collisions.dropFirst().reversed() {
                accepted.remove(at: index)
            }
        }
        return accepted
    }

    /// Two spans overlap when they share at least one character. Spans that
    /// merely touch at a boundary (one ends where the next starts) do not.
    private static func overlaps(_ lhs: Span, _ rhs: Span) -> Bool {
        lhs.start < rhs.end && lhs.end > rhs.start
    }

    /// Grow `winner` to the union of every contributor's range, keeping the
    /// winner's type, source, confidence, and priority.
    ///
    /// Every contributor overlaps the incoming candidate, so their combined
    /// range is contiguous and the union is simply min(start) through max(end).
    ///
    /// Returns nil when the union surface cannot be assembled, which only
    /// happens if some contributor's `text` is not an exact slice of its own
    /// [start, end) range. That breaks the documented Span invariant, and the
    /// caller then falls back to the historical behavior of dropping the
    /// candidate rather than writing a surface that would restore incorrectly.
    private static func absorb(into winner: Span, contributors: [Span]) -> Span? {
        guard let start = contributors.map({ $0.start }).min(),
              let end = contributors.map({ $0.end }).max(),
              let text = unionText(of: contributors, from: start, to: end) else {
            return nil
        }
        var absorbed = winner
        absorbed.start = start
        absorbed.end = end
        absorbed.text = text
        return absorbed
    }

    /// Stitch the contributors' surfaces into the one surface covering
    /// [start, end). Walks the contributors in start order, appending only the
    /// part of each that the cursor has not passed yet. Returns nil on a gap or
    /// on a contributor whose text length disagrees with its range.
    private static func unionText(of contributors: [Span], from start: Int, to end: Int) -> String? {
        let ordered = contributors.sorted { lhs, rhs in
            if lhs.start != rhs.start {
                return lhs.start < rhs.start
            }
            return lhs.end > rhs.end
        }

        var assembled = ""
        var cursor = start
        for piece in ordered {
            guard piece.end > cursor else {
                // Fully inside what the cursor already covers.
                continue
            }
            guard piece.start <= cursor else {
                // A hole the contributors do not cover; refuse to guess.
                return nil
            }
            let surface = piece.text as NSString
            guard surface.length == piece.end - piece.start else {
                return nil
            }
            assembled += surface.substring(from: cursor - piece.start)
            cursor = piece.end
        }
        return cursor == end ? assembled : nil
    }

    /// Identity key for de-duplication: two spans collapse only when start, end,
    /// and surface text all match. Type, source, confidence, and priority are
    /// intentionally excluded so a deterministic and an LLM span covering the
    /// exact same text resolve through priority rather than silently merging.
    private struct DedupKey: Hashable {
        let start: Int
        let end: Int
        let text: String
    }
}
