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
//  Phase 2b scaffold: the interface is frozen here; the search body (literal
//  occurrence scan, overlap-safe emission) lands in a later phase.
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
    /// every non-overlapping substring occurrence, advancing past each match so
    /// occurrences never overlap. Matching is case-insensitive: the model may
    /// report "ACME CORP" for a document that spells "Acme Corp", and a casing
    /// mismatch must not make the occurrence invisible (that would leak the
    /// value through anonymization). Each span carries the document's actual
    /// surface bytes, so round-trip restore stays byte-identical. All offsets
    /// are UTF-16 code-unit offsets (NSRange-compatible), computed with
    /// NSString.
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

        var result: [Span] = []
        var searchStart = 0

        // Note: case folding and canonical equivalence both allow a match whose
        // code-unit length differs from the needle's, so the loop bounds must
        // not assume needleLength; it only bounds on the remaining haystack.
        while searchStart < length {
            let searchRange = NSRange(
                location: searchStart,
                length: length - searchStart
            )
            let found = haystack.range(
                of: needle,
                options: [.caseInsensitive],
                range: searchRange
            )
            guard found.location != NSNotFound, found.length > 0 else {
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
            // so the matched slice can differ from the needle in both bytes and
            // length. Stamping `text: needle` would make span.text disagree with
            // the [start, end) bytes and silently change the document's casing or
            // normalization form on restore. Using the matched slice keeps
            // span.text byte-identical to the source range.
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
