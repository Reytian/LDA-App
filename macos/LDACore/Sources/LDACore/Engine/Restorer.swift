//
//  Restorer.swift
//  LDACore
//
//  Pure deterministic restore. A single left-to-right pass over the tokenized
//  text finds every token-shaped string (using TokenGrammar.placeholderPattern),
//  substitutes each mapped token with its restored value, and records any
//  unmapped leftover token-shaped string (an orphan) the user may have mangled
//  while editing the tokenized document.
//
//  This deliberately does NOT use the position-window or fuzzy-context strategy
//  of the Python deanonymizer. It also deliberately does NOT iterate the mapping
//  dictionary and run a whole-string replacement per entry: that approach
//  re-scans text produced by earlier replacements, so a value that happens to
//  contain another entry's token cascades, and the unordered Dictionary.values
//  iteration makes the corruption nondeterministic across process runs. The
//  single forward scan emits substituted values into an output buffer and
//  advances the cursor past them, so an inserted value is never re-scanned. This
//  mirrors the already-correct DocxRedactor.replaceTokens and makes restoration
//  order-independent. The only shared contract with the rest of the system is the
//  placeholder pattern, reused from TokenGrammar so emit and restore never drift.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Pure deterministic restorer. No clock reads, no I/O, no fuzzy matching.
public enum Restorer {
    /// Restore a tokenized document back to its original surface values.
    ///
    /// Algorithm (a single left-to-right scan):
    /// 1. Build a token -> value lookup from `mapping.entries`.
    /// 2. Find every token-shaped string in the text with
    ///    `TokenGrammar.placeholderPattern`. For each match in document order,
    ///    copy the verbatim text since the previous match, then emit either the
    ///    mapped value (and increment `restoredCount`) or, when the token is not
    ///    in the mapping, the token verbatim while recording it as an orphan. The
    ///    cursor advances past each substitution, so an emitted value is never
    ///    re-scanned. This makes restoration order-independent and immune to a
    ///    value that contains another token, and it cannot cross-replace a longer
    ///    token because the grammar matches the full brace-delimited token
    ///    ("{PERSON_1}" is matched whole, not as a prefix of "{PERSON_12}").
    /// 3. `restoredCount` is the total number of token occurrences substituted.
    ///    `orphanTokens` holds the unique unmapped token-shaped strings in
    ///    first-seen order; these are tokens not in the mapping, or that survived
    ///    because the user broke them while editing.
    ///
    /// - Parameters:
    ///   - text: The tokenized (and possibly user-edited) text.
    ///   - mapping: The token map produced during tokenization.
    /// - Returns: A `RestoreResult` with the restored text, the count of token
    ///   occurrences replaced, and any orphan tokens found during the scan.
    public static func restore(text: String, mapping: Mapping) -> RestoreResult {
        // Token -> value lookup. mapping.entries is keyed by token already, but a
        // dedicated map keeps the lookup independent of the entry shape and skips
        // any empty-token entries defensively.
        var tokenToValue: [String: String] = [:]
        for entry in mapping.entries.values where !entry.token.isEmpty {
            tokenToValue[entry.token] = entry.value
        }

        guard let regex = try? NSRegularExpression(
            pattern: TokenGrammar.placeholderPattern
        ) else {
            // Without the grammar we cannot locate tokens; return the input
            // unchanged so we never corrupt the document.
            return RestoreResult(text: text, restoredCount: 0, orphanTokens: [])
        }

        // Offsets are UTF-16 code units because NSRegularExpression runs over the
        // text as an NSString, matching the offset convention documented in
        // CoreTypes.swift.
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: fullRange)

        var result = ""
        var cursor = 0
        var restoredCount = 0
        var seenOrphans = Set<String>()
        var orphanTokens: [String] = []

        for match in matches {
            let range = match.range

            // Copy the verbatim text between the previous match and this one.
            if range.location > cursor {
                result += nsText.substring(
                    with: NSRange(location: cursor, length: range.location - cursor)
                )
            }

            let token = nsText.substring(with: range)
            if let value = tokenToValue[token] {
                // Emit the restored value. The cursor advances past it below, so
                // this value is never re-scanned for further substitution.
                result += value
                restoredCount += 1
            } else {
                // Unmapped token-shaped string: leave it verbatim and report it as
                // an orphan for the user to review.
                result += token
                if seenOrphans.insert(token).inserted {
                    orphanTokens.append(token)
                }
            }

            cursor = range.location + range.length
        }

        // Copy any trailing verbatim text after the last match.
        if cursor < nsText.length {
            result += nsText.substring(from: cursor)
        }

        return RestoreResult(
            text: result,
            restoredCount: restoredCount,
            orphanTokens: orphanTokens
        )
    }
}
