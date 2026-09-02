//
//  ProtectSelectionPresentation.swift
//  LDAUI
//
//  The sentences behind a Protect action: the notice row, its VoiceOver
//  announcement, and the kind chooser's title and primary button. Whole
//  localized phrases with separate singular and plural keys, following the
//  "1 name" / "%lld names" pattern used elsewhere. Every %@ that quotes the
//  value carries the curly quotes inside the key so translators can move them.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

enum ProtectSelectionPresentation {

    /// The notice sentence for an outcome; empty when nothing should be shown
    /// (an empty selection is refused silently because the entry points were
    /// already disabled).
    static func message(for outcome: ProtectOutcome, language: AppLanguage? = nil) -> String {
        let typeName = EntityTypePresentation.localizedName(for: outcome.type, language: language)
        switch outcome.refusal {
        case .emptySelection:
            return ""
        case .multipleParagraphs:
            return L10n.string("Select text within one paragraph.", language: language)
        case .roleLabel:
            return String(
                format: L10n.string("“%@” is a role label, so it is kept visible by design.", language: language),
                outcome.value as NSString
            )
        case .insideProtected(let container):
            return String(
                format: L10n.string("“%@” is already protected as part of “%@”.", language: language),
                outcome.value as NSString,
                container as NSString
            )
        case nil:
            break
        }

        var sentence: String
        let count = outcome.protectedCount
        if outcome.retyped > 0, let previous = outcome.previousType, previous != outcome.type {
            sentence = String(
                format: L10n.string("Now protecting %lld occurrences of “%@” as %@ (was %@).", language: language),
                Int64(count),
                outcome.value as NSString,
                typeName as NSString,
                EntityTypePresentation.localizedName(for: previous, language: language) as NSString
            )
        } else {
            let key = count == 1
                ? "Protected 1 occurrence of “%@” as %@."
                : "Protected %lld occurrences of “%@” as %@."
            sentence = count == 1
                ? String(format: L10n.string(key, language: language), outcome.value as NSString, typeName as NSString)
                : String(format: L10n.string(key, language: language), Int64(count), outcome.value as NSString, typeName as NSString)
        }
        if outcome.replaced > 0 {
            let key = outcome.replaced == 1
                ? "Replaced 1 earlier finding."
                : "Replaced %lld earlier findings."
            let suffix = outcome.replaced == 1
                ? L10n.string(key, language: language)
                : String(format: L10n.string(key, language: language), Int64(outcome.replaced))
            sentence += " " + suffix
        }
        return sentence
    }

    /// The VoiceOver announcement for a successful protection.
    static func announcement(for outcome: ProtectOutcome, language: AppLanguage? = nil) -> String {
        String(
            format: L10n.string(
                "Protected %lld occurrences of %@ as %@. Undo is available in the Edit menu.",
                language: language
            ),
            Int64(outcome.protectedCount),
            outcome.value as NSString,
            EntityTypePresentation.localizedName(for: outcome.type, language: language) as NSString
        )
    }

    /// The chooser title for a value, by variant.
    static func chooserTitle(value: String, variant: ProtectVariant, language: AppLanguage? = nil) -> String {
        switch variant {
        case .changeKind:
            return String(format: L10n.string("Change kind for “%@”", language: language), value as NSString)
        case .protect, .protectAgain:
            return String(format: L10n.string("Protect “%@”", language: language), value as NSString)
        }
    }

    /// The chooser subtitle: how often the value occurs in this document.
    static func chooserSubtitle(occurrences: Int, language: AppLanguage? = nil) -> String {
        occurrences == 1
            ? L10n.string("Found once in this document.", language: language)
            : String(format: L10n.string("Found %lld times in this document.", language: language), Int64(occurrences))
    }

    /// The chooser's primary button, by variant and chosen kind.
    static func chooserAction(
        variant: ProtectVariant,
        chosen: EntityType,
        occurrences: Int,
        language: AppLanguage? = nil
    ) -> String {
        let typeName = EntityTypePresentation.localizedName(for: chosen, language: language)
        switch variant {
        case .changeKind:
            return String(format: L10n.string("Change to %@", language: language), typeName as NSString)
        case .protectAgain:
            return String(format: L10n.string("Protect again as %@", language: language), typeName as NSString)
        case .protect:
            return occurrences == 1
                ? L10n.string("Protect 1 Occurrence", language: language)
                : String(format: L10n.string("Protect %lld Occurrences", language: language), Int64(occurrences))
        }
    }

    /// Middle-truncate a value for a menu title or a button label.
    static func menuValue(_ value: String, limit: Int = 24) -> String {
        guard value.count > limit, limit >= 3 else { return value }
        let head = (limit - 1) / 2
        let tail = limit - 1 - head
        return String(value.prefix(head)) + "\u{2026}" + String(value.suffix(tail))
    }
}
