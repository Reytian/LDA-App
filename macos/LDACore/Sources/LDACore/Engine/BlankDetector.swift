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

    /// Pre-compiled regex table. Each entry is paired with its Family so
    /// detect() never rebuilds an NSRegularExpression on every call. A
    /// precondition fires immediately in debug if a pattern is ever broken
    /// (pattern errors should be caught at dev time, not silently dropped).
    private static let compiled: [(family: Family, regex: NSRegularExpression)] = {
        families.map { family in
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: family.pattern)
            } catch {
                preconditionFailure("BlankDetector: invalid regex pattern '\(family.pattern)': \(error)")
            }
            return (family: family, regex: regex)
        }
    }()

    // MARK: - Overlap resolution (two-phase, O(n log n))
    //
    // Structural facts that make this safe:
    //   (a) Matches from one regex never overlap each other (NSRegularExpression
    //       returns non-overlapping matches in a single pass).
    //   (b) The two bare-run families (underscore runs and dot runs) match
    //       disjoint character sets, so priority-10 candidates never overlap
    //       each other.
    //   (c) Only two conflict classes need resolution:
    //         - 40-vs-40: e.g. a handlebars token that is itself inside a
    //           bracketed label (unlikely but possible).
    //         - 10-inside-40: bare underscores or dots that fall within a
    //           delimited region must be suppressed.
    //
    // Algorithm:
    //   Phase 1 (delimited sweep): sort priority-40 candidates by (location
    //   asc, length desc); sweep with a lastEnd tracker; accept a candidate
    //   iff location >= lastEnd. This resolves all 40-vs-40 conflicts linearly.
    //
    //   Phase 2 (bare filter): for each priority-10 candidate, binary-search
    //   the sorted accepted40 list to find the only accepted interval whose
    //   start is <= the candidate's end, then check for actual intersection.
    //   O(log n) per bare candidate.
    //
    //   Final result: concatenate accepted40 + kept bare candidates, sort by
    //   location.

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

        // Collect all candidates using pre-compiled regexes.
        var delimited: [Candidate] = [] // priority 40
        var bare: [Candidate] = []      // priority 10

        for (family, regex) in compiled {
            regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match else { return }
                var label = ""
                if let group = family.labelGroup, match.range(at: group).location != NSNotFound {
                    label = ns.substring(with: match.range(at: group))
                }
                let candidate = Candidate(range: match.range, label: normalizeLabel(label), priority: family.priority)
                if family.priority >= 40 {
                    delimited.append(candidate)
                } else {
                    bare.append(candidate)
                }
            }
        }

        // Phase 1: sweep delimited candidates, resolving 40-vs-40 overlaps.
        let sortedDelimited = delimited.sorted {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            return $0.range.length > $1.range.length
        }
        var accepted40: [Candidate] = []
        var lastEnd = 0
        for candidate in sortedDelimited {
            if candidate.range.location >= lastEnd {
                accepted40.append(candidate)
                lastEnd = candidate.range.location + candidate.range.length
            }
        }

        // Phase 2: filter bare candidates against accepted40 using binary search.
        // accepted40 is already sorted by location ascending (lastEnd sweep
        // guarantees non-overlapping accepted entries in order).
        func intersectsAccepted40(_ range: NSRange) -> Bool {
            guard !accepted40.isEmpty else { return false }
            let candidateEnd = range.location + range.length
            // Find the rightmost accepted40 entry whose start <= candidateEnd.
            // That is the only one that could overlap range.
            var lo = 0
            var hi = accepted40.count - 1
            var found = -1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if accepted40[mid].range.location <= candidateEnd {
                    found = mid
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            guard found >= 0 else { return false }
            // Check whether this interval actually overlaps range.
            return NSIntersectionRange(accepted40[found].range, range).length > 0
        }

        let keptBare = bare.filter { !intersectsAccepted40($0.range) }

        // Merge and sort by location.
        let allAccepted = (accepted40 + keptBare).sorted { $0.range.location < $1.range.location }

        return allAccepted.map { candidate in
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
