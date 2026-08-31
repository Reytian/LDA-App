//
//  RestoreResultPresentation.swift
//  LDAUI
//
//  Shared user-facing copy for restore outcomes that need the reader's
//  attention. Pure functions so the wording is testable without a view.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation

/// Copy shared by the restore surfaces (the de-anonymize window and the
/// session's restore card).
public enum RestoreResultPresentation {

    /// How many examples a warning sentence lists before it stops.
    static let sampleLimit = 5

    /// The sentence for masked forms that two or more entities share.
    ///
    /// These sites were deliberately left verbatim: under asterisk style a
    /// mask is a pure function of the surface, so two names sharing a surname
    /// can produce the same mask (or one mask can be a prefix of another), and
    /// substituting either one would be a guess that silently puts the WRONG
    /// person's name into the document. The reader has to settle those sites
    /// against their own records, so the sentence names them and says plainly
    /// that nothing was guessed.
    ///
    /// - Returns: nil when there is nothing to report.
    static func ambiguousSentence(_ ambiguousReplacements: [String]) -> String? {
        guard !ambiguousReplacements.isEmpty else { return nil }
        let count = ambiguousReplacements.count
        let sample = ambiguousReplacements.prefix(sampleLimit).joined(separator: ", ")
        return "\(count) masked form"
            + (count == 1 ? " is" : "s are")
            + " shared by more than one entity: \(sample). "
            + (count == 1 ? "That site was" : "Those sites were")
            + " left as-is rather than guessed; check them against your own records."
    }
}
