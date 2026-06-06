//
//  Chunker.swift
//  LDACore
//
//  Splits a document into overlapping chunks sized for the v2 extraction model.
//  The split is structure aware: it prefers paragraph boundaries, then sentence
//  boundaries, before falling back to a hard grapheme-aligned cut, so chunks stay
//  near the target size without slicing through a paragraph, sentence, or
//  character.
//
//  Offset convention: TextChunk.startUTF16 is a UTF-16 code-unit offset into the
//  source text, NSRange-compatible, so located spans can be mapped back to the
//  original document without re-scanning. See CoreTypes.swift for the convention.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - TextChunk

/// One overlapping slice of the source text, carrying its UTF-16 start offset so
/// downstream locators can translate chunk-local matches back to document
/// offsets.
public struct TextChunk: Equatable, Sendable {
    /// The chunk's substring of the source text.
    public let text: String
    /// UTF-16 code-unit offset of this chunk's first character in the source.
    public let startUTF16: Int

    public init(text: String, startUTF16: Int) {
        self.text = text
        self.startUTF16 = startUTF16
    }
}

// MARK: - Chunker

/// Splits text into overlapping chunks. The overlap lets entities that straddle
/// a chunk boundary still be captured whole in at least one chunk.
public enum Chunker {
    /// The smallest overlap we ever apply. An entity straddling a boundary must be
    /// shorter than this to be guaranteed whole in some chunk.
    private static let minOverlapChars = 150

    /// Split text into overlapping chunks.
    ///
    /// The chunker walks the document left to right. For each chunk it aims for
    /// `targetChars` UTF-16 code units, then backs the end off to the nearest
    /// structural boundary at or before that point: a paragraph break first, then
    /// a single newline, then a sentence terminator, and finally a grapheme-
    /// aligned hard cut when no boundary is available. Consecutive chunks share an
    /// overlap so an entity crossing a boundary stays whole in at least one chunk.
    ///
    /// - Parameters:
    ///   - text: the source document text.
    ///   - targetChars: approximate chunk size in UTF-16 code units.
    ///   - overlapChars: how many code units consecutive chunks share. Raised to
    ///     at least 150 so a boundary-straddling entity is captured whole.
    /// - Returns: the chunks in document order. Each TextChunk.startUTF16 is the
    ///   chunk's UTF-16 offset in the original text.
    public static func chunk(
        _ text: String,
        targetChars: Int = 2000,
        overlapChars: Int = 350
    ) -> [TextChunk] {
        // Offsets are UTF-16 code units so located spans map back to the source
        // without re-scanning. NSString slicing keeps the math NSRange-compatible.
        let ns = text as NSString
        let total = ns.length
        if total == 0 {
            return []
        }

        // Guard against degenerate parameters: a non-positive target would loop
        // forever, and an overlap at or beyond the target would never advance.
        let target = max(1, targetChars)
        let requestedOverlap = max(overlapChars, minOverlapChars)
        let overlap = max(0, min(requestedOverlap, target - 1))

        // A single chunk covers everything when the text fits in one window.
        if total <= target {
            return [TextChunk(text: text, startUTF16: 0)]
        }

        var chunks: [TextChunk] = []
        var cursor = 0

        while cursor < total {
            let remaining = total - cursor

            // The tail of the document fits in one final chunk.
            if remaining <= target {
                let tail = ns.substring(with: NSRange(location: cursor, length: remaining))
                chunks.append(TextChunk(text: tail, startUTF16: cursor))
                break
            }

            // Find where this chunk should end. We aim for `target` code units but
            // back off to the nearest structural boundary at or before that point
            // so we do not split a paragraph, a sentence, or a grapheme.
            let hardEnd = cursor + target
            let chunkEnd = boundaryEnd(in: ns, lowerBound: cursor, upperBound: hardEnd)

            let body = ns.substring(with: NSRange(location: cursor, length: chunkEnd - cursor))
            chunks.append(TextChunk(text: body, startUTF16: cursor))

            // Advance, carrying the overlap tail of this chunk into the next so an
            // entity straddling the boundary is contained whole in at least one
            // chunk. Snap the next start onto a grapheme boundary so a chunk never
            // begins mid-character. Always advance at least one code unit.
            let desiredStart = max(cursor + 1, chunkEnd - overlap)
            cursor = graphemeAlignedStart(in: ns, near: desiredStart)
        }

        return chunks
    }

    // MARK: - Boundary selection

