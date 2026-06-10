//
//  ProfileJSONParser.swift
//  LDACore
//
//  Defensive parsing of model output for profile extraction and blank
//  matching, in the same salvage style as EntityJSONParser: strip code fences
//  and prose, locate the outermost JSON array via a balanced-bracket scan,
//  decode row by row, and drop malformed rows instead of failing the batch.
//  The Detailed variants return nil when no JSON array can be recovered at
//  all, which the callers treat as a truncation signal (retry, then split,
//  then mark incomplete).
//
//  Salvage-approach note: EntityJSONParser uses largestBalancedRegion, which
//  walks all balanced bracket regions and keeps the largest one. ProfileJSON-
//  Parser mirrors that strategy so that stray balanced punctuation in model
//  prose does not shadow the real payload array. Code-fence stripping follows
//  the same try-raw-first, strip-as-fallback order to avoid mangling JSON
//  strings that contain backtick sequences.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - ProfileRow

/// One raw extracted profile row before grounding and merging.
public struct ProfileRow: Equatable, Sendable {
    public let key: String
    public let value: String
    public let snippet: String
    public let confidence: Double
}

// MARK: - BlankMatchRow

/// One raw blank match answer.
public struct BlankMatchRow: Equatable, Sendable {
    public let blank: Int
    public let field: Int?
    public let value: String?
}

// MARK: - ProfileJSONParser

public enum ProfileJSONParser {

    // MARK: Profile rows

    /// Salvage-parse profile rows from raw model output.
    ///
    /// Returns an empty array when an array was found but had no valid rows.
    /// This is a convenience wrapper over parseProfileRowsDetailed.
    public static func parseProfileRows(_ modelOutput: String) -> [ProfileRow] {
        parseProfileRowsDetailed(modelOutput) ?? []
    }

    /// Parse profile rows from raw model output, returning nil when no JSON
    /// array could be recovered (truncation signal for the caller).
    ///
    /// A non-nil return (even an empty array) means an array was located and
    /// decoded; individual rows with missing or empty required fields (key,
    /// value, snippet) are dropped rather than failing the whole batch.
    /// Confidence is clamped to [0, 1]; a missing confidence defaults to 0.5.
    public static func parseProfileRowsDetailed(_ modelOutput: String) -> [ProfileRow]? {
        guard let array = jsonArray(in: modelOutput) else { return nil }
        var rows: [ProfileRow] = []
        for element in array {
            guard
                let object = element as? [String: Any],
                let key = object["key"] as? String, !key.isEmpty,
                let value = object["value"] as? String, !value.isEmpty,
                let snippet = object["snippet"] as? String
            else { continue }
            let rawConfidence = (object["confidence"] as? NSNumber)?.doubleValue ?? 0.5
            let confidence = min(1.0, max(0.0, rawConfidence))
            rows.append(ProfileRow(key: key, value: value, snippet: snippet, confidence: confidence))
        }
        return rows
    }

    // MARK: Blank match rows

    /// Convenience wrapper: parse blank match rows, returning [] on failure.
    public static func parseBlankMatchRows(_ modelOutput: String) -> [BlankMatchRow] {
        parseBlankMatchRowsDetailed(modelOutput) ?? []
    }

    /// Parse blank match rows from raw model output, returning nil when no
    /// JSON array could be recovered.
    ///
    /// A row missing the required "blank" integer key is dropped. The "field"
    /// and "value" fields are optional and may be null (or absent), yielding
    /// nil on the corresponding struct properties.
    public static func parseBlankMatchRowsDetailed(_ modelOutput: String) -> [BlankMatchRow]? {
        guard let array = jsonArray(in: modelOutput) else { return nil }
        var rows: [BlankMatchRow] = []
        for element in array {
            guard
                let object = element as? [String: Any],
                let blank = (object["blank"] as? NSNumber)?.intValue
            else { continue }
            let field = (object["field"] as? NSNumber)?.intValue
            // "value" may be a JSON null (decoded as NSNull) or absent; both yield nil.
            let value: String?
            if let v = object["value"] as? String {
                value = v
            } else {
                value = nil
            }
            rows.append(BlankMatchRow(blank: blank, field: field, value: value))
        }
        return rows
    }

