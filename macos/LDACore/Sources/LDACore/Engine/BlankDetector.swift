//
//  BlankDetector.swift
//  LDACore
//
//  Deterministic detection of fill blanks in imported target text. No model
//  involvement. Supported conventions: bracketed labels [Company Name] and
//  [●] [•] [TBD] [___], underscore runs of two or more, bare ● or • runs,
//  handlebars {{field}}, and merge-field guillemets «Field».
//
//  Offsets are UTF-16 code units (NSRange semantics) into the supplied text,
//  matching the convention in CoreTypes.swift, so DocxFiller can hand them to
//  DocxRedactor unchanged.
//
//  False positives (cross-reference brackets, optional language) are
//  acceptable by design: nothing fills without review, and the planner may
//  answer "none".
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

public enum BlankDetector {

    /// Half-width of the context window captured around each blank, in UTF-16
    /// code units per side.
    public static let contextHalfWidth = 120

    /// One regex pattern family with an overlap-resolution priority. Higher
    /// priority wins overlaps (delimited families beat bare runs so the
    /// underscores inside {{a_b}} or [___] never double-report).
    private struct Family {
        let pattern: String
        let priority: Int
        /// Which capture group holds the label; nil means no label.
        let labelGroup: Int?
    }

    private static let families: [Family] = [
        Family(pattern: "\\[([^\\[\\]\\n]{1,60})\\]", priority: 40, labelGroup: 1),
        Family(pattern: "\\{\\{([^{}\\n]{1,60})\\}\\}", priority: 40, labelGroup: 1),
        Family(pattern: "\u{00AB}([^\u{00AB}\u{00BB}\\n]{1,60})\u{00BB}", priority: 40, labelGroup: 1),
        Family(pattern: "_{2,}", priority: 10, labelGroup: nil),
        Family(pattern: "[\u{25CF}\u{2022}]+", priority: 10, labelGroup: nil)
    ]

    /// Detect every blank in text, sorted by position. Labels that are only
    /// underscores, placeholder dots, or whitespace normalize to "".
    public static func detect(in text: String) -> [Blank] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        struct Candidate {
            let range: NSRange
            let label: String
            let priority: Int
        }

        var candidates: [Candidate] = []
        for family in families {
            guard let regex = try? NSRegularExpression(pattern: family.pattern) else { continue }
            regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match else { return }
                var label = ""
                if let group = family.labelGroup, match.range(at: group).location != NSNotFound {
                    label = ns.substring(with: match.range(at: group))
                }
                candidates.append(Candidate(range: match.range, label: normalizeLabel(label), priority: family.priority))
            }
        }

        // Overlap resolution: higher priority first, then earlier, then longer.
        // A sweep keeps every candidate that does not intersect an already
        // accepted one.
        let ordered = candidates.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            return $0.range.length > $1.range.length
        }
        var accepted: [Candidate] = []
        for candidate in ordered {
            let overlaps = accepted.contains { NSIntersectionRange($0.range, candidate.range).length > 0 }
            if !overlaps { accepted.append(candidate) }
        }

        return accepted
            .sorted { $0.range.location < $1.range.location }
            .map { candidate in
                Blank(
                    location: .textSpan(
                        start: candidate.range.location,
                        end: candidate.range.location + candidate.range.length
                    ),
                    label: candidate.label,
                    context: contextWindow(around: candidate.range, in: ns),
                    proposedFieldID: nil,
                    proposedValue: nil,
                    status: .unmatched
                )
            }
    }

    /// Labels that carry no information ([___], [●], whitespace) become "".
    private static func normalizeLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let informationless = CharacterSet(charactersIn: "_\u{25CF}\u{2022}\u{00B7}.").union(.whitespaces)
        if trimmed.unicodeScalars.allSatisfy({ informationless.contains($0) }) {
            return ""
        }
        return trimmed
    }

    private static func contextWindow(around range: NSRange, in ns: NSString) -> String {
        guard ns.length > 0 else { return "" }
        let start = max(0, range.location - contextHalfWidth)
        let end = min(ns.length, range.location + range.length + contextHalfWidth)
        // Clamp to grapheme boundaries so we never split a surrogate pair.
        let safeStart = ns.rangeOfComposedCharacterSequence(at: min(start, max(0, ns.length - 1))).location
        let last = max(safeStart, end - 1)
        let endSeq = ns.rangeOfComposedCharacterSequence(at: min(last, max(0, ns.length - 1)))
        let safeEnd = endSeq.location + endSeq.length
        return ns.substring(with: NSRange(location: safeStart, length: max(0, safeEnd - safeStart)))
    }
}
