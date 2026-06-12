//
//  PlaceholderForensics.swift
//  LDACore
//
//  Near-miss placeholder detection for restore. An external AI editing the
//  redacted text can mangle a placeholder: swap the braces for brackets or
//  parentheses, drop a brace, change the case, insert a space, or strip the
//  braces entirely. Such a string no longer matches TokenGrammar, so the main
//  restore scan cannot see it and the value would silently stay unrestored.
//
//  This scanner finds those near-miss shapes and reports them as suspects. It
//  NEVER substitutes a value for a suspect: per the flag-don't-guess contract,
//  anything that cannot be matched with certainty is surfaced to the user. The
//  scan is scoped to the TYPE strings actually present in the mapping, so
//  ordinary prose ("person 1", "Section 1") and unrelated bracketed text are
//  not flagged.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Pure forensics over restore input text. No clock reads, no I/O.
public enum PlaceholderForensics {

    /// Decode Markdown-escaped underscores inside otherwise exact tokens.
    ///
    /// AI tools that answer in Markdown commonly escape underscores, turning
    /// "{PERSON_1}" into "{PERSON\_1}". That escape is a well-defined encoding
    /// of the exact token (not a guess), so it is decoded before the restore
    /// scan. Only the escaped underscore INSIDE a token-shaped string is
    /// rewritten; every other backslash in the text is left untouched.
    public static func decodeMarkdownEscapedTokens(in text: String) -> String {
        // A token whose underscore is escaped: {TYPE\_N}
        guard let regex = try? NSRegularExpression(
            pattern: #"\{([A-Z][A-Z0-9]*)\\_(\d+)\}"#
        ) else {
            return text
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: fullRange,
            withTemplate: "{$1_$2}"
        )
    }

    /// Scan `text` for near-miss placeholder shapes for the TYPEs present in
    /// `mapping`. Returns the distinct suspect strings in first-seen order.
    ///
    /// A match is a suspect only when it does not overlap an exact
    /// TokenGrammar match (exact tokens are handled by the main restore scan,
    /// as substitutions or orphans).
    public static func suspects(in text: String, mapping: Mapping) -> [String] {
        let types = mappingTypes(mapping)
        guard !types.isEmpty else { return [] }

        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        // Ranges of exact tokens; any suspect candidate overlapping one is
        // dropped (for example the "PERSON_1}" tail inside "{PERSON_1}").
        let exactRanges = exactTokenRanges(in: text)

        var candidates: [(range: NSRange, value: String)] = []
        var seenRanges = Set<String>()

        for type in types.sorted() {
            let escaped = NSRegularExpression.escapedPattern(for: type)
            for pattern in suspectPatterns(forEscapedType: escaped) {
                guard let regex = try? NSRegularExpression(pattern: pattern) else {
                    continue
                }
                regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
                    guard let match = match else { return }
                    let range = match.range
                    let overlapsExact = exactRanges.contains { exact in
                        NSIntersectionRange(exact, range).length > 0
                    }
                    guard !overlapsExact else { return }
                    let value = nsText.substring(with: range)
                    // Defensive: an exact token string is never a suspect.
                    guard !isExactToken(value) else { return }
                    if seenRanges.insert("\(range.location):\(range.length)").inserted {
                        candidates.append((range, value))
                    }
                }
            }
        }

        // Drop a candidate fully contained inside a longer candidate (the bare
        // "COMPANY_1" inside the damaged "{ COMPANY_1 }" reports once, as the
        // longer shape), then dedupe by string in first-seen order.
        let kept = candidates.filter { candidate in
            !candidates.contains { other in
                other.range != candidate.range
                    && NSIntersectionRange(other.range, candidate.range) == candidate.range
            }
        }

        var seen = Set<String>()
        return kept.sorted { $0.range.location < $1.range.location }
            .compactMap { seen.insert($0.value).inserted ? $0.value : nil }
    }

    // MARK: - Patterns

    /// The near-miss patterns for one (already regex-escaped) TYPE string.
    ///
    /// Shapes covered, in order:
    /// 1. Brace pair with case or spacing damage: "{person_1}", "{PERSON 1}",
    ///    "{ PERSON_1 }". The exact token also matches this pattern but is
    ///    excluded by the exact-range overlap check.
    /// 2. Bracket, parenthesis, or angle pair: "[PERSON_1]", "(PERSON_1)",
    ///    "<PERSON_1>", case-insensitive.
    /// 3. Lost closing brace: "{PERSON_1" with no "}" after the digits.
    /// 4. Lost opening brace: "PERSON_1}" with no "{" before the TYPE.
    /// 5. Bare token: "PERSON_1" word-bounded, EXACT case only (the lowercase
    ///    prose "person 1" must never be flagged).
    private static func suspectPatterns(forEscapedType type: String) -> [String] {
        [
            // 1. Brace pair, forgiving about case, spaces, and the separator.
            #"\{\s*(?i:"# + type + #")\s*[_ ]\s*\d+\s*\}"#,
            // 2. Bracket, parenthesis, or angle pair.
            #"[\[(<]\s*(?i:"# + type + #")\s*[_ ]\s*\d+\s*[\])>]"#,
            // 3. Lost closing brace.
            #"\{(?i:"# + type + #")_\d+(?!\s*\})"#,
            // 4. Lost opening brace.
            #"(?<![{\[(<])\b(?i:"# + type + #")_\d+\}"#,
            // 5. Bare token, exact case.
            #"(?<![{\[(<])\b"# + type + #"_\d+\b(?![\])>}])"#
        ]
    }

    // MARK: - Helpers

    /// The distinct token TYPE strings present in the mapping (for example
    /// ["PERSON", "COMPANY"]), parsed from the entry tokens.
    private static func mappingTypes(_ mapping: Mapping) -> Set<String> {
        guard let regex = try? NSRegularExpression(
            pattern: #"^\{([A-Z][A-Z0-9]*)_\d+\}$"#
        ) else {
            return []
        }
        var types = Set<String>()
        for token in mapping.entries.keys {
            let nsToken = token as NSString
            let range = NSRange(location: 0, length: nsToken.length)
            guard let match = regex.firstMatch(in: token, options: [], range: range),
                  match.numberOfRanges > 1 else {
                continue
            }
            types.insert(nsToken.substring(with: match.range(at: 1)))
        }
        return types
    }

    /// All ranges of exact TokenGrammar tokens in the text.
    private static func exactTokenRanges(in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(
            pattern: TokenGrammar.placeholderPattern
        ) else {
            return []
        }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, options: [], range: fullRange).map { $0.range }
    }

    /// True when the whole string is an exact TokenGrammar token.
    private static func isExactToken(_ s: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: "^" + TokenGrammar.placeholderPattern + "$"
        ) else {
            return false
        }
        let range = NSRange(location: 0, length: (s as NSString).length)
        return regex.firstMatch(in: s, options: [], range: range) != nil
    }
}
