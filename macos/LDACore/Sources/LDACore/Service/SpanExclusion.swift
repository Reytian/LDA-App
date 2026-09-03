//
//  SpanExclusion.swift
//  LDACore
//
//  The review step at the engine level: a caller may exclude detected spans
//  from redaction ("redact everything except these") before anything is
//  tokenized, so the CLI, the MCP server, and the app share one implementation
//  and an excluded value never mints a token or enters a mapping.
//
//  Exclusion is BY VALUE, not by occurrence. A caller names spans (by type and
//  offsets, which is how the MCP surface identifies them), but the decision is
//  resolved to the surface VALUES those spans carry, and every occurrence of
//  such a value is then left visible on every channel: the body, the docx
//  non-body parts (headers, footers, notes, comments), and the image-PII pass.
//
//  Leaving one occurrence in clear while tokenizing the others would be worse
//  than useless: the value and its own placeholder would sit in the same
//  document, so any reader could equate the two and de-anonymize every other
//  site of that placeholder, including sites the caller never looked at. The
//  caller asked to expose one occurrence; per-occurrence exclusion would
//  disclose the whole equivalence class instead.
//
//  Two channels, on purpose:
//
//   - excludedTypes apply everywhere, whatever the value.
//   - bodyFilter is consulted over BODY spans only, because its callers
//     identify spans by offsets and offsets belong to the body text. Its
//     verdict is what resolves to values, and the values then reach every
//     channel.
//
//  Observation contract: bodyFilter is consulted for EVERY body span, exactly
//  once, in detection order, BEFORE the type test, so a caller may use it to
//  observe the full detection set (the MCP surface derives its detection
//  fingerprint this way) even when some types are excluded.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Caller-supplied exclusions applied to detected spans before tokenization.
struct SpanExclusion {
    /// Entity types left visible on every channel.
    let excludedTypes: Set<EntityType>
    /// Per-span verdict over body spans; true keeps the span. Nil keeps all.
    let bodyFilter: ((Span) -> Bool)?

    /// Run the review over one document's body detection and resolve it to the
    /// values that must stay visible. Call this once per document, before the
    /// supplementary channels run, and apply the result on every channel.
    func resolve(bodySpans: [Span]) -> ResolvedExclusion {
        // Pass 1: the caller's verdict on every span, in detection order,
        // before the type test. A rejected span contributes its VALUE.
        var excludedValues = Set<String>()
        if let bodyFilter {
            for span in bodySpans where !bodyFilter(span) {
                excludedValues.insert(span.text)
            }
        }
        return ResolvedExclusion(
            excludedTypes: excludedTypes,
            excludedValues: excludedValues,
            bodySpans: bodySpans
        )
    }
}

/// One document's review, resolved to types and values and applicable to every
/// channel. It also tallies what it left visible, so the caller can report the
/// blast radius: how many occurrences are now in clear, and how many distinct
/// values they carry.
///
/// A reference type because the supplementary channels are detected lazily,
/// part by part, through an escaping closure, and one instance has to
/// accumulate their tally across those calls.
final class ResolvedExclusion {

    /// The body spans that survived the review, in detection order.
    private(set) var keptBodySpans: [Span] = []

    private let excludedTypes: Set<EntityType>
    private let excludedValues: Set<String>
    /// Occurrences left visible, body plus every supplementary channel.
    private var occurrenceCount = 0
    /// The distinct values behind those occurrences. Values never leave this
    /// object; only the count is published.
    private var visibleValues: Set<String> = []

    fileprivate init(
        excludedTypes: Set<EntityType>,
        excludedValues: Set<String>,
        bodySpans: [Span]
    ) {
        self.excludedTypes = excludedTypes
        self.excludedValues = excludedValues
        // Pass 2: an excluded value stays visible at EVERY occurrence, so the
        // test is on the value, not on the one span the caller named.
        var kept: [Span] = []
        kept.reserveCapacity(bodySpans.count)
        for span in bodySpans where keepAndTally(span) {
            kept.append(span)
        }
        keptBodySpans = kept
    }

    /// Supplementary channels (docx non-body parts, image OCR text): the same
    /// types and the same values as the body, so a value the review left
    /// visible is not tokenized in a header, footer, note, or comment either.
    func filterSupplementary(_ spans: [Span]) -> [Span] {
        spans.filter(keepAndTally)
    }

    /// How many detected occurrences the review left visible, on every
    /// channel. This is the number a caller must see: it is the blast radius,
    /// where the count of ids they passed is not.
    var excludedOccurrenceCount: Int { occurrenceCount }

    /// How many distinct values those occurrences carry.
    var excludedValueCount: Int { visibleValues.count }

    /// True to redact this span. A dropped span is tallied as one more
    /// occurrence left visible.
    private func keepAndTally(_ span: Span) -> Bool {
        guard excludedTypes.contains(span.type) || excludedValues.contains(span.text) else {
            return true
        }
        occurrenceCount += 1
        visibleValues.insert(span.text)
        return false
    }
}
