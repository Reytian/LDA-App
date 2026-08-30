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
    ///   occurrences replaced, any orphan tokens found during the scan, and any
    ///   near-miss suspect placeholders found by the forensics scan.
    public static func restore(text: String, mapping: Mapping) -> RestoreResult {
        // The mapping knows its own style, so restore dispatches on it: the
        // token grammar scan for .token (byte-identical to the historical
        // behavior), the literal replacement scan for the styles whose
        // replacements are ordinary strings.
        switch mapping.style {
        case .token:
            return restoreTokenStyle(text: text, mapping: mapping)
        case .pseudonym, .asterisk:
            return restoreLiteralStyle(text: text, mapping: mapping)
        }
    }

    /// The historical token-grammar restore. See restore(text:mapping:).
    private static func restoreTokenStyle(text: String, mapping: Mapping) -> RestoreResult {
        // Decode Markdown-escaped underscores inside otherwise exact tokens
        // ("{PERSON\_1}" is the exact token, Markdown-encoded) so a Markdown
        // round-trip through an external AI restores cleanly. This is a
        // deterministic decode, not a guess; genuinely mangled placeholders are
        // handled by the suspect scan below, which only ever flags.
        let text = PlaceholderForensics.decodeMarkdownEscapedTokens(in: text)

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

        // Forensics pass: find near-miss placeholder shapes (an external AI may
        // have swapped brackets, dropped a brace, changed case, or stripped the
        // braces). Suspects are flagged for the user and never substituted. The
        // scan runs over the decoded INPUT text, where mangled shapes still sit
        // in their original form.
        let suspects = PlaceholderForensics.suspects(in: text, mapping: mapping)

        return RestoreResult(
            text: result,
            restoredCount: restoredCount,
            orphanTokens: orphanTokens,
            suspectPlaceholders: suspects
        )
    }

    // MARK: - Literal styles (pseudonym, asterisk)

    /// Restore for the styles whose replacements are ordinary strings.
    ///
    /// A single left-to-right pass substitutes every literal occurrence of a
    /// mapping replacement with its original value. At each position the
    /// longest matching replacement wins (a pseudonym may be a prefix of a
    /// longer one), an emitted value is never re-scanned, and the pass is
    /// deterministic regardless of dictionary order.
    ///
    /// Report semantics per the style contract:
    /// - restoredCount counts substituted occurrences.
    /// - orphanTokens lists mapping replacements that were never substituted
    ///   (the edited text no longer contains them).
    /// - ambiguousReplacements lists replacements shared by two or more
    ///   entities (asterisk collisions). Their sites are left verbatim,
    ///   never guessed.
    /// - suspectPlaceholders stays empty: there is no token grammar to
    ///   mangle in these styles.
    private static func restoreLiteralStyle(text: String, mapping: Mapping) -> RestoreResult {
        // replacement -> the distinct original values behind it. Entry keys
        // are visited in sorted order so value order is deterministic.
        var valuesByReplacement: [String: [String]] = [:]
        for key in mapping.entries.keys.sorted() {
            guard let entry = mapping.entries[key], !entry.token.isEmpty else { continue }
            if !(valuesByReplacement[entry.token]?.contains(entry.value) ?? false) {
                valuesByReplacement[entry.token, default: []].append(entry.value)
            }
        }
        let ambiguous = Set(
            valuesByReplacement.filter { $0.value.count > 1 }.map { $0.key }
        )

        let nsText = text as NSString

        // Collect every literal occurrence of every replacement.
        struct LiteralMatch {
            let range: NSRange
            let replacement: String
        }
        var found: [LiteralMatch] = []
        for replacement in valuesByReplacement.keys {
            var searchLocation = 0
            while searchLocation < nsText.length {
                let range = nsText.range(
                    of: replacement,
                    options: [.literal],
                    range: NSRange(location: searchLocation, length: nsText.length - searchLocation)
                )
                guard range.location != NSNotFound, range.length > 0 else { break }
                found.append(LiteralMatch(range: range, replacement: replacement))
                searchLocation = range.location + range.length
            }
        }

        // Earliest position first; at the same position the longest
        // replacement wins; ties break on the string for determinism.
        found.sort { lhs, rhs in
            if lhs.range.location != rhs.range.location {
                return lhs.range.location < rhs.range.location
            }
            if lhs.range.length != rhs.range.length {
                return lhs.range.length > rhs.range.length
            }
            return lhs.replacement < rhs.replacement
        }

        var result = ""
        var cursor = 0
        var restoredCount = 0
        var substituted = Set<String>()
        var ambiguousSeen = Set<String>()
        var ambiguousReported: [String] = []

        for match in found {
            // A match starting before the cursor overlaps an accepted match
            // (a shorter replacement nested in a longer one) and is skipped.
            guard match.range.location >= cursor else { continue }

            if match.range.location > cursor {
                result += nsText.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
            }

            if ambiguous.contains(match.replacement) {
                // Two or more entities share this masked form. Restoring one
                // of them would be a guess; leave the site verbatim and flag.
                result += nsText.substring(with: match.range)
                if ambiguousSeen.insert(match.replacement).inserted {
                    ambiguousReported.append(match.replacement)
                }
            } else if let value = valuesByReplacement[match.replacement]?.first {
                result += value
                restoredCount += 1
                substituted.insert(match.replacement)
            } else {
                result += nsText.substring(with: match.range)
            }

            cursor = match.range.location + match.range.length
        }

        if cursor < nsText.length {
            result += nsText.substring(from: cursor)
        }

        // Mapping replacements that never substituted anywhere: the edited
        // text no longer contains them (or a longer replacement shadowed
        // every occurrence). Ambiguity is reported separately above.
        let orphans = valuesByReplacement.keys
            .filter { !substituted.contains($0) && !ambiguousSeen.contains($0) }
            .sorted()

        return RestoreResult(
            text: result,
            restoredCount: restoredCount,
            orphanTokens: orphans,
            suspectPlaceholders: [],
            ambiguousReplacements: ambiguousReported
        )
    }

    /// The unambiguous replacement -> value map for a literal-style mapping:
    /// every replacement carried by exactly one distinct value. Ambiguous
    /// replacements (asterisk collisions) are excluded so a caller doing its
    /// own substitution (the DOCX run walker) can never guess.
    internal static func unambiguousReplacementMap(_ mapping: Mapping) -> [String: String] {
        var valuesByReplacement: [String: Set<String>] = [:]
        for entry in mapping.entries.values where !entry.token.isEmpty {
            valuesByReplacement[entry.token, default: []].insert(entry.value)
        }
        var map: [String: String] = [:]
        for (replacement, values) in valuesByReplacement where values.count == 1 {
            map[replacement] = values.first
        }
        return map
    }
}
