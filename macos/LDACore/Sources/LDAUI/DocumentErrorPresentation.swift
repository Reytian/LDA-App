//
//  DocumentErrorPresentation.swift
//  LDAUI
//
//  Localized wrappers for document failures. Engine details remain verbatim.
//

import Foundation
import LDACore

enum DocumentErrorPresentation {
    /// Translate errors the app owns and preserve an unknown system or engine
    /// description exactly as received.
    static func describeOrFallback(
        _ error: Error,
        language: AppLanguage? = nil
    ) -> String {
        describe(error, language: language) ?? error.localizedDescription
    }

    static func describe(
        _ error: Error,
        language: AppLanguage? = nil
    ) -> String? {
        guard let ioError = error as? DocumentIOError else { return nil }
        let locale = (language ?? AppLanguage.selected()).locale
        switch ioError {
        case .unreadable(let detail):
            return format("The file could not be read. %@", detail, language, locale)
        case .unsupportedFormat(let detail):
            return format("Unsupported format. %@", detail, language, locale)
        case .corrupt(let detail):
            return format("The file is corrupt. %@", detail, language, locale)
        case .ocrUnavailable:
            return L10n.string("OCR is unavailable on this system.", language: language)
        case .decryptionFailed:
            return L10n.string("The document could not be decrypted.", language: language)
        case .keychainError(let status):
            return String(
                format: L10n.string(
                    "A Keychain error occurred (status %lld).",
                    language: language
                ),
                locale: locale,
                Int64(status)
            )
        case .tooLarge(let detail):
            return format("That file is too large to open. %@", detail, language, locale)
        }
    }

    private static func format(
        _ key: String,
        _ detail: String,
        _ language: AppLanguage?,
        _ locale: Locale
    ) -> String {
        String(
            format: L10n.string(key, language: language),
            locale: locale,
            detail as NSString
        )
    }
}
