//
//  SpanSplitter.swift
//  LDACore
//
//  Splits detected spans whose surface text crosses a break (a paragraph
//  newline, a w:br or w:cr line break, or a w:tab) into per-part sub-spans.
//
//  Why, for DOCX: those characters are synthetic in the imported text. They
//  exist in the text but in no w:t run, so a replacement whose surface carries
//  one cannot round-trip: the token would restore the full value (break
//  included) into a single run, pushing a literal newline or tab into w:t
//  content while the break element stayed behind, diverging from the original
//  document structure.
//
//  Why, for plain text and Markdown: a replacement that swallows a newline
//  deletes a line. The redacted file comes back with one line fewer than the
//  original, and the value on the far side of the break is hidden inside a
//  placeholder named after the value on the near side.
//
//  Splitting at breaks gives each part its own token, which redacts and
//  restores exactly in place, and each part is re-typed from its own text so a
//  date a merged PHONE span reached across a line break is a DATE again.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Splits spans at breaks so no replacement surface ever crosses a paragraph
/// boundary, a line break element, or a tab.
public enum SpanSplitter {

    /// The characters the DOCX parser synthesizes outside any run, and the same
    /// characters that carry line structure in plain text: line breaks
    /// (paragraph ends, w:br, w:cr) and the tab (w:tab).
    static let breakCharacters = CharacterSet.newlines.union(CharacterSet(charactersIn: "\t"))

    /// Returns the spans with every break-crossing span replaced by its
    /// per-part sub-spans. Whitespace-only parts are dropped. Spans without a
    /// break pass through unchanged, type included. Offsets are UTF-16 code
    /// units into text, matching Span's convention; each sub-span's text is the
    /// exact source slice, so downstream tokenize/restore stays byte-identical.
    ///
    /// Each part's TYPE is re-derived from the part text alone. The parent's
    /// type describes the whole crossing surface, which is often not what
    /// either side is: SpanMerger absorbs a PHONE and a DATE separated only by
    /// a line break into one PHONE span, and copying that type down left the
    /// date half labelled a phone number in the token, in the pseudonym handed
    /// to the AI, and in the asterisk mask (which then leaks the year prefix).
    /// A part no deterministic detection claims keeps the parent's type, so
    /// re-typing never un-redacts anything.
    ///
    /// `source`, `confidence`, and `priority` stay the parent's: they describe
    /// where the detection came from and how its overlaps were already
    /// resolved, and nothing downstream of the split resolves overlaps again.
    public static func splitAtBreaks(_ spans: [Span], in text: String) -> [Span] {
        // One detector for the whole call. splitAtBreaks runs on every export,
        // so a part must not pay for a detector of its own.
        let engine = DeterministicEngine()
        var result: [Span] = []
        result.reserveCapacity(spans.count)

        for span in spans {
            let surface = span.text as NSString
            if surface.rangeOfCharacter(from: breakCharacters).location == NSNotFound {
                result.append(span)
                continue
            }

            for range in partRanges(in: surface) {
                let partText = surface.substring(with: range)
                result.append(
                    Span(
                        start: span.start + range.location,
                        end: span.start + range.location + range.length,
                        type: DominantEntityType.of(partText, engine: engine) ?? span.type,
                        text: partText,
                        source: span.source,
                        confidence: span.confidence,
                        priority: span.priority
                    )
                )
            }
        }

        return result
    }

    /// The first part a surface would be split into, or nil when the surface
    /// carries no break (nothing would be split) or holds no non-whitespace
    /// part at all.
    ///
    /// Callers that index by whole surface text (the sealed token chips) use
    /// this to recover a split value's first token: after a split the mapping
    /// holds the parts, never the crossing surface.
    public static func firstPart(of surface: String) -> String? {
        let ns = surface as NSString
        guard ns.rangeOfCharacter(from: breakCharacters).location != NSNotFound,
              let first = partRanges(in: ns).first else {
            return nil
        }
        return ns.substring(with: first)
    }

    /// The parts of a surface: the maximal stretches between break characters,
    /// with whitespace-only stretches dropped.
    private static func partRanges(in surface: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var partStart: Int?

        func flush(upTo endOffset: Int) {
            guard let start = partStart else { return }
            partStart = nil
            let range = NSRange(location: start, length: endOffset - start)
            let part = surface.substring(with: range)
            guard !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            ranges.append(range)
        }

        for offset in 0..<surface.length {
            // Break characters are all BMP scalars, so unpaired surrogate
            // halves (which fail Unicode.Scalar) never match.
            let unit = surface.character(at: offset)
            if let scalar = Unicode.Scalar(unit), breakCharacters.contains(scalar) {
                flush(upTo: offset)
            } else if partStart == nil {
                partStart = offset
            }
        }
        flush(upTo: surface.length)

        return ranges
    }
}