    // MARK: - Core salvage: locate the JSON array

    /// Locate and decode the outermost JSON array in the model output.
    ///
    /// Strategy (mirrors EntityJSONParser.candidateJSONRegions):
    ///  1. Try the trimmed raw output first so clean JSON decodes immediately
    ///     without unnecessary string manipulation.
    ///  2. Apply largestBalancedArrayRegion to extract the largest bracket-
    ///     balanced substring, handling stray prose brackets that would fool a
    ///     naive first-"["/last-"]" scan.
    ///  3. Retry both steps on the fence-stripped text, but only when the
    ///     fence stripper actually changed the string (avoids double work and
    ///     prevents backtick sequences inside JSON string values from being
    ///     treated as fence markers).
    ///
    /// Returns nil when no candidate decodes to a JSON array.
    private static func jsonArray(in modelOutput: String) -> [Any]? {
        var candidates: [String] = []

        let trimmed = modelOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            candidates.append(trimmed)
        }
        if let balanced = largestBalancedArrayRegion(in: modelOutput) {
            if !candidates.contains(balanced) {
                candidates.append(balanced)
            }
        }

        let stripped = stripCodeFences(modelOutput)
        if stripped != modelOutput {
            let strippedTrimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            if !strippedTrimmed.isEmpty, !candidates.contains(strippedTrimmed) {
                candidates.append(strippedTrimmed)
            }
            if let balanced = largestBalancedArrayRegion(in: stripped) {
                if !candidates.contains(balanced) {
                    candidates.append(balanced)
                }
            }
        }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            guard
                let parsed = try? JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                ),
                let array = parsed as? [Any]
            else { continue }
            return array
        }
        return nil
    }

    // MARK: - Code fence stripping

    /// Remove triple-backtick fences (with an optional language tag such as
    /// "json") so the JSON body inside a fenced code block is exposed.
    /// If no closing fence is present the input is returned unchanged.
    /// Mirrors EntityJSONParser.stripCodeFences exactly.
    private static func stripCodeFences(_ text: String) -> String {
        let fence = "```"
        guard let openRange = text.range(of: fence) else {
            return text
        }

        var bodyStart = openRange.upperBound
        if let newline = text[bodyStart...].firstIndex(of: "\n") {
            let tag = text[bodyStart..<newline].trimmingCharacters(in: .whitespaces)
            if tag.allSatisfy({ $0.isLetter }) {
                bodyStart = text.index(after: newline)
            }
        }

        guard let closeRange = text.range(of: fence, range: bodyStart..<text.endIndex) else {
            return String(text[bodyStart...])
        }

        return String(text[bodyStart..<closeRange.lowerBound])
    }

    // MARK: - Balanced bracket region

    /// Return the largest balanced "[" ... "]" region in the text, honoring
    /// string literals so brackets inside quoted values do not throw off the
    /// depth count.
    ///
    /// Mirrors EntityJSONParser.largestBalancedRegion (open: "[", close: "]"):
    /// scans the full text and keeps the largest completed top-level region
    /// rather than the first, so a real entities array preceded by stray prose
    /// brackets wins even when those brackets appear first.
    private static func largestBalancedArrayRegion(in text: String) -> String? {
        let scalars = Array(text)
        var startIndex: Int?
        var depth = 0
        var inString = false
        var escaped = false
        var best: String?

        for (index, ch) in scalars.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }

            if ch == "\"" {
                inString = true
                continue
            }

            if ch == "[" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if ch == "]" {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let begin = startIndex {
                    let region = String(scalars[begin...index])
                    if region.count > (best?.count ?? 0) {
                        best = region
                    }
                    startIndex = nil
                }
            }
        }

        return best
    }
}
