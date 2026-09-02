//
//  SpanExclusion.swift
//  LDACore
//
//  The review step at the engine level: a caller may exclude detected spans
//  from redaction ("redact everything except these") before anything is
//  tokenized, so the CLI, the MCP server, and the app share one implementation
//  and an excluded value never mints a token or enters a mapping.
//
//  Two channels, on purpose:
//
//   - excludedTypes apply everywhere: the body, the docx non-body parts
//     (headers, footers, notes, comments), and the image-PII channel.
//   - bodyFilter applies to BODY spans only. Its callers identify spans by
//     type and offsets, and offsets belong to the body text: a header span at
//     the same offsets is a different value, so applying the filter there
//     could leave a header value visible that nobody excluded.
//
//  Observation contract: bodyFilter is consulted for EVERY body span, in
//  detection order, BEFORE the type test, so a caller may use it to observe
//  the full detection set (the MCP surface derives its detection fingerprint
//  this way) even when some types are excluded.
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

    /// Body spans: the filter sees every span first, then the type test runs.
    func filterBody(_ spans: [Span]) -> [Span] {
        spans.filter { span in
            let accepted = bodyFilter?(span) ?? true
            return accepted && !excludedTypes.contains(span.type)
        }
    }

    /// Supplementary channels (docx non-body parts, image OCR text): types
    /// only. Per-span filters never apply here because their offsets belong
    /// to the body text.
    func filterSupplementary(_ spans: [Span]) -> [Span] {
        guard !excludedTypes.isEmpty else { return spans }
        return spans.filter { !excludedTypes.contains($0.type) }
    }
}
