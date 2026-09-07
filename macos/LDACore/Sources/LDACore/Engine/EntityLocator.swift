//
//  EntityLocator.swift
//  LDACore
//
//  Locates an extracted entity value back in the source text, producing one
//  Span per occurrence. The v2 model returns surface values without offsets, so
//  this layer re-anchors them to UTF-16 ranges that SpanMerger and the Tokenizer
//  can consume.
//
//  Offset convention: returned Span.start/Span.end are UTF-16 code-unit offsets,
//  NSRange-compatible (start inclusive, end exclusive). See CoreTypes.swift.
//
//  Two searches run side by side: NSString's exact search (case-insensitive,
//  canonically equivalent) and a bounded whitespace-variant pattern
//  (EntityVariantPattern), so one exact occurrence never hides a repeat
//  mention broken by a line wrap.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - EntityLocator

/// Re-anchors a model-reported value to its occurrences in the source text.
public enum EntityLocator {
    /// Overlap-resolution priority stamped on every span this locator emits.
    ///
    /// LLM fuzzy entities sit below deterministic, checksum-validated structured
    /// PII (which carries a high priority such as 100), so deterministic
    /// detections win conflicts during merging.
    public static let llmPriority = 30

    /// Find every occurrence of value in text and emit a Span for each.
    ///
    /// The search trims surrounding whitespace from value, then scans text for
    /// every non-overlapping occurrence, advancing past each match so
    /// occurrences never overlap. Two searches run side by side and the
    /// leftmost hit wins at every step, so the result stays in document order:
    ///
    /// - The exact search (NSString) is case-insensitive and canonically
    ///   equivalent: the model may report "ACME CORP" for a document that
    ///   spells "Acme Corp", or an NFC name for an NFD source, and neither
    ///   mismatch may make the occurrence invisible.
    /// - The variant search (EntityVariantPattern) finds the same words with a
    ///   different run of whitespace between them: a line wrap, a page break,
    ///   a tab, a no-break or ideographic space, or CJK script-boundary space
    ///   drift in either direction. Before it existed one exact hit hid every
    ///   wrapped repeat mention, which then survived into the output while the
    ///   result was called fully anchored.
    ///
    /// Each span carries the document's actual surface bytes (the wrapped
    /// slice, line break included), so round-trip restore stays byte-identical
    /// and SpanSplitter can still split a span that crosses a break into
    /// per-part tokens downstream. All offsets are UTF-16 code-unit offsets
    /// (NSRange-compatible).
    ///
    /// Word boundaries: a match whose edge sits INSIDE a Latin word is
    /// rejected. A model-reported fragment such as "laint" (clipped from
    /// "Complaint") must not redact the tail of every "Complaint" in the
    /// document. A match is accepted only when, at each edge, the adjacent
    /// haystack character and the edge character are not both Latin word
    /// characters. CJK is exempt (no word delimiters exist), so CJK values keep
    /// matching inside CJK runs exactly as before.
    ///
    /// - Parameters:
    ///   - value: the surface value the model reported.
    ///   - type: the entity type to stamp on each emitted span.
    ///   - text: the source text to search.
    ///   - source: detection source for the spans. Defaults to .llm.
    ///   - confidence: confidence to stamp on each span. Defaults to 0.7.
    /// - Returns: one Span per occurrence, in document order. Empty when value
    ///   is blank or absent from text.
    public static func spans(
        forValue value: String,
        type: EntityType,
        in text: String,
        source: DetectionSource = .llm,
        confidence: Double = 0.7
    ) -> [Span] {
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return []
        }

        let haystack = text as NSString
        let length = haystack.length
        let needleLength = (needle as NSString).length
        guard needleLength > 0, length > 0 else {
            return []
        }

