//
//  PseudonymOverrideErrorPresentation.swift
//  LDAUI
//
//  Localized presentation for typed pseudonym override validation failures.
//  User-provided text remains verbatim while the surrounding explanation
//  follows the selected interface language.
//

import Foundation
import LDACore

enum PseudonymOverrideErrorPresentation {
    static func message(
        for error: PseudonymOverrideError,
        language: AppLanguage? = nil
    ) -> String {
        switch error {
        case .styleNotPseudonym(let style):
            return format(
                "Custom replacement text is available only with Pseudonyms. Current setting: %@.",
                language: language,
                arguments: [styleName(style, language: language) as NSString]
            )
        case .empty(let surface):
            guard !surface.isEmpty else {
                return L10n.string(
                    "A custom replacement needs non-empty original text.",
                    language: language
                )
            }
            return format(
                "The custom replacement for \"%@\" must not be empty.",
                language: language,
                arguments: [surface as NSString]
            )
        case .containsBraces(let surface, _):
            return format(
                "The custom replacement for \"%@\" must not contain braces.",
                language: language,
                arguments: [surface as NSString]
            )
        case .collidesWithExistingReplacement(let surface, let replacement):
            return format(
                "The custom replacement \"%@\" for \"%@\" is already used for another entity.",
                language: language,
                arguments: [replacement as NSString, surface as NSString]
            )
        case .occursNaturallyInCorpus(let surface, let replacement):
            return format(
                "The custom replacement \"%@\" for \"%@\" already appears in the session documents.",
                language: language,
                arguments: [replacement as NSString, surface as NSString]
            )
        case .prefixOfAnotherReplacement(let surface, let replacement, let other):
            return format(
                "The custom replacement \"%@\" for \"%@\" and the replacement \"%@\" overlap at the beginning, so Restore could substitute the wrong entity. Choose replacements that do not begin with one another.",
                language: language,
                arguments: [
                    replacement as NSString,
                    surface as NSString,
                    other as NSString
                ]
            )
        case .seamSpellsAnotherReplacement(let surface, let replacement, let other):
            return format(
                "The custom replacement \"%@\" for \"%@\" runs together with nearby document text to form \"%@\", so Restore could substitute the wrong entity. Choose replacement text that remains distinct beside the surrounding text.",
                language: language,
                arguments: [
                    replacement as NSString,
                    surface as NSString,
                    other as NSString
                ]
            )
        }
    }

    private static func styleName(
        _ style: SubstitutionStyle,
        language: AppLanguage?
    ) -> String {
        let key: String
        switch style {
        case .token: key = "Placeholders"
        case .pseudonym: key = "Pseudonyms"
        case .asterisk: key = "Asterisks"
        }
        return L10n.string(key, language: language)
    }

    private static func format(
        _ key: String,
        language: AppLanguage?,
        arguments: [CVarArg]
    ) -> String {
        let selectedLanguage = language ?? AppLanguage.selected()
        return String(
            format: L10n.string(key, language: language),
            locale: selectedLanguage.locale,
            arguments: arguments
        )
    }
}
