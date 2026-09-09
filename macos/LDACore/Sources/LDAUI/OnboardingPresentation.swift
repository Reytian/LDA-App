//
//  OnboardingPresentation.swift
//  LDAUI
//
//  The first-run wizard's page sequence, the model-tier recommendation, and
//  the copy for pages 1 (language) and 3 (steps), kept apart from the view so
//  they are unit-testable without a rendered SwiftUI body. The model step
//  (page 2) lives in ModelSetupPresentation, which already carries the ask's
//  routing and copy.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation

enum OnboardingPresentation {

    // MARK: - Page sequence

    /// Which page is on screen.
    enum Page: Equatable {
        case language
        case model
        case steps
        case integrations
    }

    /// The first page shown for a given entry mode.
    ///
    /// `.modelAskOnly` (a return visit for an unresolved ask) never repeats
    /// the language question: that sheet only opens after
    /// `hasCompletedFirstRun` is true, so the language question is already
    /// settled and re-asking it every launch would be a ritual.
    static func firstPage(mode: OnboardingView.Mode) -> Page {
        mode == .firstRun ? .language : .model
    }

    /// The page after `page`, or nil to dismiss the sheet.
    static func nextPage(
        after page: Page,
        mode: OnboardingView.Mode,
        hasModel: Bool
    ) -> Page? {
        switch (page, mode) {
        case (.language, _): return hasModel ? .steps : .model
        case (.model, .firstRun): return .steps
        case (.model, .modelAskOnly): return nil
        case (.steps, .firstRun): return .integrations
        case (.steps, .modelAskOnly), (.integrations, _): return nil
        }
    }

    /// Total pages in the sequence for a given entry mode and model state.
    static func pageCount(mode: OnboardingView.Mode, hasModel: Bool) -> Int {
        switch mode {
        case .modelAskOnly: return 1
        case .firstRun: return hasModel ? 3 : 4
        }
    }

    /// 1-indexed position of `page` in the sequence, for the "Step N of M" chip.
    static func position(of page: Page, mode: OnboardingView.Mode, hasModel: Bool) -> Int {
        switch page {
        case .language: return 1
        case .model: return mode == .modelAskOnly ? 1 : 2
        case .steps: return hasModel ? 2 : 3
        case .integrations: return hasModel ? 3 : 4
        }
    }

    /// "Step %lld of %lld", or nil when there is only one page (the chip
    /// renders only when `pageCount > 1`).
    static func stepChip(
        position: Int,
        count: Int,
        language: AppLanguage? = nil
    ) -> String? {
        guard count > 1 else { return nil }
        return String(
            format: L10n.string("Step %lld of %lld", language: language),
            Int64(position),
            Int64(count)
        )
    }

    // MARK: - The model-tier recommendation

    /// The rung the wizard pre-selects. Never Most thorough: it flags more
    /// false positives than Balanced (about one in eight against one in
    /// fifteen) and doubles the wait, and its extra find pays only on a
    /// judgement about the document, not about the Mac.
    static func recommendedLevel(
        catalog: ModelCatalog,
        installedGB: Double = MemoryGate.installedGB()
    ) -> DetectionLevel? {
        for level in [DetectionLevel.balanced, .quick] {
            guard let tier = catalog.tier(for: level) else { continue }
            if MemoryGate.availability(for: tier, installedGB: installedGB) == .available {
                return level
            }
        }
        guard let quick = catalog.tier(for: .quick),
              MemoryGate.availability(for: quick, installedGB: installedGB).isSelectable else {
            return nil
        }
        return .quick
    }

