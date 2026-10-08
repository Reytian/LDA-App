//
//  PrecedentPartyRule.swift
//  LDACore
//
//  A published precedent's own parties stay visible. When the document is
//  itself a published precedent (an SPC or SPP guiding case, or a published US
//  opinion), its parties' names are public and the owner's convention is to
//  keep them in clear, in the caption and in the body. A token tagger sees a
//  256-token window and cannot tell what kind of document it is reading, so
//  the models redact every name and this rule runs on the whole document.
//
//  Caption detection is TinyPII.PrecedentRule.caption(of:), a port of the
//  reference rule (datagen/precedent_rule.py). It is deliberately
//  conservative: an unpublished opinion, a memorandum, or a case merely cited
//  in passing returns nil, and then nothing is released.
//
//  The release is BY VALUE, like SpanExclusion: a PERSON or COMPANY value of
//  two or more characters that appears in the caption stays visible at every
//  occurrence, on every channel. Witnesses, judges and counsel are not named
//  in a caption, so they stay redacted, and so does a short form the caption
//  does not spell (大华公司 for 西安市大华餐饮有限公司).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import TinyPII

/// What the rule released for one document.
public struct PrecedentRelease: Equatable, Sendable {
    /// The caption that identified the document as a published precedent.
    public let caption: String
    /// The released values as they appear in the document, in first-seen order.
    public let values: [String]
    /// The same values normalized with TextMatching.normalize, for by-value
    /// comparison across channels.
    public let normalizedValues: Set<String>

    /// True when this span carries a released value.
    public func releases(_ span: Span) -> Bool {
        PrecedentPartyRule.partyTypes.contains(span.type)
            && normalizedValues.contains(TextMatching.normalize(span.text))
    }
}

public enum PrecedentPartyRule {
    /// The types a caption can name. Everything else is never released.
    static let partyTypes: Set<EntityType> = [.person, .company]

    /// The caption of a published precedent, or nil.
    public static func caption(of text: String) -> String? {
        PrecedentRule.caption(of: text)
    }

    /// The party values the rule keeps visible in this document, or nil when
    /// the document is not a published precedent or no detected value is
    /// named in its caption.
    ///
    /// - Parameter redactedElsewhere: confirmed entities of the OTHER
    ///   documents in the same session. A value one of them redacts is not
    ///   released here: its name in clear beside its own token in a document
    ///   shared alongside would disclose the mapping.
    public static func release(
        text: String,
        spans: [Span],
        redactedElsewhere: [Span] = []
    ) -> PrecedentRelease? {
        guard let caption = caption(of: text) else { return nil }
        let folded = caption.lowercased()
        let elsewhere = Set(redactedElsewhere.map { TextMatching.normalize($0.text) })
        var values: [String] = []
        var normalized = Set<String>()
        for span in spans where partyTypes.contains(span.type) {
            let surface = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard surface.unicodeScalars.count >= 2, folded.contains(surface.lowercased()) else { continue }
            let key = TextMatching.normalize(span.text)
            guard !elsewhere.contains(key) else { continue }
            if normalized.insert(key).inserted {
                values.append(surface)
            }
        }
        guard !values.isEmpty else { return nil }
        return PrecedentRelease(caption: caption, values: values, normalizedValues: normalized)
    }
}
