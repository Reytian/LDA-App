//
//  SegmentPacker.swift
//  LDACore
//
//  Builds the text windows the LLM extraction pass actually sends to the model.
//
//  Why this exists: the previous pipeline ran Chunker (whose overlap made the
//  next chunk start mid-word) and then re-split every chunk into paragraph
//  segments. On a real 18-page contract that produced 48 model calls, re-scanned
//  23 percent of the text, and fed the model segments that began mid-word
//  ("nformation disclosed by ..."). The model then echoed clipped fragments such
//  as "laint" or "Associated Third" as entity values, which EntityLocator fanned
//  out across the whole document.
//
//  SegmentPacker walks the full document once and emits windows that:
//  - aim for `targetChars` UTF-16 code units per window (one model call each);
//  - end at the strongest structural boundary available in range: paragraph
//    break, then single newline, then sentence terminator, then plain
//    whitespace, then a grapheme-aligned hard cut only for pathological
//    whitespace-free runs;
//  - start on a word boundary, never mid-word (Latin script); CJK needs no word
//    alignment and stays grapheme-aligned;
//  - carry overlap ONLY where an entity could straddle the cut: none after a
//    paragraph break (entities do not span blank lines), a small tail after
//    newline/sentence/whitespace cuts, and a larger tail after a hard cut.
//
//  Windows are substrings of the source, so TextChunk.startUTF16 remains a real
//  offset into the document.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - SegmentPacker

/// Splits a document into word-aligned, structure-aware windows for the LLM
/// extraction pass. One window equals one model call.
public enum SegmentPacker {

    /// Overlap carried into the next window when a window ends inside a
    /// paragraph (newline, sentence, or whitespace cut). Sized to keep a
    /// wrapped multi-line entity (for example a street address broken across
    /// lines) whole in the following window.
    private static let softOverlapChars = 200

    /// Overlap carried into the next window after a forced hard cut in a
    /// whitespace-free run. Matches Chunker's historical minimum overlap.
    private static let hardOverlapChars = 350

    /// Split text into extraction windows.
    ///
    /// - Parameters:
    ///   - text: the source document text.
    ///   - targetChars: approximate window size in UTF-16 code units.
    /// - Returns: windows in document order. Each TextChunk.startUTF16 is the
    ///   window's UTF-16 offset in the source text. Whitespace-only windows are
    ///   dropped.
    public static func segments(
        of text: String,
        targetChars: Int = 2000
    ) -> [TextChunk] {
        let ns = text as NSString
        let total = ns.length
        if total == 0 {
            return []
        }

        let target = max(1, targetChars)
        if total <= target {
            return isBlank(ns, from: 0, to: total) ? [] : [TextChunk(text: text, startUTF16: 0)]
        }

        var windows: [TextChunk] = []
        var cursor = 0

        while cursor < total {
            let remaining = total - cursor
            if remaining <= target {
                appendWindow(ns, from: cursor, to: total, into: &windows)
                break
            }

            let hardEnd = cursor + target
            let boundary = boundaryEnd(in: ns, lowerBound: cursor, upperBound: hardEnd)
            appendWindow(ns, from: cursor, to: boundary.offset, into: &windows)

            cursor = nextStart(in: ns, after: boundary, windowStart: cursor)
        }

        return windows
    }

    // MARK: - Window emission

    /// Append the [from, to) slice as a window unless it is whitespace-only.
    private static func appendWindow(
        _ ns: NSString,
        from: Int,
        to: Int,
        into windows: inout [TextChunk]
    ) {
        guard to > from, !isBlank(ns, from: from, to: to) else { return }
        let body = ns.substring(with: NSRange(location: from, length: to - from))
        windows.append(TextChunk(text: body, startUTF16: from))
    }

    private static func isBlank(_ ns: NSString, from: Int, to: Int) -> Bool {
        var index = from
        while index < to {
            if !isWhitespace(ns.character(at: index)) {
                return false
            }
            index += 1
        }
        return true
    }

    // MARK: - Next-window start selection

