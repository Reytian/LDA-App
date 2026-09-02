//
//  SpanSplitter.swift
//  LDACore
//
//  Splits detected spans whose surface text crosses a run break (a paragraph
//  newline, a w:br or w:cr line break, or a w:tab) into per-run sub-spans.
//
//  Why: those characters are synthetic in the DOCX imported text. They exist
//  in the text but in no w:t run, so a replacement whose surface carries one
//  cannot round-trip: the token would restore the full value (break included)
//  into a single run, pushing a literal newline or tab into w:t content while
//  the break element stayed behind, diverging from the original document
//  structure. Splitting at breaks gives each run-local part its own token,
//  which redacts and restores exactly within its own run structure.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Splits spans at run breaks so no replacement surface ever crosses a
/// paragraph boundary, a line break element, or a tab.
public enum SpanSplitter {

    /// The characters the DOCX parser synthesizes outside any run: line breaks
    /// (paragraph ends, w:br, w:cr) and the tab (w:tab).
    static let breakCharacters = CharacterSet.newlines.union(CharacterSet(charactersIn: "\t"))

    /// Returns the spans with every break-crossing span replaced by its
    /// per-run sub-spans. Whitespace-only parts are dropped. Spans without a
    /// break pass through unchanged. Offsets are UTF-16 code units into text,
    /// matching Span's convention; each sub-span's text is the exact source
    /// slice, so downstream tokenize/restore stays byte-identical.
    public static func splitAtBreaks(_ spans: [Span], in text: String) -> [Span] {
        var result: [Span] = []
        result.reserveCapacity(spans.count)

        for span in spans {
            let surface = span.text as NSString
            if surface.rangeOfCharacter(from: breakCharacters).location == NSNotFound {
                result.append(span)
                continue
            }

            var partStart: Int?
            func flush(upTo endOffset: Int) {
                guard let start = partStart else { return }
                partStart = nil
                let partText = surface.substring(
                    with: NSRange(location: start, length: endOffset - start)
                )
                guard !partText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                result.append(
                    Span(
                        start: span.start + start,
                        end: span.start + endOffset,
                        type: span.type,
                        text: partText,
                        source: span.source,
                        confidence: span.confidence,
                        priority: span.priority
                    )
                )
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
        }

        return result
    }
}