    /// The one line naming the deciding factor for a rung, rendered only when
    /// two or more rungs are selectable on the wizard's model step (on the
    /// 16 GB Mac most PRC lawyers own there is no choice to guide). Also
    /// replaces `DetectionLevel.localizedSummary` for Settings' rung list,
    /// where every rung, including Patterns only, always shows its line.
    static func chooseLine(for level: DetectionLevel, language: AppLanguage? = nil) -> String {
        switch level {
        case .patternsOnly:
            return L10n.string(
                "No model runs. The names of people and organisations are not detected.",
                language: language
            )
        case .quick:
            return L10n.string(
                "Runs on every Mac LDA supports. About one flag in five is one you will dismiss.",
                language: language
            )
        case .balanced:
            return L10n.string(
                "Misses as little as Quick, with a third as much to dismiss.",
                language: language
            )
        case .mostThorough:
            return L10n.string(
                "Missed nothing in testing, including the Chinese bank branch name Balanced missed. About twice the wait of Balanced.",
                language: language
            )
        }
    }

    // MARK: - Page 1: language

    static func languageStepTitle(language: AppLanguage? = nil) -> String {
        L10n.string("Language", language: language)
    }

    static func languageStepExplanation(language: AppLanguage? = nil) -> String {
        L10n.string(
            "Choose the language LDA uses for its interface. Follow System uses your Mac language.",
            language: language
        )
    }

    // MARK: - Page 3: steps

    static func stepsTitle(language: AppLanguage? = nil) -> String {
        L10n.string("Use AI on confidential documents, safely", language: language)
    }

    static func stepsLede(language: AppLanguage? = nil) -> String {
        L10n.string(
            "LDA protects client information before it reaches an AI tool, and puts it back afterwards.",
            language: language
        )
    }

    static func step1Title(language: AppLanguage? = nil) -> String {
        L10n.string("Bring documents in", language: language)
    }

    /// Without a model the shipped sentence must not promise names three
    /// lines below the block that says they are not found: which kinds of
    /// value a scan can find is exactly what the model step above decides.
    static func step1Text(hasModel: Bool, language: AppLanguage? = nil) -> String {
        hasModel
            ? L10n.string(
                "Drop Word, PDF, or text files (or a .zip). The app finds names, companies, dates, amounts, emails, phones, and IDs, and you review what it will protect.",
                language: language
            )
            : L10n.string(
                "Drop Word, PDF, or text files (or a .zip). The app scans each one and you review what it will protect. Which kinds of value it can find depends on the detection model above.",
                language: language
            )
    }

    static func step2Title(language: AppLanguage? = nil) -> String {
        L10n.string("Hand the safe copy to any AI", language: language)
    }

    static func step2Text(language: AppLanguage? = nil) -> String {
        L10n.string(
            "Export for AI saves a redacted Markdown file. Upload it to ChatGPT, Claude, or any tool, with your instructions.",
            language: language
        )
    }

    static func step3Title(language: AppLanguage? = nil) -> String {
        L10n.string("Bring the answer back", language: language)
    }

    static func step3Text(language: AppLanguage? = nil) -> String {
        L10n.string(
            "Restore takes the file the AI gave back and puts the real values in, flagging anything it cannot match with certainty. Save the final document in its original format.",
            language: language
        )
    }

    static func privacyParagraph(language: AppLanguage? = nil) -> String {
        L10n.string(
            "LDA processes document contents and stores the encrypted mapping on this Mac. If you ask it to download a detection model, it connects to the model host. Copying or exporting a document lets you send it to a service you choose, so review that service's privacy settings first.",
            language: language
        )
    }

    static func visibilityCaution(language: AppLanguage? = nil) -> String {
        L10n.string(
            "Anything you choose to keep visible stays visible in the exported document.",
            language: language
        )
    }

    static func clipboardCaution(autoClearSeconds: Int, language: AppLanguage? = nil) -> String {
        String(
            format: L10n.string(
                "Restore Clipboard, in the menu-bar icon, is the one action that puts real values on your clipboard; it tries to clear them again about %lld seconds later, so paste promptly and do not rely on the clearing.",
                language: language
            ),
            Int64(autoClearSeconds)
        )
    }
}
