//
//  RestoreResultPresentation.swift
//  LDAUI
//
//  Shared user-facing copy for restore outcomes that need the reader's
//  attention. Pure functions so the wording is testable without a view.
//
//  House rules: Localized user-facing copy. No separator dashes.
//

import Foundation

/// Copy shared by the restore surfaces (the de-anonymize window and the
/// session's restore card).
public enum RestoreResultPresentation {

    /// How many examples a warning sentence lists before it stops.
    static let sampleLimit = 5

    /// Which key opened the file. Named in the result so a stale .ldamap
    /// moved next to a new file is visible, not silent.
    public enum KeySource: Equatable {
        /// The session mapping (in memory, resumed, or the matter's).
        case session
        /// The .ldamap saved next to the file.
        case sidecar
        /// A .ldamap the user picked by hand.
        case chosenMapping
    }

    /// The sentence naming which key opened the file.
    static func keySentence(
        for source: KeySource,
        language: AppLanguage? = nil
    ) -> String {
        switch source {
        case .session:
            return L10n.string("Restored with this session's mapping.", language: language)
        case .sidecar:
            return L10n.string("Restored with the mapping saved next to the file.", language: language)
        case .chosenMapping:
            return L10n.string("Restored with the mapping you chose.", language: language)
        }
    }

    /// The compact completion sentence used while the restored text is still
    /// in the paste sheet and has not been saved to a file yet.
    static func restoredSentence(
        _ restoredCount: Int,
        language: AppLanguage? = nil
    ) -> String {
        format(
            restoredCount == 1
                ? "Restored %lld value."
                : "Restored %lld values.",
            language: language,
            arguments: [Int64(restoredCount)]
        )
    }

    /// The clean completion sentence shown when every protected value was
    /// restored without review warnings.
    static func cleanResult(
        restoredCount: Int,
        outputFileName: String,
        keyNote: String? = nil,
        language: AppLanguage? = nil
    ) -> String {
        let summary = format(
            restoredCount == 1
                ? "Restored %lld value to %@."
                : "Restored %lld values to %@.",
            language: language,
            arguments: [Int64(restoredCount), outputFileName as NSString]
        )
        return ([summary] + (keyNote.map { [$0] } ?? [])).joined(separator: " ")
    }

    /// The sentence for placeholders that no longer match the mapping.
    /// Returns nil when there is nothing to report.
    static func orphanSentence(
        _ orphanTokens: [String],
        language: AppLanguage? = nil
    ) -> String? {
        guard !orphanTokens.isEmpty else { return nil }
        let count = orphanTokens.count
        let sample = orphanTokens.prefix(sampleLimit).joined(separator: ", ")
        return format(
            count == 1
                ? "%lld placeholder could not be matched: %@."
                : "%lld placeholders could not be matched: %@.",
            language: language,
            arguments: [Int64(count), sample as NSString]
        )
    }

    /// The sentence for placeholders whose characters were changed while the
    /// document was edited. Returns nil when there is nothing to report.
    static func damagedSentence(
        _ suspectPlaceholders: [String],
        language: AppLanguage? = nil
    ) -> String? {
        guard !suspectPlaceholders.isEmpty else { return nil }
        let count = suspectPlaceholders.count
        let sample = suspectPlaceholders.prefix(sampleLimit).joined(separator: ", ")
        return format(
            count == 1
                ? "%lld placeholder looks damaged by editing: %@."
                : "%lld placeholders look damaged by editing: %@.",
            language: language,
            arguments: [Int64(count), sample as NSString]
        )
    }

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
    static func ambiguousSentence(
        _ ambiguousReplacements: [String],
        language: AppLanguage? = nil
    ) -> String? {
        guard !ambiguousReplacements.isEmpty else { return nil }
        let count = ambiguousReplacements.count
        let sample = ambiguousReplacements.prefix(sampleLimit).joined(separator: ", ")
        return format(
            count == 1
                ? "%lld masked form is shared by more than one entity: %@. That site was left as-is rather than guessed; check it against your own records."
                : "%lld masked forms are shared by more than one entity: %@. Those sites were left as-is rather than guessed; check them against your own records.",
            language: language,
            arguments: [Int64(count), sample as NSString]
        )
    }

    /// The complete warning result. Problem sentences are already localized
    /// and their raw samples remain untouched.
    static func warningResult(
        restoredCount: Int,
        problems: [String],
        outputFileName: String,
        keyNote: String? = nil,
        language: AppLanguage? = nil
    ) -> String {
        let summary = format(
            restoredCount == 1
                ? "Restored %lld value with warnings."
                : "Restored %lld values with warnings.",
            language: language,
            arguments: [Int64(restoredCount)]
        )
        let review = format(
            "Nothing was guessed; review these in %@ and fix them by hand.",
            language: language,
            arguments: [outputFileName as NSString]
        )
        return ([summary] + problems + [review] + (keyNote.map { [$0] } ?? [])).joined(separator: " ")
    }

    /// The failure sentence keeps the system-provided error description
    /// exactly as received while translating the surrounding app copy.
    static func failureResult(
        errorDescription: String,
        language: AppLanguage? = nil
    ) -> String {
        format(
            "Restore failed. %@",
            language: language,
            arguments: [errorDescription as NSString]
        )
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
