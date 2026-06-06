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

/// One user-defined term to always redact.
public struct CustomPattern: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    /// The literal term to find in the document.
    public var text: String
    /// The token type to assign when this term is redacted.
    public var type: EntityType
    /// When false (the default), matching ignores letter case.
    public var caseSensitive: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        type: EntityType = .company,
        caseSensitive: Bool = false
    ) {
        self.id = id
        self.text = text
        self.type = type
        self.caseSensitive = caseSensitive
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

            let options: NSString.CompareOptions = pattern.caseSensitive ? [] : [.caseInsensitive]
            var searchStart = 0
            while searchStart < ns.length {
                let searchRange = NSRange(location: searchStart, length: ns.length - searchStart)
                let found = ns.range(of: needle, options: options, range: searchRange)
                if found.location == NSNotFound { break }
                let surface = ns.substring(with: found)
                spans.append(
                    Span(
                        start: found.location,
                        end: found.location + found.length,
                        type: pattern.type,
                        text: surface,
                        source: .manual,
                        confidence: 1.0,
                        priority: priority
                    )
                )
                searchStart = found.location + max(found.length, 1)
            }
        }
        return spans
    }
}
