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
    public static func parse(_ modelOutput: String) -> [ExtractedEntity] {
        let stripped = stripCodeFences(modelOutput)

        // Try every candidate balanced region, largest first, and return the
        // first that yields a usable decode. JSONSerialization is the primary
        // path; a brace-matching scan supplies the candidates when the raw
        // string is not itself valid JSON.
        for candidate in candidateJSONRegions(in: stripped) {
            guard let data = candidate.data(using: .utf8) else { continue }
            guard
                let object = try? JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                )
            else { continue }

            let entities = extractEntities(from: object)
            if !entities.isEmpty {
                return entities
            }
        }

        return []
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

    /// Scan for the largest balanced region delimited by the given open and
    /// close characters, honoring string literals so braces inside quoted values
    /// do not throw off the depth count. Returns the substring from the first
    /// opener to its matching closer, or nil when none balances.
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
                    return String(scalars[begin...index])
                }
            }
        }

        return nil
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
        default:
            return .unknown
        }
    }
}
