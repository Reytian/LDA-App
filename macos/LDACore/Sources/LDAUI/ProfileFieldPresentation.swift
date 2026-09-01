//
//  ProfileFieldPresentation.swift
//  LDAUI
//
//  Localized display names for stable profile field wire keys.
//

import LDACore

enum ProfileFieldPresentation {
    static func localizedName(
        for key: ProfileFieldKey,
        language: AppLanguage? = nil
    ) -> String {
        if case .custom(let name) = key {
            return name
        }
        return L10n.string(key.displayName, language: language)
    }
}
