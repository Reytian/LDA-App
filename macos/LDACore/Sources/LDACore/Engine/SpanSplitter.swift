//
//  SpanSplitter.swift
//  LDACore
//
//  Splits detected spans whose surface text crosses a line break into
//  per-line sub-spans.
//
//  Why: the DOCX paragraph newline is synthetic. It exists in the imported
//  text but in no w:t run, so a replacement whose surface carries it cannot
//  round-trip: the token would restore the full value (newline included)
//  into a single run, pushing a literal newline into w:t content and
//  diverging from the original document structure. Splitting at line breaks
//  gives each paragraph-local part its own token, which redacts and restores
//  exactly within its own run structure.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Splits spans at line breaks so no replacement surface ever crosses a
/// paragraph boundary.
public enum SpanSplitter {

    /// Returns the spans with every line-break-crossing span replaced by its
    /// per-line sub-spans. Whitespace-only parts are dropped. Spans without a
    /// line break pass through unchanged. Offsets are UTF-16 code units into
    /// text, matching Span's convention; each sub-span's text is the exact
    /// source slice, so downstream tokenize/restore stays byte-identical.
    public static func splitAtLineBreaks(_ spans: [Span], in text: String) -> [Span] {
        var result: [Span] = []
        result.reserveCapacity(spans.count)

        for span in spans {
            let surface = span.text as NSString
            if surface.rangeOfCharacter(from: .newlines).location == NSNotFound {
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
                // Line-break characters are all BMP scalars, so unpaired
                // surrogate halves (which fail Unicode.Scalar) never match.
                let unit = surface.character(at: offset)
                if let scalar = Unicode.Scalar(unit), CharacterSet.newlines.contains(scalar) {
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
