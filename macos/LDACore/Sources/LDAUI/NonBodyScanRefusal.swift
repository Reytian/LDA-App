//
//  NonBodyScanRefusal.swift
//  LDAUI
//
//  Why a .docx export refused a header, footer, note or comment (review
//  2026-11-11, F9). Those parts obey the body's gates, but the user never
//  reviews them, so the export says what failed and what to do instead of
//  writing a copy that still holds the value.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

enum NonBodyScanRefusal: Error, Equatable {
    /// The model failed or did not finish a part.
    case notScanned
    /// The model found values in a part that could not be removed.
    case valuesLeft(Int)

    /// The localized sentence the export shows.
    func message(language: AppLanguage? = nil) -> String {
        switch self {
        case .notScanned:
            return L10n.string(
                "A header, footer, note or comment could not be scanned completely, so the redacted copy was not written. Export again, or choose another detection level in Settings.",
                language: language
            )
        case .valuesLeft(let count):
            return String(
                format: L10n.string(
                    "A header, footer, note or comment holds %lld detected value(s) that could not be removed, so the redacted copy was not written. Edit that part in Word and export again.",
                    language: language
                ),
                locale: (language ?? AppLanguage.selected()).locale,
                Int64(count)
            )
        }
    }
}
