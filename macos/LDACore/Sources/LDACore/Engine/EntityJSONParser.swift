//
//  EntityJSONParser.swift
//  LDACore
//
//  Parses the v2 model's single-shot JSON output into typed entities. The model
//  returns {"entities":[{"value":...,"type":...}, ...], "redacted_text":"..."}.
//  Only the fuzzy types LDA keeps from the LLM (PERSON, COMPANY, ADDRESS) are of
//  interest downstream; the DeterministicEngine owns the structured types and
//  wins conflicts via SpanMerger priority.
//
//  The model's text is not guaranteed to be clean JSON: it may be wrapped in
//  prose, fenced in triple-backtick code blocks, or carry trailing chatter. The
//  parser locates the largest balanced JSON region, decodes it tolerantly, and
//  accepts either an object with an "entities" array plus "redacted_text", or a
//  bare array of {value,type}. It never throws; unparseable input yields [].
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - ExtractedEntity

/// One entity the model reported: a surface value plus its classified type.
/// Locations are resolved later by EntityLocator against the source text.
public struct ExtractedEntity: Equatable, Sendable {
    /// The surface value the model returned, for example "Acme Corporation".
    public let value: String
    /// The classified entity type, mapped from the model's wire string.
    public let type: EntityType

    public init(value: String, type: EntityType) {
        self.value = value
        self.type = type
    }
}

// MARK: - EntityJSONParser

/// Parses raw v2 model output into extracted entities.
public enum EntityJSONParser {
    /// Parse the model's JSON output into entities.
    ///
    /// - Parameter modelOutput: the raw decoded text returned by the model.
    /// - Returns: the parsed entities, or an empty array on unparseable output.
    ///
    /// This is a thin wrapper over parseDetailed for callers that only need the
    /// entities and do not distinguish a truncated completion from genuine
    /// emptiness.
    public static func parse(_ modelOutput: String) -> [ExtractedEntity] {
        return parseDetailed(modelOutput).entities
    }

    /// Parse the model's JSON output into entities, reporting whether the output
    /// appears to have been truncated mid-array (the model hit its generation
    /// token cap before closing the JSON).
    ///
    /// A truncated completion is NOT genuine emptiness: complete entity objects
    /// emitted before the cut are salvaged and returned, and `truncated` is set
    /// so the caller can retry or flag the segment as not fully scanned rather
    /// than silently presenting zero spans as a clean result (LJE-001).
    ///
    /// - Parameter modelOutput: the raw decoded text returned by the model.
    /// - Returns: the recovered entities plus a truncation flag. For well-formed
    ///   JSON (including a genuinely empty entities array) `truncated` is false.
    public static func parseDetailed(
        _ modelOutput: String
    ) -> (entities: [ExtractedEntity], truncated: Bool) {
        // Try the RAW (trimmed) output and its balanced regions BEFORE stripping
        // code fences, so a "```" sequence inside a JSON string value never
        // mangles otherwise-valid JSON (LJE-003). Fence-stripping runs only as a
        // fallback, for genuinely fenced output.
        var candidates = candidateJSONRegions(in: modelOutput)
        let stripped = stripCodeFences(modelOutput)
        if stripped != modelOutput {
            for region in candidateJSONRegions(in: stripped)
            where !candidates.contains(region) {
                candidates.append(region)
            }
        }

        // Try every candidate balanced region, largest first, and return the
        // first that yields a usable decode. JSONSerialization is the primary
        // path; a brace-matching scan supplies the candidates when the raw
        // string is not itself valid JSON.
        var decodedSomeRegion = false
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            guard
                let object = try? JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                )
            else { continue }