    /// Picks the best UTF-16 end offset for a chunk that begins at `lowerBound`
    /// and may extend up to `upperBound`. Prefers, in order: a paragraph break
    /// (double newline), then a single newline, then a sentence terminator, then a
    /// grapheme-aligned hard cut at `upperBound`. The returned offset is strictly
    /// greater than `lowerBound` so the loop always advances.
    private static func boundaryEnd(
        in ns: NSString,
        lowerBound: Int,
        upperBound: Int
    ) -> Int {
        let cap = min(upperBound, ns.length)

        // Do not accept a boundary in the first half of the window; a chunk that
        // ends almost immediately would make poor forward progress and produce
        // many tiny chunks. Require the boundary to land in the second half.
        let searchFloor = lowerBound + (cap - lowerBound) / 2

        // 1. Paragraph break: a double newline is the strongest structural signal.
        if let end = lastParagraphBreak(in: ns, from: searchFloor, to: cap, double: true) {
            return end
        }
        // 2. A single newline.
        if let end = lastParagraphBreak(in: ns, from: searchFloor, to: cap, double: false) {
            return end
        }
        // 3. A sentence terminator: ASCII '.', '?', '!' followed by whitespace, or
        //    a CJK full-width terminator which stands alone.
        if let end = lastSentenceBreak(in: ns, from: searchFloor, to: cap) {
            return end
        }
        // 4. No structural boundary in range: cut at the cap, aligned to a grapheme
        //    boundary so we never split a character.
        return graphemeAlignedStart(in: ns, near: cap)
    }

    /// Scans backward from `to` to `from` for a newline run. When `double` is
    /// true it requires a run of two or more newlines (a paragraph break) and
    /// returns the offset just past the run. When `double` is false it returns the
    /// offset just past any single newline. Returns nil when none is found.
    private static func lastParagraphBreak(
        in ns: NSString,
        from: Int,
        to: Int,
        double: Bool
    ) -> Int? {
        guard from < to else { return nil }
        var index = to - 1
        while index >= from {
            if isNewline(ns.character(at: index)) {
                // Measure the contiguous newline run ending at `index`.
                var runStart = index
                while runStart - 1 >= from && isNewline(ns.character(at: runStart - 1)) {
                    runStart -= 1
                }
                let runLength = index - runStart + 1
                if double {
                    if runLength >= 2 {
                        return index + 1
                    }
                } else {
                    return index + 1
                }
                // Skip past the measured run and keep scanning backward.
                index = runStart - 1
                continue
            }
            index -= 1
        }
        return nil
    }

    /// Scans backward for a sentence terminator and returns the offset just past
    /// it, consuming a single trailing space so the next chunk does not begin with
    /// leading whitespace. Recognizes ASCII '.', '?', '!' when followed by
    /// whitespace or the window edge (so "U.S.A." or "3.14" is not split), and the
    /// CJK full-width terminators U+3002, U+FF1F, U+FF01 which stand alone.
    /// Returns nil when none is found.
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
                // Full-width terminators need no trailing space; break right after.
                return index + 1
            }
            if ch == 0x2E || ch == 0x3F || ch == 0x21 {
                // ASCII '.', '?', '!'. A sentence end only when the next character
                // is whitespace or this is the window edge.
                let next = index + 1
                if next >= to {
                    return next
                }
                if isWhitespace(ns.character(at: next)) {
                    // Consume one trailing whitespace code unit.
                    return next + 1
                }
            }
            index -= 1
        }
        return nil
    }

    // MARK: - Grapheme alignment

    /// Returns an offset at or before `index` that sits on a grapheme-cluster
    /// boundary, so slicing there never splits a composed character or a surrogate
    /// pair. Clamped to a valid range within the string.
    private static func graphemeAlignedStart(in ns: NSString, near index: Int) -> Int {
        if index <= 0 {
            return 0
        }
        if index >= ns.length {
            return ns.length
        }
        let range = ns.rangeOfComposedCharacterSequence(at: index)
        // If `index` already starts a composed sequence, keep it. Otherwise back
        // up to the start of the sequence that contains it.
        if range.location == index {
            return index
        }
        return range.location
    }

    // MARK: - Character classification

    private static func isNewline(_ ch: unichar) -> Bool {
        // LF, CR, NEL, line separator, paragraph separator.
        return ch == 0x0A || ch == 0x0D || ch == 0x85 || ch == 0x2028 || ch == 0x2029
    }

    private static func isWhitespace(_ ch: unichar) -> Bool {
        if isNewline(ch) {
            return true
        }
        // Space, tab, no-break space, ideographic space.
        return ch == 0x20 || ch == 0x09 || ch == 0xA0 || ch == 0x3000
    }

    private static func isCJKTerminator(_ ch: unichar) -> Bool {
        // Ideographic full stop, full-width question mark, full-width exclamation.
        return ch == 0x3002 || ch == 0xFF1F || ch == 0xFF01
    }
}
