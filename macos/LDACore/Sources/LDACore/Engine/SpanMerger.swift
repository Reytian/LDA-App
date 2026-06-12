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
    ///    (end - start), then (c) earlier start. Winners are accepted greedily;
    ///    any candidate overlapping an already-accepted span is discarded. This
    ///    enforces "deterministic wins on conflict" because deterministic
    ///    structured types carry higher priority than LLM spans.
    /// 4. Return the accepted spans sorted by start ascending.
    ///
    /// - Parameters:
    ///   - deterministic: Trusted, structured detections (high priority).
    ///   - llm: Fuzzy LLM detections (lower priority).
    /// - Returns: Accepted, non-overlapping spans sorted by start ascending.
    public static func merge(deterministic: [Span], llm: [Span]) -> [Span] {
        // Step 1: union both lists, then drop role-label spans.
        let union = deterministic + llm
        let filtered = union.filter { span in
            !RoleLabels.isRoleLabel(span.text)
        }

        // Step 2: de-duplicate identical (start, end, text) spans. The first
        // occurrence in the union order is kept; later identical spans are
        // dropped. This avoids feeding redundant candidates into the resolver.
        var seenKeys = Set<DedupKey>()
        var deduped: [Span] = []
        deduped.reserveCapacity(filtered.count)
        for span in filtered {
            let key = DedupKey(start: span.start, end: span.end, text: span.text)
            if seenKeys.insert(key).inserted {
                deduped.append(span)
            }
        }

        // Step 3: order candidates so the winner sorts first, then greedily
        // accept non-overlapping winners.
        //
        // Winner ordering:
        //   (a) higher priority first       -> descending priority
        //   (b) longer span first           -> descending (end - start)
        //   (c) earlier start first         -> ascending start
        // A final tie-break on end keeps the ordering total and stable so the
        // result is fully deterministic regardless of input order.
        let ordered = deduped.sorted { lhs, rhs in
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

        var accepted: [Span] = []
        accepted.reserveCapacity(ordered.count)
        for candidate in ordered {
            let overlaps = accepted.contains { existing in
                candidate.start < existing.end && candidate.end > existing.start
            }
            if !overlaps {
                accepted.append(candidate)
            }
        }

        // Step 4: return accepted spans sorted by start ascending. A secondary
        // sort by end keeps ordering total for any spans that share a start
        // (which can only happen for zero-width or boundary-touching spans that
        // do not count as overlapping).
        return accepted.sorted { lhs, rhs in
            if lhs.start != rhs.start {
                return lhs.start < rhs.start
            }
            return lhs.end < rhs.end
        }
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
