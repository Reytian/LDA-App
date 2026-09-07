//
//  RestorePreviewPresentation.swift
//  LDAUI
//
//  The copy the Restore preview sheet shows, as pure functions so the wording
//  is testable without a view.
//
//  The warning sentences are the SAME ones RestoreResultPresentation already
//  wrote for the result banner. That is deliberate reuse, not duplication: the
//  facts a reader needs about an orphan token, a damaged placeholder or an
//  ambiguous mask do not change depending on whether the file has been written
//  yet, and having one wording means the sheet and the banner can never
//  describe the same document differently.
//
//  House rules: Localized user-facing copy. No separator dashes.
//

import Foundation
import LDACore

/// Copy for the sheet that shows a restore before it is written.
enum RestorePreviewPresentation {

    /// The forward-looking count sentence. Deliberately future tense: nothing
    /// has been written when this is read, and "Restored 4 values" on a sheet
    /// that has written nothing would be a lie the reader acts on.
    static func pendingSentence(
        _ restoredCount: Int,
        language: AppLanguage? = nil
    ) -> String {
        let key = restoredCount == 1
            ? "%lld value will be restored."
            : "%lld values will be restored."
        let selected = language ?? AppLanguage.selected()
        return String(
            format: L10n.string(key, language: language),
            locale: selected.locale,
            arguments: [Int64(restoredCount)]
        )
    }

    /// Every warning this preview carries, in the order the result banner
    /// lists them. Empty when the restore is clean.
    static func warnings(
        _ preview: RestorePreview,
        language: AppLanguage? = nil
    ) -> [String] {
        [
            RestoreResultPresentation.orphanSentence(preview.orphanTokens, language: language),
            RestoreResultPresentation.damagedSentence(
                preview.suspectPlaceholders,
                language: language
            ),
            RestoreResultPresentation.ambiguousSentence(
                preview.ambiguousReplacements,
                language: language
            )
        ].compactMap { $0 }
    }

    /// The sentence that says why the warned items have no field to type in.
    ///
    /// Shown only when there is something warned about, so a clean restore
    /// does not explain a restriction the reader never met. See
    /// RestorePreviewModel for the reasoning this sentence summarizes.
    static func refusalNote(
        _ preview: RestorePreview,
        language: AppLanguage? = nil
    ) -> String? {
        guard !warnings(preview, language: language).isEmpty else { return nil }
        // One unbroken literal on purpose: the localization scan reads the
        // FIRST string literal in an L10n call as the catalog key, so a key
        // split with + would ask the catalogs for its opening fragment.
        return L10n.string(
            "These cannot be corrected here. A placeholder that is missing from the mapping or damaged by editing is not a recorded value, and a masked form several entities share has no single owner. Settle those by hand in the saved document.",
            language: language
        )
    }

    /// The refusal when the file changed between the preview and the write.
    ///
    /// States that nothing was written, because the reader chose a
    /// destination and will otherwise go looking for a file that is not
    /// there, and names the only remedy: preview it again. See
    /// RestoreSourceGuard.swift.
    static func sourceChangedRefusal(language: AppLanguage? = nil) -> String {
        // One unbroken literal on purpose; see refusalNote above.
        L10n.string(
            "This file changed after the preview was computed, so the document that would be written is not the one you approved. Nothing was written. Open the file again to preview it as it is now.",
            language: language
        )
    }
}