    /// Where the next window begins, given how the previous window ended.
    ///
    /// - After a paragraph break: exactly at the boundary. An entity cannot
    ///   straddle a blank line, so no overlap is needed and no text is scanned
    ///   twice.
    /// - After a newline, sentence, or whitespace cut: back off by a small
    ///   overlap so a wrapped entity that straddles the cut is whole in the next
    ///   window, then advance to a word start so the window never begins
    ///   mid-word.
    /// - After a hard cut (whitespace-free run): back off by the larger overlap;
    ///   grapheme alignment is the only alignment possible.
    ///
    /// Always returns a position strictly greater than windowStart so the walk
    /// advances.
    private static func nextStart(
        in ns: NSString,
        after boundary: Boundary,
        windowStart: Int
    ) -> Int {
        let minimumProgress = windowStart + 1

        switch boundary.kind {
        case .paragraph:
            return max(boundary.offset, minimumProgress)
        case .newline, .sentence, .whitespace:
            let candidate = max(boundary.offset - softOverlapChars, minimumProgress)
            let aligned = wordAlignedStart(in: ns, near: candidate, notBeyond: boundary.offset)
            return max(aligned, minimumProgress)
        case .hardCut:
            let candidate = max(boundary.offset - hardOverlapChars, minimumProgress)
            return max(graphemeAlignedStart(in: ns, near: candidate), minimumProgress)
        }
    }

    /// Returns a position at or after `near` that does not begin mid-word:
    /// if `near` sits inside a Latin word run, advances to the position just
    /// past the end of that run's next whitespace (that is, the start of the
    /// next word). Capped at `notBeyond`; when no word start exists before the
    /// cap, the cap itself is returned (zero overlap, still aligned because the
    /// previous window ended on a structural boundary).
    ///
    /// CJK and other non-Latin scripts are not treated as word characters, so a
    /// position between CJK characters is accepted as-is (grapheme-aligned).
    private static func wordAlignedStart(
        in ns: NSString,
        near: Int,
        notBeyond cap: Int
    ) -> Int {
        var position = graphemeAlignedStart(in: ns, near: near)
        guard position > 0, position < cap else {
            return min(max(position, 0), cap)
        }

        // Mid-word means: the character before and the character at the position
        // are both Latin word characters. Advance past the current word run.
        if isLatinWordChar(ns.character(at: position - 1)) && isLatinWordChar(ns.character(at: position)) {
            while position < cap && isLatinWordChar(ns.character(at: position)) {
                position += 1
            }
        }
        return graphemeAlignedStart(in: ns, near: min(position, cap))
    }

    // MARK: - Boundary selection

    /// How a window's end was chosen. Drives the overlap policy in nextStart.
    private enum BoundaryKind {
        case paragraph
        case newline
        case sentence
        case whitespace
        case hardCut
    }

    private struct Boundary {
        let offset: Int
        let kind: BoundaryKind
    }

    /// Picks the best UTF-16 end offset for a window that begins at `lowerBound`
    /// and may extend up to `upperBound`. Prefers, in order: a paragraph break
    /// (run of two or more newlines), a single newline, a sentence terminator,
    /// any whitespace, then a grapheme-aligned hard cut. The boundary must land
    /// in the second half of the window so the walk keeps good forward progress.
    private static func boundaryEnd(
        in ns: NSString,
        lowerBound: Int,
        upperBound: Int
    ) -> Boundary {
        let cap = min(upperBound, ns.length)
        let searchFloor = lowerBound + (cap - lowerBound) / 2

        if let end = lastNewlineRun(in: ns, from: searchFloor, to: cap, requireDouble: true) {
            return Boundary(offset: end, kind: .paragraph)
        }
        if let end = lastNewlineRun(in: ns, from: searchFloor, to: cap, requireDouble: false) {
            return Boundary(offset: end, kind: .newline)
        }
        if let end = lastSentenceBreak(in: ns, from: searchFloor, to: cap) {
            return Boundary(offset: end, kind: .sentence)
        }
        if let end = lastWhitespace(in: ns, from: searchFloor, to: cap) {
            return Boundary(offset: end, kind: .whitespace)
        }
        return Boundary(offset: graphemeAlignedStart(in: ns, near: cap), kind: .hardCut)
    }

