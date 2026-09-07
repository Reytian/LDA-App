//
//  MarkdownTokenDecode.swift
//  LDACore
//
//  The Markdown-escaped spelling of an exact token, in the two shapes the
//  engine needs it.
//
//  An AI answering in Markdown escapes underscores, so "{PERSON_1}" comes back
//  as "{PERSON\_1}". Restoration decodes that spelling before it scans, which
//  is right: it is a well-defined encoding of the exact token, not a guess.
//  But reservation and seam verification used to read the RAW text, so the
//  escaped spelling was invisible to both. A token minted for one document
//  could equal the DECODED form of a literal sitting in another, and the
//  literal then restored to the entity value with no seam, orphan or
//  ambiguity reported (R6).
//
//  Two callers, two shapes:
//
//  - Reservation needs the SET of token strings restoration will read, raw
//    spellings and decoded spellings together (SourceTokenLiterals).
//  - Verification needs the decoded text plus a way back: it computes restore
//    sites where restoration will compute them, then maps each site to the
//    original offsets the emitted pieces are recorded in. The map is per
//    UTF-16 unit, the same shape PdfImporter.normalizeWhitespace uses, because
//    guessing the shift instead would put a site on the wrong piece.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - MarkdownTokenDecode

/// Decodes Markdown-escaped exact tokens, optionally keeping an offset map
/// back to the original text. Pure: no clock, no IO.
enum MarkdownTokenDecode {

    /// A token whose underscore is Markdown-escaped: {TYPE\_N}. The single
    /// definition both the plain decode and the mapped decode use, so the two
    /// can never disagree about what counts as an escaped token.
    static let escapedTokenPattern = #"\{([A-Z][A-Z0-9]*)\\_(\d+)\}"#

    /// A decoded text plus, for each UTF-16 code unit of it, the UTF-16 index
    /// that unit came from in the original.
    struct Decoded {
        /// The text with every escaped token rewritten to its exact form.
        let text: String
        /// One entry per UTF-16 unit of `text`. The removed backslash simply
        /// has no decoded unit, so the map is strictly increasing.
        let originalIndexes: [Int]
        /// UTF-16 length of the text this was decoded from.
        let originalLength: Int

        /// True when the per-unit invariant holds. A caller that maps offsets
        /// must check this and report that it could not verify rather than
        /// compare offsets that would be fiction.
        var isConsistent: Bool { originalIndexes.count == (text as NSString).length }

        /// The original range the decoded range covers, or nil when the range
        /// is out of bounds.
        ///
        /// The decoded range's first and last units are mapped, and the span
        /// between them is taken whole: that is exactly the stretch of
        /// original text the decoded stretch was built from, escape
        /// backslashes included.
        func originalRange(of decoded: NSRange) -> NSRange? {
            guard decoded.location >= 0,
                  decoded.length >= 0,
                  decoded.location + decoded.length <= originalIndexes.count else {
                return nil
            }
            guard decoded.length > 0 else {
                let start = decoded.location < originalIndexes.count
                    ? originalIndexes[decoded.location]
                    : originalLength
                return NSRange(location: start, length: 0)
            }
            let start = originalIndexes[decoded.location]
            let lastUnit = originalIndexes[decoded.location + decoded.length - 1]
            return NSRange(location: start, length: lastUnit + 1 - start)
        }
    }

    /// The text with every Markdown-escaped exact token decoded.
    ///
    /// Deliberately does NOT build the offset map. This runs on every restore
    /// and on every reservation scan, where a per-unit map of a whole document
    /// would be pure waste. The two paths share `escapedTokenPattern` and
    /// MarkdownTokenDecodeTests pins them to the same output on the same
    /// inputs, so they cannot drift.
    static func decodedText(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: escapedTokenPattern) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: "{$1_$2}"
        )
    }

    /// Decode `text` and keep the per-unit map back to it.
    static func decode(_ text: String) -> Decoded {
        let source = text as NSString
        guard let regex = try? NSRegularExpression(pattern: escapedTokenPattern) else {
            return identity(source)
        }
        let matches = regex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else {
            return identity(source)
        }

        var output = ""
        var indexes: [Int] = []
        indexes.reserveCapacity(source.length)
        var cursor = 0

        for match in matches {
            guard match.numberOfRanges > 2, match.range(at: 1).location != NSNotFound else {
                continue
            }
            appendVerbatim(
                NSRange(location: cursor, length: match.range.location - cursor),
                of: source,
                to: &output,
                indexes: &indexes
            )
            // The escape backslash sits immediately after the TYPE capture and
            // immediately before the underscore, so dropping that one unit is
            // the whole decode of this token.
            let type = match.range(at: 1)
            let backslash = type.location + type.length
            for unit in match.range.location..<(match.range.location + match.range.length)
            where unit != backslash {
                output += source.substring(with: NSRange(location: unit, length: 1))
                indexes.append(unit)
            }
            cursor = match.range.location + match.range.length
        }
        appendVerbatim(
            NSRange(location: cursor, length: source.length - cursor),
            of: source,
            to: &output,
            indexes: &indexes
        )

        return Decoded(text: output, originalIndexes: indexes, originalLength: source.length)
    }

    /// Copy a stretch of untouched text and its identity offsets.
    ///
    /// Every boundary here abuts an ASCII brace of a matched token or an end
    /// of the string, so the slice can never split a surrogate pair.
    private static func appendVerbatim(
        _ range: NSRange,
        of source: NSString,
        to output: inout String,
        indexes: inout [Int]
    ) {
        guard range.length > 0 else { return }
        output += source.substring(with: range)
        for unit in range.location..<(range.location + range.length) {
            indexes.append(unit)
        }
    }

    /// The nothing-was-escaped case: decoded text is the original text and
    /// every decoded offset is its own original offset.
    private static func identity(_ source: NSString) -> Decoded {
        return Decoded(
            text: source as String,
            originalIndexes: Array(0..<source.length),
            originalLength: source.length
        )
    }
}

// MARK: - SourceTokenLiterals

/// Every token-shaped literal a text already contains, in every spelling
/// restoration will read it in.
enum SourceTokenLiterals {

    /// Scan `text` for token-shaped literals already present, in the raw text
    /// AND in its Markdown-decoded form.
    ///
    /// Returns the distinct matched strings in their EXACT spelling (for
    /// example "{PERSON_1}"), because a minted token is compared against them
    /// by string equality: a token minted equal to any of these would be
    /// byte-identical to a literal the user wrote, and restoration would
    /// overwrite that literal with an entity value.
    ///
    /// The decoded pass is what makes an escaped literal count. Restoration
    /// decodes "{PERSON\_1}" to "{PERSON_1}" before it scans, so minting
    /// "{PERSON_1}" while that escaped literal sits in this text or a
    /// companion is the same collision as the plain spelling (R6).
    ///
    /// Pure: reads only the in-memory text. NSRegularExpression runs over the
    /// text as an NSString, matching the UTF-16 offset convention used
    /// elsewhere.
    static func literals(in text: String) -> Set<String> {
        var literals = matches(in: text)
        let decoded = MarkdownTokenDecode.decodedText(text)
        if decoded != text {
            literals.formUnion(matches(in: decoded))
        }
        return literals
    }

    /// The exact grammar tokens in one text, using the shared
    /// `TokenGrammar.placeholderPattern` so emit and restore never drift.
    private static func matches(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(
            pattern: TokenGrammar.placeholderPattern
        ) else {
            return []
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var found = Set<String>()
        regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match = match else {
                return
            }
            found.insert(nsText.substring(with: match.range))
        }
        return found
    }
}
