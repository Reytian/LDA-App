//
//  RunInProtection.swift
//  LDACore
//
//  Review's Protect, applied without asking.
//
//  A value the model found can be written somewhere with a letter or digit
//  run into it: "Jordan Lee2" (a footnote marker) or "byJordan Lee" (a PDF
//  text layer that lost a space). The locator refuses those places, so by
//  default the document is refused rather than written with the value still
//  in it (LJE-001), and Review lists the value for the user to Protect by
//  hand. A batch has no one to ask. Under UnlocatedValuePolicy.protect the
//  engine redacts exactly the places Protect would
//  (EntityLocator.runInOccurrences) and still refuses the document when a
//  value is written in no such place: that value sits only inside longer
//  words, or in a form the text does not have, and cutting a value out of an
//  ordinary word is never done automatically.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// What the engine does with a value the model found but the locator could
/// not anchor at every place it is written.
public enum UnlocatedValuePolicy: String, Sendable, Codable, CaseIterable {
    /// Refuse the document and write nothing. The default wherever a person
    /// looks at the result: Review in the app, a single `lda anonymize`.
    case refuse
    /// Redact the value where a letter or digit runs into it, the places
    /// Review's Protect covers, and refuse only when a value is written in no
    /// such place. The policy of `lda batch` and the app's batch window.
    case protect
}

/// Redaction spans for the run-in places of values the locator refused.
public enum RunInProtection {

    /// The overlap priority of a protected place. Equal to the priority the
    /// app gives a value the user protects by hand
    /// (ProtectSelectionRules.manualPriority), so an automatic protection wins
    /// exactly the conflicts a manual one does.
    public static let priority = 110

    /// The outcome of protecting a list of values in one text.
    public struct Outcome: Equatable, Sendable {
        /// One span per run-in place, in value order, then document order.
        public let spans: [Span]
        /// The values written run-in at least once. Every such place is in
        /// `spans`.
        public let protectedValues: [ExtractedEntity]
        /// The values written in no run-in place: only inside longer words, or
        /// not in the text as reported. Nothing here protects them.
        public let unprotectedValues: [ExtractedEntity]
    }

    /// A span for every place a value in `values` is written run into a
    /// letter or digit in `text`. Never a place inside an ordinary word: see
    /// EntityLocator.runInOccurrences.
    public static func spans(
        for values: [ExtractedEntity],
        in text: String,
        source: DetectionSource,
        priority: Int = RunInProtection.priority
    ) -> [Span] {
        let nsText = text as NSString
        return values.flatMap { value in
            EntityLocator.runInOccurrences(forValue: value.value, in: text).map { range in
                Span(
                    start: range.location,
                    end: NSMaxRange(range),
                    type: value.type,
                    text: nsText.substring(with: range),
                    source: source,
                    confidence: 1.0,
                    priority: priority
                )
            }
        }
    }

    /// Protects `values`, the values a scan of `text` could not anchor
    /// everywhere: their run-in places as spans, and which values that leaves
    /// unprotected.
    public static func protect(_ values: [ExtractedEntity], in text: String) -> Outcome {
        var spans: [Span] = []
        var protectedValues: [ExtractedEntity] = []
        var unprotectedValues: [ExtractedEntity] = []
        for value in values {
            let places = Self.spans(for: [value], in: text, source: .llm)
            if places.isEmpty {
                unprotectedValues.append(value)
            } else {
                protectedValues.append(value)
                spans.append(contentsOf: places)
            }
        }
        return Outcome(
            spans: spans,
            protectedValues: protectedValues,
            unprotectedValues: unprotectedValues
        )
    }
}
