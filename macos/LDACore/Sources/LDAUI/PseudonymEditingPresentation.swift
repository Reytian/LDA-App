//
//  PseudonymEditingPresentation.swift
//  LDAUI
//
//  Pure presentation decisions for the editable pseudonym replacements (F5):
//  when the sidebar shows the edit affordance, what the row displays as the
//  current replacement, and the one-line footnote that explains the gate.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

enum PseudonymEditingPresentation {

    /// Replacement editing exists only for the pseudonym style: under the
    /// token style a forced non-brace replacement would be invisible to the
    /// restore scan, and asterisk masks are a fixed form. The engine
    /// validator enforces the same rule; this gate keeps the affordance out
    /// of the sidebar entirely for the other styles.
    static func isEditingAvailable(style: SubstitutionStyle) -> Bool {
        style == .pseudonym
    }

    /// The one-line sidebar footnote shown while editing is available.
    static let footnote = "Replacement text can be edited in this list because "
        + "the output style is pseudonyms. Placeholder and asterisk outputs "
        + "use fixed forms."

    /// What the row shows as the value's current replacement: the user's
    /// override when one exists, otherwise the replacement assigned by the
    /// most recent build (nil before the first build).
    static func currentReplacement(
        override: String?,
        assignedToken: String?
    ) -> String? {
        override ?? assignedToken
    }
}
