//
//  CustomPatternEngine.swift
//  LDACore
//
//  User-defined vocabulary: literal terms the user always wants redacted (for
//  example a project codename, a client name, an internal label). Each term
//  carries the token type to assign. Matches are emitted as high-priority manual
//  spans so they win any overlap conflict during merging: the user's explicit
//  choice dominates both the regex engine and the model.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation

/// One user-defined term to always redact. The term is either a literal string
/// or an ICU regular expression (for example a matter number M-\d{5}).
public struct CustomPattern: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    /// The literal term, or the regular expression source when isRegex is true.
    public var text: String
    /// The token type to assign when this term is redacted.
    public var type: EntityType
    /// When false (the default), matching ignores letter case.
    public var caseSensitive: Bool
    /// When true, text is treated as a regular expression instead of a literal.
    public var isRegex: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        type: EntityType = .company,
        caseSensitive: Bool = false,
        isRegex: Bool = false
    ) {
        self.id = id
        self.text = text
        self.type = type
        self.caseSensitive = caseSensitive
        self.isRegex = isRegex
    }

    /// True when this pattern is a regex whose source fails to compile, so the UI
    /// can flag it. A literal is always valid.
    public var isInvalidRegex: Bool {
        guard isRegex else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return (try? NSRegularExpression(pattern: trimmed)) == nil
    }
}

/// Locates user-defined vocabulary terms in a document.
public enum CustomPatternEngine {
    /// User-chosen terms outrank everything else so they are always redacted.
    public static let priority = 120

    /// Find every occurrence of each pattern's term in text and emit a Span per
    /// occurrence (UTF-16 offsets, source .manual). Empty or whitespace-only
    /// terms are ignored. Matching is case-insensitive unless the pattern opts in.
    public static func detect(_ text: String, patterns: [CustomPattern]) -> [Span] {
        guard !patterns.isEmpty, !text.isEmpty else { return [] }
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var spans: [Span] = []

        for pattern in patterns {
            let needle = pattern.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }

            if pattern.isRegex {
                appendRegexMatches(pattern, needle: needle, ns: ns, range: fullRange, into: &spans)
            } else {
                appendLiteralMatches(pattern, needle: needle, ns: ns, into: &spans)
            }
        }
        return spans
    }

    private static func appendLiteralMatches(
        _ pattern: CustomPattern,
        needle: String,
        ns: NSString,
        into spans: inout [Span]
    ) {
        let options: NSString.CompareOptions = pattern.caseSensitive ? [] : [.caseInsensitive]
        var searchStart = 0
        while searchStart < ns.length {
            let searchRange = NSRange(location: searchStart, length: ns.length - searchStart)
            let found = ns.range(of: needle, options: options, range: searchRange)
            if found.location == NSNotFound { break }
            spans.append(makeSpan(ns: ns, range: found, type: pattern.type))
            searchStart = found.location + max(found.length, 1)
        }
    }

    private static func appendRegexMatches(
        _ pattern: CustomPattern,
        needle: String,
        ns: NSString,
        range: NSRange,
        into spans: inout [Span]
    ) {
        let options: NSRegularExpression.Options = pattern.caseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: needle, options: options) else { return }
        regex.enumerateMatches(in: ns as String, options: [], range: range) { match, _, _ in
            guard let match, match.range.length > 0 else { return }
            spans.append(makeSpan(ns: ns, range: match.range, type: pattern.type))
        }
    }

    private static func makeSpan(ns: NSString, range: NSRange, type: EntityType) -> Span {
        Span(
            start: range.location,
            end: range.location + range.length,
            type: type,
            text: ns.substring(with: range),
            source: .manual,
            confidence: 1.0,
            priority: priority
        )
    }
}
