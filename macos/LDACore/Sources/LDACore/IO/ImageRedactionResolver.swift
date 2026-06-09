//
//  ImageRedactionResolver.swift
//  LDACore
//
//  Policy core of the image-PII channel. Turns image-origin OCR observations into
//  redaction boxes (conservative: one box per observation) plus redact-only mapping
//  entries for the observations that detection classifies as PII.
//
//  Token rules (see the spec): reuse an existing token when the detected surface is
//  already in the mapping (matched on normalized surface text and aliases); mint the
//  next {TYPE_N}, continuing the mapping's per-type numbering, for a new entity; use
//  a generic {REDACTED_N} label with no mapping entry when detection finds nothing.
//
//  Pure: no IO, no OCR, no clock. Detection is injected so it is testable and so the
//  caller can load the LLM engine once and reuse it.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//
import Foundation
import CoreGraphics

public enum ImageRedactionResolver {
    public struct Result: Sendable, Equatable {
        public var boxes: [RedactionBox]
        public var newEntries: [MappingEntry]
        public var imageRedactionCount: Int
    }

    /// Resolve observations into boxes and redact-only entries.
    ///
    /// - Parameters:
    ///   - mapping: the mapping from the text-layer tokenization (read-only here).
    ///   - observations: image-origin OCR observations, in document order.
    ///   - detect: detection over arbitrary text (deterministic + optional LLM).
    public static func resolve(
        mapping: Mapping,
        observations: [ImageTextObservation],
        detect: (String) -> [Span]
    ) -> Result {
        guard !observations.isEmpty else {
            return Result(boxes: [], newEntries: [], imageRedactionCount: 0)
        }

        // Build one combined text so detection runs once. Track each observation's
        // UTF-16 range so detected spans can be attributed back to an observation.
        var combined = ""
        var ranges: [Range<Int>] = []
        for (i, observation) in observations.enumerated() {
            let start = combined.utf16.count
            combined += observation.text
            ranges.append(start..<combined.utf16.count)
            if i < observations.count - 1 { combined += "\n" }
        }
        let spans = detect(combined)

        // Reuse index: normalized surface (and aliases) -> existing token.
        var tokenByNormSurface: [String: String] = [:]
        for entry in mapping.entries.values {
            tokenByNormSurface[TextMatching.normalize(entry.surfaceText)] = entry.token
            for alias in entry.aliases {
                tokenByNormSurface[TextMatching.normalize(alias)] = entry.token
            }
        }

        // Per-type counters seeded from the existing mapping token keys.
        var counters = perTypeMaxIndices(in: mapping.entries.keys)

        var boxes: [RedactionBox] = []
        var newEntries: [MappingEntry] = []

        for (i, observation) in observations.enumerated() {
            let range = ranges[i]
            // The dominant span fully inside this observation's range, longest first.
            let dominant = spans
                .filter { $0.start >= range.lowerBound && $0.end <= range.upperBound }
                .max(by: { ($0.end - $0.start) < ($1.end - $1.start) })

            let token: String
            if let span = dominant {
                let norm = TextMatching.normalize(span.text)
                if let existing = tokenByNormSurface[norm] {
                    token = existing  // reuse, no new entry
                } else {
                    let typeToken = TokenGrammar.sanitizeType(span.type.rawValue)
                    let n = (counters[typeToken] ?? 0) + 1
                    counters[typeToken] = n
                    token = "{\(typeToken)_\(n)}"
                    tokenByNormSurface[norm] = token
                    newEntries.append(MappingEntry(token: token, value: span.text,
                                                   type: span.type, surfaceText: span.text, aliases: []))
                }
            } else {
                let n = (counters["REDACTED"] ?? 0) + 1
                counters["REDACTED"] = n
                token = "{REDACTED_\(n)}"  // generic label, no mapping entry
            }
            boxes.append(RedactionBox(pageIndex: observation.pageIndex, rect: observation.rect, token: token))
        }

        return Result(boxes: boxes, newEntries: newEntries, imageRedactionCount: boxes.count)
    }

    /// Max N per TYPE across canonical "{TYPE_N}" mapping keys. Scans keys only, so a
    /// surface text that happens to look like a token cannot perturb numbering.
    private static func perTypeMaxIndices<S: Sequence>(in keys: S) -> [String: Int]
    where S.Element == String {
        var maxima: [String: Int] = [:]
        for key in keys {
            guard key.hasPrefix("{"), key.hasSuffix("}") else { continue }
            let inner = key.dropFirst().dropLast()  // e.g. PERSON_1
            guard let underscore = inner.lastIndex(of: "_") else { continue }
            let typePart = String(inner[..<underscore])
            guard let n = Int(inner[inner.index(after: underscore)...]) else { continue }
            maxima[typePart] = max(maxima[typePart] ?? 0, n)
        }
        return maxima
    }
}
