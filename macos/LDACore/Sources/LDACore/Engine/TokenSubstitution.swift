//
//  TokenSubstitution.swift
//  LDACore
//
//  The single grammar-matched token scan used by every substitution path.
//
//  Why it is shared: Restorer.restore (text and companion surfaces) and
//  DocxRedactor.replaceTokens (per-run substitution inside word/document.xml)
//  had near-identical copies of this loop. Two copies of the rule that decides
//  what counts as a token, and of the rule that an UNMAPPED token is left
//  verbatim rather than blanked, is exactly the code that must not drift: a
//  divergence between them means the same document restores differently
//  depending on which surface it came back on.
//
//  Two invariants live here:
//
//   - The cursor advances PAST each substituted value, so a restored value is
//     never rescanned. Without that, a real value that happens to look like a
//     placeholder would be substituted again.
//   - An unmapped token-shaped string is copied through unchanged and reported.
//     It is never blanked and never guessed at; the caller decides how to
//     surface it. This is the same flag-don't-guess contract the placeholder
//     forensics scan follows.
//
//  Offsets are UTF-16 code units, because NSRegularExpression runs over the
//  text as an NSString. That matches the offset convention in CoreTypes.swift.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Grammar-matched token scanning with caller-supplied substitution.
public enum TokenSubstitution {

    /// The result of one scan.
    public struct Outcome: Equatable {
        /// The text with every resolved token replaced.
        public var text: String
        /// How many tokens were replaced.
        public var substitutedCount: Int
        /// Token-shaped strings the caller could not resolve, in first-seen
        /// order and deduplicated. Left verbatim in `text`.
        public var unmappedTokens: [String]

        public init(text: String, substitutedCount: Int, unmappedTokens: [String]) {
            self.text = text
            self.substitutedCount = substitutedCount
            self.unmappedTokens = unmappedTokens
        }
    }

    /// Scan `text` for tokens matching `regex` and replace each one with
    /// whatever `resolve` returns for it.
    ///
    /// - Parameters:
    ///   - text: the text to scan.
    ///   - regex: the token grammar. Callers pass a regex compiled from
    ///     TokenGrammar.placeholderPattern.
    ///   - resolve: maps a matched token to its replacement, or nil when the
    ///     token is unknown. A nil result leaves the token in place and records
    ///     it in `unmappedTokens`.
    public static func substitute(
        in text: String,
        matching regex: NSRegularExpression,
        resolve: (String) -> String?
    ) -> Outcome {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else {
            return Outcome(text: text, substitutedCount: 0, unmappedTokens: [])
        }

        var result = ""
        var cursor = 0
        var substitutedCount = 0
        var seenUnmapped = Set<String>()
        var unmappedTokens: [String] = []

        for match in matches {
            let range = match.range

            // Copy the verbatim text between the previous match and this one.
            if range.location > cursor {
                result += nsText.substring(
                    with: NSRange(location: cursor, length: range.location - cursor)
                )
            }

            let token = nsText.substring(with: range)
            if let replacement = resolve(token) {
                result += replacement
                substitutedCount += 1
            } else {
                result += token
                if seenUnmapped.insert(token).inserted {
                    unmappedTokens.append(token)
                }
            }

            // Advance past the match, so a substituted value is never rescanned.
            cursor = range.location + range.length
        }

        // Copy any trailing verbatim text after the last match.
        if cursor < nsText.length {
            result += nsText.substring(from: cursor)
        }

        return Outcome(
            text: result,
            substitutedCount: substitutedCount,
            unmappedTokens: unmappedTokens
        )
    }
}