    /// Scans backward from `to` toward `from` for a newline run. When
    /// `requireDouble` is true only a run of two or more LOGICAL newlines
    /// qualifies (a paragraph break). A CRLF pair counts as one logical
    /// newline: without that, every single line break in a CRLF document
    /// would masquerade as a paragraph break and the next window would get no
    /// straddle-protection overlap. Returns the offset just past the run, or
    /// nil.
    private static func lastNewlineRun(
        in ns: NSString,
        from: Int,
        to: Int,
        requireDouble: Bool
    ) -> Int? {
        guard from < to else { return nil }
        var index = to - 1
        while index >= from {
            if isNewline(ns.character(at: index)) {
                var runStart = index
                while runStart - 1 >= from && isNewline(ns.character(at: runStart - 1)) {
                    runStart -= 1
                }
                if !requireDouble || logicalNewlineCount(in: ns, from: runStart, through: index) >= 2 {
                    return index + 1
                }
                index = runStart - 1
                continue
            }
            index -= 1
        }
        return nil
    }

    /// Counts logical newlines in the code-unit run [from, through], folding
    /// each CR+LF pair into a single logical newline.
    private static func logicalNewlineCount(in ns: NSString, from: Int, through: Int) -> Int {
        var count = 0
        var index = from
        while index <= through {
            if ns.character(at: index) == 0x0D, index + 1 <= through, ns.character(at: index + 1) == 0x0A {
                index += 2
            } else {
                index += 1
            }
            count += 1
        }
        return count
    }

    /// Scans backward for a sentence terminator and returns the offset just past
    /// it (consuming one trailing space for ASCII terminators). Recognizes ASCII
    /// '.', '?', '!' followed by whitespace or the window edge, and the CJK
    /// full-width terminators which stand alone. Returns nil when none is found.
    private static func lastSentenceBreak(
        in ns: NSString,
        from: Int,
        to: Int
    ) -> Int? {
        guard from < to else { return nil }
        var index = to - 1
        while index >= from {
            let ch = ns.character(at: index)
            if isCJKTerminator(ch) {
                return index + 1
            }
            if ch == 0x2E || ch == 0x3F || ch == 0x21 {
                let next = index + 1
                if next >= to {
                    return next
                }
                if isWhitespace(ns.character(at: next)) {
                    return next + 1
                }
            }
            index -= 1
        }
        return nil
    }

    /// Scans backward for any whitespace and returns the offset just past it.
    /// This tier makes true hard cuts possible only in whitespace-free runs.
    private static func lastWhitespace(
        in ns: NSString,
        from: Int,
        to: Int
    ) -> Int? {
        guard from < to else { return nil }
        var index = to - 1
        while index >= from {
            if isWhitespace(ns.character(at: index)) {
                return index + 1
            }
            index -= 1
        }
        return nil
    }

    // MARK: - Grapheme alignment

    /// Returns an offset at or before `index` on a grapheme-cluster boundary so
    /// slicing never splits a composed character or a surrogate pair.
    private static func graphemeAlignedStart(in ns: NSString, near index: Int) -> Int {
        if index <= 0 {
            return 0
        }
        if index >= ns.length {
            return ns.length
        }
        let range = ns.rangeOfComposedCharacterSequence(at: index)
        if range.location == index {
            return index
        }
        return range.location
    }

    // MARK: - Character classification

    /// True for characters that form Latin-script words: ASCII letters and
    /// digits plus Latin-1 Supplement and Latin Extended letters. CJK is
    /// intentionally excluded: CJK text has no word delimiters, so word
    /// alignment does not apply there.
    static func isLatinWordChar(_ ch: unichar) -> Bool {
        if (0x30...0x39).contains(ch) { return true }   // 0-9
        if (0x41...0x5A).contains(ch) { return true }   // A-Z
        if (0x61...0x7A).contains(ch) { return true }   // a-z
        if (0xC0...0x24F).contains(ch) && ch != 0xD7 && ch != 0xF7 { return true }
        return false
    }

    private static func isNewline(_ ch: unichar) -> Bool {
        return ch == 0x0A || ch == 0x0D || ch == 0x85 || ch == 0x2028 || ch == 0x2029
    }

    private static func isWhitespace(_ ch: unichar) -> Bool {
        if isNewline(ch) {
            return true
        }
        return ch == 0x20 || ch == 0x09 || ch == 0xA0 || ch == 0x3000
    }

    private static func isCJKTerminator(_ ch: unichar) -> Bool {
        return ch == 0x3002 || ch == 0xFF1F || ch == 0xFF01
    }
}
