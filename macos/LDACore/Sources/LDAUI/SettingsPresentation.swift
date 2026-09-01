//
//  SettingsPresentation.swift
//  LDAUI
//
//  Localized presentation for dynamic Settings copy. User and file names are
//  inserted as data after the interface sentence has been resolved.
//

import Foundation

enum SettingsHistoryPresentation {
    static func documentsLine(
        protectedValueCount: Int,
        documentSummaries: [String],
        language: AppLanguage? = nil
    ) -> String {
        let key = protectedValueCount == 1
            ? "%lld identity protected across: %@"
            : "%lld identities protected across: %@"
        return format(
            key,
            language: language,
            arguments: [
                Int64(protectedValueCount),
                documentSummaries.joined(separator: ", ") as NSString
            ]
        )
    }

    static func restoresLine(
        restoreCount: Int,
        restoredValueCount: Int,
        flaggedCount: Int,
        language: AppLanguage? = nil
    ) -> String {
        guard restoreCount > 0 else {
            return L10n.string("Not restored yet.", language: language)
        }

        let key: String
        switch (restoreCount == 1, restoredValueCount == 1) {
        case (true, true):
            key = "%lld restore, %lld value put back."
        case (true, false):
            key = "%lld restore, %lld values put back."
        case (false, true):
            key = "%lld restores, %lld value put back."
        case (false, false):
            key = "%lld restores, %lld values put back."
        }

        var line = format(
            key,
            language: language,
            arguments: [Int64(restoreCount), Int64(restoredValueCount)]
        )
        if flaggedCount > 0 {
            let flaggedKey = flaggedCount == 1
                ? " %lld item flagged for review."
                : " %lld items flagged for review."
            line += format(
                flaggedKey,
                language: language,
                arguments: [Int64(flaggedCount)]
            )
        }
        return line
    }

    static func displayDate(
        _ iso: String,
        language: AppLanguage? = nil
    ) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let formatter = DateFormatter()
        formatter.locale = (language ?? AppLanguage.selected()).locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func format(
        _ key: String,
        language: AppLanguage?,
        arguments: [CVarArg]
    ) -> String {
        String(
            format: L10n.string(key, language: language),
            locale: (language ?? AppLanguage.selected()).locale,
            arguments: arguments
        )
    }
}

enum SettingsSharingPresentation {
    static func counts(
        vocabularyCount: Int,
        learnedCount: Int,
        language: AppLanguage? = nil
    ) -> String {
        format(
            "Vocabulary terms: %lld  ·  Learned entries: %lld",
            language: language,
            arguments: [Int64(vocabularyCount), Int64(learnedCount)]
        )
    }

    static func exported(
        vocabularyCount: Int,
        learnedCount: Int,
        language: AppLanguage? = nil
    ) -> String {
        format(
            "Exported vocabulary terms: %lld. Exported learned entries: %lld.",
            language: language,
            arguments: [Int64(vocabularyCount), Int64(learnedCount)]
        )
    }

    static func imported(
        vocabularyCount: Int,
        learnedCount: Int,
        language: AppLanguage? = nil
    ) -> String {
        format(
            "Imported new vocabulary terms: %lld. Merged learned entries: %lld.",
            language: language,
            arguments: [Int64(vocabularyCount), Int64(learnedCount)]
        )
    }

    static func exportFailure(
        _ detail: String,
        language: AppLanguage? = nil
    ) -> String {
        format(
            "Export failed. %@",
            language: language,
            arguments: [detail as NSString]
        )
    }

    static var preparationFailure: String {
        L10n.string("Could not prepare the profile.")
    }

    static var invalidProfile: String {
        L10n.string("That file is not a valid LDA vocabulary profile.")
    }

    private static func format(
        _ key: String,
        language: AppLanguage?,
        arguments: [CVarArg]
    ) -> String {
        String(
            format: L10n.string(key, language: language),
            locale: (language ?? AppLanguage.selected()).locale,
            arguments: arguments
        )
    }
}
