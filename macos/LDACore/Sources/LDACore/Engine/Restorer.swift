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

        // The scan itself is shared with DocxRedactor's per-run substitution
        // (see TokenSubstitution), so the token grammar and the "an unmapped
        // token is left verbatim, never blanked" rule cannot drift between the
        // text surface and the docx surface. Unmapped tokens come back as
        // orphans for the user to review.
        let outcome = TokenSubstitution.substitute(in: text, matching: regex) { token in
            tokenToValue[token]
        }

        // Forensics pass: find near-miss placeholder shapes (an external AI may
        // have swapped brackets, dropped a brace, changed case, or stripped the
        // braces). Suspects are flagged for the user and never substituted. The
        // scan runs over the decoded INPUT text, where mangled shapes still sit
        // in their original form.
        let suspects = PlaceholderForensics.suspects(in: text, mapping: mapping)

        return RestoreResult(
            text: outcome.text,
            restoredCount: outcome.substitutedCount,
            orphanTokens: outcome.unmappedTokens,
            suspectPlaceholders: suspects
        )
    }
}