        var exact = SearchCursor { from in
            // Case folding and canonical equivalence both allow a match whose
            // code-unit length differs from the needle's, so nothing here
            // assumes needleLength; the search only bounds on the remaining
            // haystack.
            let found = haystack.range(
                of: needle,
                options: [.caseInsensitive],
                range: NSRange(location: from, length: length - from)
            )
            return found.location != NSNotFound && found.length > 0 ? found : nil
        }
        let variantPattern = EntityVariantPattern.regex(for: needle)
        var variant = SearchCursor { from in
            guard let variantPattern else { return nil }
            let found = variantPattern.firstMatch(
                in: text,
                options: [],
                range: NSRange(location: from, length: length - from)
            )?.range
            return found.map { $0.length > 0 ? $0 : nil } ?? nil
        }

        var result: [Span] = []
        var searchStart = 0

        while searchStart < length {
            guard let found = leftmost(exact.next(from: searchStart), variant.next(from: searchStart)) else {
                break
            }

            let start = found.location
            let end = found.location + found.length

            // Reject matches whose edges land inside a Latin word (see the
            // word-boundary note above). Advance by one code unit, not past the
            // match: a later, boundary-valid occurrence may begin inside the
            // rejected range's tail.
            guard isWordBoundary(in: haystack, start: start, end: end) else {
                searchStart = start + 1
                continue
            }

            // Capture the ACTUAL matched substring, not the needle. NSString.range
            // does canonical (NFC/NFD-insensitive) and case-insensitive matching,
            // and a variant hit differs from the needle in its whitespace, so
            // the matched slice can differ from the needle in both bytes and
            // length. Stamping `text: needle` would make span.text disagree with
            // the [start, end) bytes and silently change the document's casing,
            // normalization form, or line structure on restore. Using the
            // matched slice keeps span.text byte-identical to the source range.
            let matched = haystack.substring(with: found)
            result.append(
                Span(
                    start: start,
                    end: end,
                    type: type,
                    text: matched,
                    source: source,
                    confidence: confidence,
                    priority: llmPriority
                )
            )

            // Advance past this match so the next search cannot overlap it.
            searchStart = end
        }

        return result
    }

    // MARK: - Two-engine scan

    /// One search engine's position in the scan. A hit stays valid while the
    /// scan has not passed its start, so each engine walks the text once even
    /// when the other engine supplies most of the accepted matches; without
    /// this, a thousand wrapped mentions ahead of one exact mention would
    /// re-run the exact search a thousand times over the same stretch.
    private struct SearchCursor {
        private let search: (Int) -> NSRange?
        private var hit: NSRange?
        private var exhausted = false

        init(search: @escaping (Int) -> NSRange?) {
            self.search = search
        }

        mutating func next(from: Int) -> NSRange? {
            if exhausted {
                return nil
            }
            if let hit, hit.location >= from {
                return hit
            }
            hit = search(from)
            if hit == nil {
                exhausted = true
            }
            return hit
        }
    }

    /// The hit that starts first. On a tie the exact hit wins: the two then
    /// cover the same words, and the exact search's semantics (canonical
    /// equivalence) are the established ones.
    private static func leftmost(_ exact: NSRange?, _ variant: NSRange?) -> NSRange? {
        switch (exact, variant) {
        case (nil, nil):
            return nil
        case (let exact?, nil):
            return exact
        case (nil, let variant?):
            return variant
        case (let exact?, let variant?):
            return variant.location < exact.location ? variant : exact
        }
    }

    // MARK: - Word boundaries

    /// True when the [start, end) match does not begin or end inside a Latin
    /// word. An edge is inside a word when the characters on both sides of it
    /// are Latin word characters (letters or digits, ASCII plus Latin-1 and
    /// Latin Extended). Non-Latin scripts (CJK) never count as word characters,
    /// so matches in CJK text are always boundary-valid.
    private static func isWordBoundary(in haystack: NSString, start: Int, end: Int) -> Bool {
        if start > 0 {
            let before = haystack.character(at: start - 1)
            let first = haystack.character(at: start)
            if SegmentPacker.isLatinWordChar(before) && SegmentPacker.isLatinWordChar(first) {
                return false
            }
        }
        if end < haystack.length {
            let last = haystack.character(at: end - 1)
            let after = haystack.character(at: end)
            if SegmentPacker.isLatinWordChar(last) && SegmentPacker.isLatinWordChar(after) {
                return false
            }
        }
        return true
    }
}
