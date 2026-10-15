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
        anchoring(forValue: value, type: type, in: text, source: source, confidence: confidence).spans
    }

    /// The two results of one search for a value: the spans the locator
    /// anchors, and the run-in places it refuses (see runInOccurrences).
    public struct Anchoring {
        /// Exactly what `spans(forValue:)` returns.
        public let spans: [Span]
        /// Exactly what `runInOccurrences(forValue:in:)` returns.
        public let runIns: [NSRange]
    }

    /// `spans(forValue:)` and `runInOccurrences(forValue:in:)` from a single
    /// search, for a caller that needs both. The anchoring is the search
    /// `spans(forValue:)` has always run, step for step: recording a refused
    /// run-in changes neither what is accepted nor where the search resumes.
    public static func anchoring(
        forValue value: String,
        type: EntityType,
        in text: String,
        source: DetectionSource = .llm,
        confidence: Double = 0.7
    ) -> Anchoring {
        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return Anchoring(spans: [], runIns: [])
        }

        let haystack = text as NSString
        let length = haystack.length
        guard (needle as NSString).length > 0, length > 0 else {
            return Anchoring(spans: [], runIns: [])
        }

        var scan = TwoEngineScan(needle: needle, text: text)
        var result: [Span] = []
        var runIns: [NSRange] = []
        var searchStart = 0

        while searchStart < length {
            guard let found = scan.nextHit(from: searchStart) else {
                break
            }

            let start = found.location
            let end = found.location + found.length

            // Reject matches whose edges land inside a Latin word (see the
            // word-boundary note above). Advance by one code unit, not past the
            // match: a later, boundary-valid occurrence may begin inside the
            // rejected range's tail.
            guard isWordBoundary(in: haystack, start: start, end: end) else {
                // A refused hit with the shape of a mention run into its
                // neighbour is kept as a run-in, never as a span. One that
                // overlaps the previous run-in is the same mention seen again.
                if isRunIn(in: haystack, start: start, end: end),
                   runIns.last.map({ start >= NSMaxRange($0) }) ?? true {
                    runIns.append(found)
                }
                searchStart = start + 1
                continue
            }

            // Capture the ACTUAL matched substring, not the needle: an exact hit
            // can differ from the needle in casing or normalization form, and a
            // variant hit differs in its whitespace. Stamping `text: needle`
            // would make span.text disagree with the [start, end) bytes and
            // silently change the document on restore.
            result.append(
                Span(
                    start: start,
                    end: end,
                    type: type,
                    text: haystack.substring(with: found),
                    source: source,
                    confidence: confidence,
                    priority: llmPriority
                )
            )

            // Advance past this match so the next search cannot overlap it.
            searchStart = end
        }

        // A run-in that an anchored span overlaps is already partly redacted;
        // protecting it would have to cut that span apart, so it is not
        // offered. Only a value that repeats inside itself can produce one.
        let free = runIns.filter { runIn in
            !result.contains { $0.start < NSMaxRange(runIn) && $0.end > runIn.location }
        }
        return Anchoring(spans: result, runIns: free)
    }

    // MARK: - Run-in occurrences

    /// Where `value` is still written in `text` although `spans(forValue:)`
    /// refuses to anchor it there: a mention that a letter or digit runs into.
    ///
    /// The word-boundary guard refuses any hit whose edge falls inside a Latin
    /// word. That keeps "Ann" from redacting part of "Annex", and it also
    /// refuses a real mention glued to its neighbour: "Jordan Lee2", where a
    /// footnote marker follows the name, or "byJordan Lee", where a PDF text
    /// layer lost a space. A refused hit is returned only when every edge the
    /// guard refuses has one of those two shapes:
    /// - a letter beside a digit ("Lee2", "3Acme"), or
    /// - a lowercase letter followed by an uppercase one, two words run
    ///   together ("byJordan", "LeeCEO").
    /// A hit inside an ordinary word has neither ("li" in "compliance", "Lee"
    /// in "Leeds", "Chan" in "Chancery", "Unit 5" in "Unit 57", "Apartment 5"
    /// in "Apartment 5A") and is never returned, so a caller that redacts
    /// these ranges cannot cut words apart.
    ///
    /// The search is the one `spans(forValue:)` runs, the case-insensitive
    /// exact search plus the whitespace variants, so a refused wrapped mention
    /// ("Jordan\nLee2") is found too. Hits the guard accepts are not returned:
    /// `spans(forValue:)` anchors those, and run-ins never become spans, so
    /// anchoring is unchanged. A value can have both: "Jordan Lee signed ...
    /// witnessed by Jordan Lee2" anchors the first mention and leaves the
    /// second as a run-in, which is a leak like a value that anchors nowhere.
    ///
    /// - Returns: UTF-16 ranges (NSRange-compatible), in document order, never
    ///   overlapping each other or an anchored span. Empty when value is blank
    ///   or no refused hit qualifies.
    public static func runInOccurrences(forValue value: String, in text: String) -> [NSRange] {
        anchoring(forValue: value, type: .person, in: text).runIns
    }

    // MARK: - Two-engine scan

    /// The exact search and the variant search over one text, each behind its
    /// own cursor. nextHit returns whichever hit starts first at or after the
    /// scan position, so the caller sees one ordered stream of candidates.
    private struct TwoEngineScan {
        private var exact: SearchCursor
        private var variant: SearchCursor

        init(needle: String, text: String) {
            let haystack = text as NSString
            let length = haystack.length
            exact = SearchCursor { from in
                // Case folding and canonical equivalence both allow a match
                // whose code-unit length differs from the needle's, so nothing
                // here assumes the needle length; the search only bounds on the
                // remaining haystack.
                let found = haystack.range(
                    of: needle,
                    options: [.caseInsensitive],
                    range: NSRange(location: from, length: length - from)
                )
                return found.location != NSNotFound && found.length > 0 ? found : nil
            }
            let pattern = EntityVariantPattern.regex(for: needle)
            variant = SearchCursor { from in
                guard let pattern else { return nil }
                let found = pattern.firstMatch(
                    in: text,
                    options: [],
                    range: NSRange(location: from, length: length - from)
                )?.range
                return found.map { $0.length > 0 ? $0 : nil } ?? nil
            }
        }

        mutating func nextHit(from: Int) -> NSRange? {
            return leftmost(exact.next(from: from), variant.next(from: from))
        }
    }

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

    /// True when every edge of the [start, end) match that isWordBoundary
    /// refuses reads as two tokens run together (see isRunInJoin). An edge the
    /// guard accepts needs no explanation.
    private static func isRunIn(in haystack: NSString, start: Int, end: Int) -> Bool {
        if start > 0 {
            let before = haystack.character(at: start - 1)
            let first = haystack.character(at: start)
            if SegmentPacker.isLatinWordChar(before) && SegmentPacker.isLatinWordChar(first)
                && !isRunInJoin(left: before, right: first, outsideIsLeft: true) {
                return false
            }
        }
        if end < haystack.length {
            let last = haystack.character(at: end - 1)
            let after = haystack.character(at: end)
            if SegmentPacker.isLatinWordChar(last) && SegmentPacker.isLatinWordChar(after)
                && !isRunInJoin(left: last, right: after, outsideIsLeft: false) {
                return false
            }
        }
        return true
    }

    /// True when two adjacent Latin word characters, one at the edge of the
    /// match and one just outside it, read as two tokens run together rather
    /// than as the inside of one word:
    /// - a digit outside, against a letter of the value: a footnote marker or
    ///   a list number glued to the name ("Lee2", "3Acme"). A digit of the
    ///   value against a letter outside is one token ("Apartment 5" in
    ///   "Apartment 5A", "5th"), and two digits are one number.
    /// - a lowercase letter followed by an uppercase one: a space lost before
    ///   a capitalised word ("byJordan", "LeeCEO"). Two letters in the same
    ///   case are one word.
    private static func isRunInJoin(left: unichar, right: unichar, outsideIsLeft: Bool) -> Bool {
        let outside = outsideIsLeft ? left : right
        let edge = outsideIsLeft ? right : left
        let outsideIsDigit = (0x30...0x39).contains(outside)
        let edgeIsDigit = (0x30...0x39).contains(edge)
        if outsideIsDigit || edgeIsDigit {
            return outsideIsDigit && !edgeIsDigit
        }
        guard let leftScalar = Unicode.Scalar(left), let rightScalar = Unicode.Scalar(right) else {
            return false
        }
        return leftScalar.properties.isLowercase && rightScalar.properties.isUppercase
    }
}
