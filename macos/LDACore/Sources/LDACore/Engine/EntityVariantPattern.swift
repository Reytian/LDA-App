//
//  EntityVariantPattern.swift
//  LDACore
//
//  Builds the search pattern that finds every WHITESPACE VARIANT of a reported
//  value in the source: the same words with a different run of whitespace
//  between them. A model reports "Alice Smith" once; the document spells it
//  once exactly and once broken across a line ("Alice\nSmith"). The literal
//  locator anchored the exact hit only, the unanchored-value safeguard never
//  ran (it fired only on ZERO exact hits), and the wrapped occurrence survived
//  into the output while the result was called fully anchored.
//
//  The pattern keeps every non-whitespace piece of the value literal (escaped,
//  matched case-insensitively) and replaces each whitespace run with a BOUNDED
//  gap class: the Unicode White_Space set, which covers spaces, tabs, line and
//  page breaks (a form feed is how a PDF text layer marks a page break), the
//  no-break space, and the ideographic space U+3000. At a CJK-to-ASCII script
//  boundary the gap may be empty, which is CJKSpacing's rule and subsumes the
//  old tighten-and-retry fallback: "化工路口 98 号" anchors both "化工路口98号"
//  and "化工路口 98 号" in one pass. A space inside Latin text is real, so
//  "Alice Smith" never claims "AliceSmith".
//
//  Regex rules learned in this engine: adjacent unbounded whitespace quantifiers
//  are O(k^2) on long whitespace runs, and an ambiguous class backtracks
//  catastrophically. Every gap here is bounded and sits between two literal
//  pieces, so a failed candidate costs at most maximumGapLength retries.
//
//  What this pattern does not do: canonical equivalence. NSString's exact
//  search matches an NFC needle against an NFD source; ICU's regex engine does
//  not, so an accented name that is BOTH decomposed and wrapped stays
//  unanchored and is reported, never silently skipped.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Pure pattern construction for whitespace variants. No IO, no clock.
enum EntityVariantPattern {

    /// The longest whitespace run one gap bridges, in UTF-16 units (every
    /// scalar in the gap class is one unit). A line wrap with indentation or a
    /// page break with a form feed fits; a blank region of a page does not, so
    /// two words on either side of a column gap are never joined into a name.
    static let maximumGapLength = 12

    /// The Unicode White_Space set as a regex class: U+0009 through U+000D,
    /// space, next line, no-break space, ogham space mark, the U+2000 block,
    /// line and paragraph separators, narrow no-break space, medium
    /// mathematical space, and the ideographic space.
    static let gapClass =
        "[\\t\\n\\u000B\\u000C\\r \\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000]"

    /// The compiled variant matcher for `needle`, or nil when the needle admits
    /// no variant: no whitespace inside it and no CJK-to-ASCII boundary, so the
    /// exact search already finds every occurrence and the regex pass is
    /// skipped. The pattern is built from escaped literals and a fixed class,
    /// so compilation cannot fail; a nil from the compiler is treated as "no
    /// variant" rather than crashing an extraction.
    static func regex(for needle: String) -> NSRegularExpression? {
        guard let pattern = pattern(for: needle) else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// The pattern source for `needle`: escaped literal pieces joined by gaps.
    /// A gap replaces each whitespace run and is required there ({1,N}), except
    /// at a CJK-to-ASCII script boundary where it is optional ({0,N}); an
    /// optional gap is also inserted at every such boundary the needle spells
    /// tight, so a source that spaces its digits still anchors. Returns nil
    /// when no gap was emitted, meaning the needle has no variant.
    static func pattern(for needle: String) -> String? {
        var pieces: [String] = []
        var literal = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        var pendingWhitespace = false
        var gapCount = 0

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            pieces.append(NSRegularExpression.escapedPattern(for: String(literal)))
            literal = String.UnicodeScalarView()
        }

        for scalar in needle.unicodeScalars {
            if scalar.properties.isWhitespace {
                pendingWhitespace = true
                continue
            }
            if let previous {
                let boundary = CJKSpacing.isScriptBoundary(previous, scalar)
                if pendingWhitespace || boundary {
                    flushLiteral()
                    pieces.append(gap(optional: boundary))
                    gapCount += 1
                }
            }
            literal.append(scalar)
            previous = scalar
            pendingWhitespace = false
        }
        flushLiteral()

        guard gapCount > 0 else { return nil }
        return pieces.joined()
    }

    /// One bounded gap: optional at a script boundary, required elsewhere.
    private static func gap(optional: Bool) -> String {
        return "\(gapClass){\(optional ? 0 : 1),\(maximumGapLength)}"
    }
}
