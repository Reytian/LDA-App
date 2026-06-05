//
//  Restorer.swift
//  LDACore
//
//  Pure deterministic restore. For every token in a Mapping, replace all
//  occurrences of that exact token string with its restored value, then scan
//  the result for any leftover token-shaped strings (orphans) the user may have
//  mangled while editing the tokenized document.
//
//  This deliberately does NOT use the position-window or fuzzy-context strategy
//  of the Python deanonymizer. Tokens are unique opaque brace-delimited strings,
//  so an exact whole-token substitution is both correct and deterministic. The
//  only shared contract with the rest of the system is the placeholder pattern,
//  which is reused from TokenGrammar so emit and restore never drift.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Pure deterministic restorer. No clock reads, no I/O, no fuzzy matching.
public enum Restorer {
    /// Restore a tokenized document back to its original surface values.
    ///
    /// Algorithm:
    /// 1. For every entry in `mapping.entries`, replace every exact occurrence
    ///    of the entry's token string with that entry's `value`. Because a token
    ///    is brace-delimited (for example "{PERSON_1}"), a literal whole-token
    ///    replacement cannot cross-replace a longer token: "{PERSON_1}" is not a
    ///    substring of "{PERSON_12}" once the closing brace is part of the match.
    ///    So a plain literal replacement of the full brace-delimited token is
    ///    already exact, and no longest-first ordering is required.
    /// 2. `restoredCount` is the total number of token occurrences replaced
    ///    across all entries.
    /// 3. After substitution, scan the result with
    ///    `TokenGrammar.placeholderPattern` for any leftover token-shaped
    ///    strings. Collect the unique matched strings, in first-seen order, into
    ///    `orphanTokens`. These are tokens that are not in the mapping, or that
    ///    survived because the user broke them while editing.
    ///
    /// - Parameters:
    ///   - text: The tokenized (and possibly user-edited) text.
    ///   - mapping: The token map produced during tokenization.
    /// - Returns: A `RestoreResult` with the restored text, the count of token
    ///   occurrences replaced, and any orphan tokens found afterwards.
    public static func restore(text: String, mapping: Mapping) -> RestoreResult {
        var working = text
        var restoredCount = 0

        // Step 1: exact whole-token substitution for every mapping entry.
        //
        // We count occurrences before replacing so restoredCount reflects the
        // number of token occurrences actually substituted, not merely the
        // number of distinct tokens. Replacement is literal (not regex), which
        // guarantees the brace-delimited token is matched exactly and never
        // interpreted as a pattern.
        for entry in mapping.entries.values {
            let token = entry.token
            if token.isEmpty {
                continue
            }
            let occurrences = countOccurrences(of: token, in: working)
            if occurrences == 0 {
                continue
            }
            working = working.replacingOccurrences(of: token, with: entry.value)
            restoredCount += occurrences
        }

        // Step 2: orphan guard. Scan the restored text for any remaining
        // token-shaped strings and collect the unique matches in first-seen
        // order. These are broken or unknown tokens for the user to review.
        let orphanTokens = collectOrphanTokens(in: working)

        return RestoreResult(
            text: working,
            restoredCount: restoredCount,
            orphanTokens: orphanTokens
        )
    }

    // MARK: - Helpers

    /// Count the number of non-overlapping occurrences of `needle` in `haystack`.
    ///
    /// Tokens are opaque and never overlap themselves in practice (the leading
    /// brace cannot recur inside a single token), but non-overlapping counting is
    /// the correct and safe semantics for literal replacement either way.
    private static func countOccurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else {
            return 0
        }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: [], range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }

    /// Scan `text` with the canonical placeholder pattern and return the unique
    /// matched token strings in first-seen order.
    ///
    /// Offsets are handled as UTF-16 code units because NSRegularExpression runs
    /// over the text as an NSString, matching the offset convention documented in
    /// CoreTypes.swift.
    private static func collectOrphanTokens(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: TokenGrammar.placeholderPattern
        ) else {
            return []
        }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        var seen = Set<String>()
        var ordered: [String] = []

        regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match = match else {
                return
            }
            let matched = nsText.substring(with: match.range)
            if seen.insert(matched).inserted {
                ordered.append(matched)
            }
        }

        return ordered
    }
}
