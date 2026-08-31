//
//  PseudonymSeamGuard.swift
//  LDACore
//
//  Seam-aware uniqueness for the literal substitution styles.
//
//  The pseudonym uniqueness contract is that every literal occurrence of a
//  replacement in the redacted document is a substitution site, which is what
//  lets Restorer's literal scan substitute blindly. The mint-time checks that
//  establish it (used replacements, reserved token literals, the document and
//  its companions) all read the ORIGINAL text. Restore reads the TOKENIZED
//  text, and those two views disagree at every seam: where an emitted
//  replacement meets the document text that follows it, the join can spell a
//  DIFFERENT replacement that was never emitted there.
//
//  Concretely, the Latin company scheme runs Company A .. Company Z and then
//  Company AA, so a document holding twenty seven companies mints Company A
//  first and Company AA last. If the first company is followed in the source
//  by the letter A, the redacted text reads "Company AA", and the
//  longest-match-wins literal scan restores the twenty seventh company over
//  the first one and eats the adjacent letter. Neither replacement occurs in
//  the natural text, so every pre-existing check passes.
//
//  This guard closes that shape in both mint orders:
//  - renderProvisional gives the mint loop the document as the restore scan
//    will see it, so a candidate that the already-emitted seams already spell
//    is rejected (the longer replacement minted after the shorter one).
//  - completesLongerReplacement rejects a candidate that is a strict prefix
//    of a replacement already in use whose remaining tail is exactly what
//    follows one of the candidate's own sites (the shorter replacement minted
//    after the longer one).
//
//  Both rules only ever reject candidates that the finite document spells, so
//  the generator's unbounded candidate sequence always escapes them.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Seam-aware checks over the document the literal restore scan will read.
enum PseudonymSeamGuard {

    /// A rendering of the document part way through minting, plus where each
    /// span's emitted piece landed in it.
    struct ProvisionalDocument {
        /// The document as the restore scan will see it: assigned surfaces
        /// rendered as their replacement, everything else verbatim.
        let text: String
        /// One entry per input span, in the order the spans were given. The
        /// range locates that span's piece in `text` in UTF-16 offsets, and
        /// is nil for a span that was skipped as out of order.
        let pieceRanges: [NSRange?]
    }

    /// Render the document as it currently stands.
    ///
    /// A span whose surface text already has a replacement renders as that
    /// replacement; every other span renders as its own surface text, which
    /// is what the original document already held there. The walk mirrors
    /// Tokenizer's emit walk exactly, so the rendering of a fully assigned
    /// span set is byte-identical to the tokenized output.
    ///
    /// - Parameters:
    ///   - text: the original document text.
    ///   - spans: accepted spans, sorted by start and non-overlapping (the
    ///     shape Tokenizer's accept step produces). An out-of-order span is
    ///     skipped and reported as a nil piece range.
    ///   - replacementBySurface: surface text to replacement, for the
    ///     surfaces decided so far.
    static func renderProvisional(
        text: String,
        spans: [Span],
        replacementBySurface: [String: String]
    ) -> ProvisionalDocument {
        // Slicing goes through NSString rather than
        // String.Index(utf16Offset:in:), which walks from the start of the
        // string on every call. The mint loop renders once per surface, so an
        // offset walk per span would make tokenization quadratic in the span
        // count on a document with many entities.
        let nsText = text as NSString
        let utf16Count = nsText.length
        var pieces: [String] = []
        var pieceRanges: [NSRange?] = []
        var cursor = 0
        var renderedLength = 0

        for span in spans {
            guard span.start >= cursor, span.end <= utf16Count else {
                pieceRanges.append(nil)
                continue
            }
            if span.start > cursor {
                let gap = nsText.substring(
                    with: NSRange(location: cursor, length: span.start - cursor)
                )
                pieces.append(gap)
                renderedLength += gap.utf16.count
            }
            let piece = replacementBySurface[span.text]
                ?? nsText.substring(
                    with: NSRange(location: span.start, length: span.end - span.start)
                )
            pieces.append(piece)
            pieceRanges.append(
                NSRange(location: renderedLength, length: piece.utf16.count)
            )
            renderedLength += piece.utf16.count
            cursor = span.end
        }

        if cursor < utf16Count {
            pieces.append(nsText.substring(from: cursor))
        }

        return ProvisionalDocument(text: pieces.joined(), pieceRanges: pieceRanges)
    }

    /// True when emitting `candidate` for `surface` would be swallowed by a
    /// longer replacement already in use.
    ///
    /// The danger is a replacement that starts with the whole candidate: at
    /// the candidate's own site the restore scan sees the candidate followed
    /// by the document text, and if that text opens with the longer
    /// replacement's remaining tail then the longer one matches at the site
    /// and wins. The site would restore to the wrong entity and swallow the
    /// document characters that completed it.
    ///
    /// A replacement that merely CONTAINS the candidate elsewhere is
    /// harmless: at a candidate site the scan starts at the site, so only a
    /// replacement sharing the site's start position can outrank it.
    static func completesLongerReplacement(
        candidate: String,
        surface: String,
        spans: [Span],
        document: ProvisionalDocument,
        replacements: Set<String>
    ) -> Bool {
        let longer = replacements.filter {
            $0.count > candidate.count && $0.hasPrefix(candidate)
        }
        guard !longer.isEmpty else {
            return false
        }

        let rendered = document.text as NSString
        for (index, span) in spans.enumerated() where span.text == surface {
            guard index < document.pieceRanges.count,
                  let range = document.pieceRanges[index] else {
                continue
            }
            // The text that follows this site is the same whether the piece
            // currently holds the surface or the candidate, so the seam can
            // be read off the rendering as it stands.
            let tailStart = range.location + range.length
            for replacement in longer {
                let tail = String(replacement.dropFirst(candidate.count))
                let tailLength = tail.utf16.count
                guard tailStart + tailLength <= rendered.length else {
                    continue
                }
                let following = rendered.substring(
                    with: NSRange(location: tailStart, length: tailLength)
                )
                if following == tail {
                    return true
                }
            }
        }
        return false
    }
}