            // A fully decodable region is, by definition, not truncated.
            decodedSomeRegion = true
            let entities = extractEntities(from: object)
            if !entities.isEmpty {
                return (entities, false)
            }
        }

        // At least one region decoded cleanly but none carried entities: this is
        // genuine emptiness (the model found no PII), not a cut-off completion.
        if decodedSomeRegion {
            return ([], false)
        }

        // No candidate region decoded. Either the output is genuine garbage with
        // no entities, or it is a completion that was cut off mid-array. Salvage
        // every complete {value,type} object before the cut and report truncation
        // so the caller does not treat a partial scan as a clean one.
        return salvageTruncatedEntities(from: stripped != modelOutput ? stripped : modelOutput)
    }

    // MARK: - Truncation salvage

    /// Recover the complete entity objects emitted before a truncation point.
    ///
    /// Locates the entities array (after an "entities" key, or a leading bare
    /// "["), walks it object by object with the same string-aware brace matcher
    /// used elsewhere, collects each fully-balanced {...}, and stops at the first
    /// object that does not close. Returns the recovered entities plus whether
    /// the array tail was left unbalanced (the truncation signal). When no
    /// entities array can be located at all, returns ([], false): that is genuine
    /// non-JSON input, not a mid-array cut, so there is nothing to salvage and no
    /// truncation to report.
    private static func salvageTruncatedEntities(
        from text: String
    ) -> (entities: [ExtractedEntity], truncated: Bool) {
        let scalars = Array(text)

        guard let arrayStart = entitiesArrayStart(in: scalars) else {
            return ([], false)
        }

        var entities: [ExtractedEntity] = []
        var index = arrayStart
        var arrayClosed = false

        // Walk the array body, pulling out each balanced object in turn.
        scan: while index < scalars.count {
            // Advance to the next object opener, stopping if the array closes.
            while index < scalars.count {
                let ch = scalars[index]
                if ch == "{" { break }
                if ch == "]" {
                    // The array closed cleanly; nothing was truncated past here.
                    arrayClosed = true
                    break scan
                }
                index += 1
            }
            guard index < scalars.count else { break }

            // Match this object honoring string literals.
            guard let objectEnd = balancedObjectEnd(in: scalars, from: index) else {
                // The trailing object never closed: this is the truncation point.
                break
            }

            let objectText = String(scalars[index...objectEnd])
            if let data = objectText.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                entities.append(contentsOf: extractEntities(from: [object]))
            }
            index = objectEnd + 1
        }

        // The array is truncated when it never reached its closing "]", whether
        // the tail object was cut mid-way or the input simply ended right after a
        // complete object but before the closing bracket. Either way the caller
        // must not treat the recovered set as the full, fully-scanned result.
        return (entities, !arrayClosed)
    }

    /// Find the scalar index just inside the entities array. Prefers the "["
    /// following an "entities" key; falls back to a leading bare "[" for a
    /// bare-array completion. Returns nil when no array can be located.
    private static func entitiesArrayStart(in scalars: [Character]) -> Int? {
        let key = Array("\"entities\"")
        if let keyIndex = firstIndex(of: key, in: scalars) {
            var index = keyIndex + key.count
            while index < scalars.count {
                if scalars[index] == "[" { return index + 1 }
                index += 1
            }
        }

        // Bare-array shape: the first "[" in the text opens the entity list.
        if let bracket = scalars.firstIndex(of: "[") {
            return bracket + 1
        }
        return nil
    }

    /// First index at which the needle scalar sequence occurs in haystack, or nil.
    private static func firstIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }

    /// Given a "{" at `start`, return the index of its matching "}", honoring
    /// string literals so braces inside quoted values do not throw off the depth
    /// count. Returns nil when the object does not close (the truncation case).
    private static func balancedObjectEnd(in scalars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start

        while index < scalars.count {
            let ch = scalars[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }

        return nil
    }

    // MARK: - Code fence stripping

    /// Remove triple-backtick fences (with an optional language tag such as
    /// ```json) so the JSON body inside a fenced code block is exposed. If no
    /// closing fence is present the input is returned unchanged.
    private static func stripCodeFences(_ text: String) -> String {
        let fence = "```"
        guard let openRange = text.range(of: fence) else {
            return text
        }

        // Skip an optional language tag on the rest of the opening fence line.
        var bodyStart = openRange.upperBound
        if let newline = text[bodyStart...].firstIndex(of: "\n") {
            let tag = text[bodyStart..<newline].trimmingCharacters(
                in: .whitespaces
            )
            // A short alphabetic tag like "json" is a language hint we drop.
            if tag.allSatisfy({ $0.isLetter }) {
                bodyStart = text.index(after: newline)
            }
        }

        guard let closeRange = text.range(
            of: fence,
            range: bodyStart..<text.endIndex
        ) else {
            // No closing fence: hand back everything after the opening fence.
            return String(text[bodyStart...])
        }

        return String(text[bodyStart..<closeRange.lowerBound])
    }

    // MARK: - Candidate region discovery

    /// Produce the balanced JSON regions worth attempting, ordered largest
    /// first. The whole (trimmed) string is tried first so that already-clean
    /// JSON decodes immediately; brace and bracket matched substrings follow as
    /// the fallback scan for JSON embedded in prose.
    private static func candidateJSONRegions(in text: String) -> [String] {
        var regions: [String] = []

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            regions.append(trimmed)
        }

        // Brace-matched object, then bracket-matched array. Each is the largest
        // balanced region of its kind, which is what we want for the dominant
        // payload.
        if let object = largestBalancedRegion(in: text, open: "{", close: "}") {
            regions.append(object)
        }
        if let array = largestBalancedRegion(in: text, open: "[", close: "]") {
            regions.append(array)
        }

        // De-duplicate while preserving order so we never decode the same string
        // twice.
        var seen = Set<String>()
        return regions.filter { seen.insert($0).inserted }
    }

    /// Scan for the largest balanced top-level region delimited by the given open
    /// and close characters, honoring string literals so braces inside quoted
    /// values do not throw off the depth count. Returns the longest completed
    /// top-level region, or nil when none balances.
    ///
    /// Returning the LARGEST region rather than the first (LJE-002) lets a real
    /// entities object or array be reached even when stray balanced punctuation
    /// in a reasoning model's prose precedes it.
    private static func largestBalancedRegion(
        in text: String,
        open: Character,
        close: Character
    ) -> String? {
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

            if ch == open {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if ch == close {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let begin = startIndex {
                    // Record this completed top-level region and keep scanning so
                    // a later, larger region can win.
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

    // MARK: - Decoding

    /// Extract entities from a decoded JSON object. Accepts either a dictionary
    /// carrying an "entities" array, or a bare array of entity objects.
    private static func extractEntities(from object: Any) -> [ExtractedEntity] {
        if let dict = object as? [String: Any] {
            if let rawEntities = dict["entities"] as? [Any] {
                return entities(fromArray: rawEntities)
            }
            return []
        }

        if let array = object as? [Any] {
            return entities(fromArray: array)
        }

        return []
    }

    /// Map an array of raw entity dictionaries to typed entities, skipping any
    /// entry that lacks a non-empty value.
    private static func entities(fromArray array: [Any]) -> [ExtractedEntity] {
        var result: [ExtractedEntity] = []

        for element in array {
            guard let entry = element as? [String: Any] else { continue }
            guard let rawValue = entry["value"] as? String else { continue }

            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                continue
            }

            let rawType = (entry["type"] as? String) ?? ""
            let type = mapType(rawType)

            result.append(ExtractedEntity(value: value, type: type))
        }

        return result
    }

    /// Map a wire type string to an EntityType case-insensitively. Recognizes the
    /// fuzzy and structured wire strings plus their aliases; anything unrecognized
    /// becomes .unknown.
    private static func mapType(_ raw: String) -> EntityType {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        switch key {
        case "PERSON":
            return .person
        case "COMPANY":
            return .company
        case "ADDRESS":
            return .address
        case "EMAIL":
            return .email
        case "PHONE":
            return .phone
        case "DATE":
            return .date
        case "AMOUNT":
            return .amount
        case "NATIONAL_ID":
            return .nationalID
        case "USCC":
            return .uscc
        case "BANK_ACCOUNT":
            return .bankAccount
        case "CASE_NUMBER":
            return .caseNumber
        case "LICENSE_PLATE":
            return .licensePlate
        case "WECHAT_ID":
            return .wechatID
        case "URL":
            return .url
        case "SEAL":
            return .seal
        default:
            return .unknown
        }
    }
}
