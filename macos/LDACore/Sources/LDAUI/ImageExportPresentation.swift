//
//  ImageExportPresentation.swift
//  LDAUI
//
//  Pure presentation decisions for the standalone-image export artifacts: the
//  seal CANDIDATE line, the unlocated-range warning, and the copy for the
//  per-document candidate toggle. Keeping the wording out of the views makes
//  it testable, and this is wording that has to be exactly right.
//
//  Claims discipline (docs/positioning-claims.md): red-region boxes are
//  CANDIDATES. Nothing here may say a seal was found, detected, or confirmed.
//  Over-covering is the accepted failure direction, so the toggle copy tells
//  the user why they might turn it off rather than promising precision.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation

enum ImageExportPresentation {

    /// The candidate line for the export completion card, or nil when the
    /// export boxed no candidates (an image with no red regions, a non-image
    /// source, or the toggle switched off).
    static func sealCandidateDetail(count: Int) -> String? {
        guard count > 0 else { return nil }
        let noun = count == 1 ? "red region" : "red regions"
        return "\(count) \(noun) boxed as possible seals or stamps. "
            + "These are candidates, not confirmed seals."
    }

    /// The warning for replaced values the image geometry could not box, or
    /// nil when every replaced value got a box.
    ///
    /// This one is a warning, not an informational line: the value IS replaced
    /// in the text companion and the mapping, so the round trip is correct,
    /// but the exported image can still show it. A lawyer who forwards that
    /// image believing it redacted is the failure this count exists to
    /// prevent, so it is never dropped.
    static func unboxedWarning(count: Int) -> String? {
        guard count > 0 else { return nil }
        let subject = count == 1 ? "1 redacted value" : "\(count) redacted values"
        let pronoun = count == 1 ? "it" : "them"
        return "Warning: \(subject) could not be boxed in the image. "
            + "The text and the mapping are redacted, but the exported image "
            + "may still show \(pronoun). Check it before sharing."
    }

    /// The per-document toggle label.
    static let sealCandidateToggleTitle = "Box red seal candidates"

    /// The per-document toggle help text. Says what the boxes are, what they
    /// are not, and the one reason to turn them off.
    static let sealCandidateToggleHelp =
        "Also box red regions that may be a seal or a stamp. These are "
        + "candidates: LDA does not confirm that a red region is a seal. "
        + "Turn this off when a red letterhead or a red title covers too much "
        + "of this document."
}
