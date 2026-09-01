//
//  Localization.swift
//  LDAUI
//
//  Runtime localization support for the SwiftPM UI resource bundle.
//

import Foundation

enum LDAResourceBundle {
    static func resolve(explicit: Bundle? = nil) -> Bundle? {
        if let explicit { return explicit }

        let resourceBundleName = "LDACore_LDAUI.bundle"
        var candidates: [Bundle] = []

        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(
               path: resources.appendingPathComponent(resourceBundleName).path
           ) {
            candidates.append(bundle)
        }

        if let bundle = Bundle(
            path: Bundle.main.bundleURL
                .appendingPathComponent(resourceBundleName)
                .path
        ) {
            candidates.append(bundle)
        }

        let codeBundle = Bundle(for: LocalizationBundleToken.self)
        let siblingURL = codeBundle.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(resourceBundleName)
        if let bundle = Bundle(path: siblingURL.path) {
            candidates.append(bundle)
        }

        candidates.append(codeBundle)
        candidates.append(Bundle.main)

        return candidates.first { candidate in
            supportedLocalizationIdentifiers.contains { identifier in
                localizationBundle(identifier, inside: candidate) != nil
            }
        }
    }

    static let supportedLocalizationIdentifiers = [
        AppLanguage.english.rawValue,
        AppLanguage.french.rawValue,
        AppLanguage.simplifiedChinese.rawValue,
        AppLanguage.traditionalChinese.rawValue
    ]

    static func localizationBundle(
        _ identifier: String,
        inside bundle: Bundle
    ) -> Bundle? {
        let candidates = [identifier, identifier.lowercased()]
        for candidate in candidates {
            guard let path = bundle.path(forResource: candidate, ofType: "lproj"),
                  let localizedBundle = Bundle(path: path) else {
                continue
            }
            return localizedBundle
        }
        return nil
    }
}

public enum L10n {
    public static func string(
        _ key: String,
        language: AppLanguage? = nil,
        defaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages,
        bundle: Bundle? = nil
    ) -> String {
        let selectedLanguage = language ?? AppLanguage.selected(defaults: defaults)
        let identifier = localizationIdentifier(
            for: selectedLanguage,
            preferredLanguages: preferredLanguages
        )

        guard let resourceBundle = LDAResourceBundle.resolve(explicit: bundle) else {
            return key
        }

        if let localizedBundle = LDAResourceBundle.localizationBundle(
            identifier,
            inside: resourceBundle
        ) {
            return localizedBundle.localizedString(
                forKey: key,
                value: key,
                table: nil
            )
        }

        if identifier != AppLanguage.english.rawValue,
           let englishBundle = LDAResourceBundle.localizationBundle(
               AppLanguage.english.rawValue,
               inside: resourceBundle
           ) {
            return englishBundle.localizedString(
                forKey: key,
                value: key,
                table: nil
            )
        }

        return key
    }

    static func localizationIdentifier(
        for language: AppLanguage,
        preferredLanguages: [String]
    ) -> String {
        guard language == .system else { return language.rawValue }

        for preferredLanguage in preferredLanguages {
            let locale = Locale(identifier: preferredLanguage)
            let languageCode = locale.language.languageCode?.identifier.lowercased()

            switch languageCode {
            case "en":
                return AppLanguage.english.rawValue
            case "fr":
                return AppLanguage.french.rawValue
            case "zh":
                let script = locale.language.script?.identifier.lowercased()
                let region = locale.region?.identifier.uppercased()
                if script == "hans" {
                    return AppLanguage.simplifiedChinese.rawValue
                }
                if script == "hant" {
                    return AppLanguage.traditionalChinese.rawValue
                }
                if ["HK", "MO", "TW"].contains(region) {
                    return AppLanguage.traditionalChinese.rawValue
                }
                return AppLanguage.simplifiedChinese.rawValue
            default:
                continue
            }
        }

        return AppLanguage.english.rawValue
    }
}

private final class LocalizationBundleToken {}
