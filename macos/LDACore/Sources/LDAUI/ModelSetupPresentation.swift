//
//  ModelSetupPresentation.swift
//  LDAUI
//
//  Every sentence and every routing decision behind the first-run model ask,
//  the pre-scan gate and the Export for AI gate. Pure and view-free, in the
//  same spirit as AnonymizeWorkflowPresentation, FillServicePresentation and
//  ModelAnnotation: a claim about what a scan does and does not look for is
//  the one kind of copy that must be testable without a rendered SwiftUI body.
//
//  Why the copy never says "accuracy decreases". Precision is untouched by a
//  missing model. What disappears is three categories from the search space:
//  LLMExtractor.keptTypes is exactly [.person, .company, .address], and with no
//  model the LLM span list is empty, so SpanMerger.merge is a pass-through.
//  "Accuracy decreases" invites the reading "somewhat worse but working". So
//  every sentence here enumerates what is matched, names PERSON and COMPANY as
//  not looked for, and states that an address is matched only in the Chinese
//  street form and stops at the street number.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation

/// The copy and the routing for the model setup flow.
enum ModelSetupPresentation {

    /// Which ask a Mac gets: the real offer, the import-only offer (offline
    /// mode), or the statement (no tier is selectable).
    ///
    /// `.unavailable` is an 8 GB or 12 GB Mac. It gets a statement with one
    /// Continue, no scan gate and an advisory with no button, because a dialog
    /// with no available remedy is a ritual.
    enum AskRoute: Equatable {
        case download
        case importOnly
        case unavailable
    }

    /// The route for a Mac, given what it can run and whether it may download.
    ///
    /// Offline mode makes `canDownload` false for every tier and can be
    /// MDM-forced, so the ask degrades to the checksum-verified import route
    /// rather than offering to turn a security setting off.
    static func askRoute(canRunAModel: Bool, canDownload: Bool) -> AskRoute {
        guard canRunAModel else { return .unavailable }
        return canDownload ? .download : .importOnly
    }

    /// The ask page's title key.
    static func askTitleKey(route: AskRoute) -> String {
        switch route {
        case .download, .importOnly:
            return "First, add a detection model"
        case .unavailable:
            return "This Mac cannot run a detection model"
        }
    }

    /// The ask page's body paragraphs, in render order.
    ///
    /// The third paragraph is the measured evidence and carries the one number
    /// in this flow. It is prose plus a measurement rather than a Found / Not
    /// found grid: a grid is the most authoritative format this app has, and a
    /// Found cell would untrain the distrust the same screen just taught.
    static func askBody(route: AskRoute, language: AppLanguage? = nil) -> [String] {
        switch route {
        case .download, .importOnly:
            return [
                L10n.string("A detection model is what finds people's names and company names. Without one, a scan matches patterns only: emails, phones, dates, amounts, ID numbers, Unified Social Credit Codes, bank accounts, case numbers, license plates, WeChat IDs, links, and seals.", language: language),
                L10n.string("Names and company names are not detected, so they stay in the document, they are not in the review list, and the copy you hand to an AI tool still identifies your client. An address is matched only in the Chinese street form, and the match stops at the street number.", language: language),
                L10n.string("In our own test on two agreements, a scan with no model left 32 of the 36 names, companies, and addresses in place, and matched the other 4 only in part.", language: language)
            ]
        case .unavailable:
            return [
                L10n.string("This Mac does not have the memory to run a detection model, so LDA does not offer one here. Scans on this Mac match patterns only, and names and company names stay in the document. Adding a model file by hand would not change that.", language: language)
            ]
        }
    }

    /// The primary button on the ask page and in the scan dialog.
    ///
    /// The size comes from `ModelTier.downloadSizeDescription`, which reads
    /// Models.json, so the number in the button has one source of truth and
    /// cannot fork from the manifest.
    static func downloadButtonTitle(
        sizeDescription: String,
        language: AppLanguage? = nil
    ) -> String {
        String(
            format: L10n.string("Download the Model (%@)", language: language),
            sizeDescription as NSString
        )
    }

    /// The pre-scan gate's title, message and proceed button.
    static func scanConfirmation(
        language: AppLanguage? = nil
    ) -> (title: String, message: String, proceed: String) {
        (
            title: L10n.string("Scan without a detection model?", language: language),
            message: L10n.string("This scan will not look for people's names or company names, and it matches an address only in the Chinese street form, stopping at the street number. Those values stay in the document and are not in the review list. Emails, phones, dates, amounts, ID numbers, case numbers, bank accounts, license plates, WeChat IDs, links, and seals are still found.", language: language),
            proceed: L10n.string("Scan Without Names", language: language)
        )
    }

    /// The Export for AI gate's title, message and proceed button.
    ///
    /// A second confirmation sits here rather than on Scan alone because this
    /// is the step that actually discloses. It fires on every Export for AI
    /// while the condition holds: low frequency, and the handoff is the moment
    /// the copy leaves the Mac.
    static func exportConfirmation(
        language: AppLanguage? = nil
    ) -> (title: String, message: String, proceed: String) {
        (
            title: L10n.string("Export a copy where the AI pass did not run?", language: language),
            message: L10n.string("The AI pass did not run on at least one of these documents, so people's names and company names were not looked for there and are still in the copy you are about to write. Read that copy before you hand it to an AI tool, or add a detection model and scan those documents again.", language: language),
            proceed: L10n.string("Export Anyway", language: language)
        )
    }

    /// True when at least one exportable document had an AI pass that was
    /// asked for and did not run.
    ///
    /// Pure: the shell maps `session.entries` into it. The `aiFailure` term is
    /// what separates a REQUESTED pass that could not run from a deliberate
    /// patterns-only run, which produces the same entity output and must not
    /// raise a dialog. A document that cannot be exported carries nothing into
    /// the handoff, so it cannot be the reason for one.
    static func exportNeedsConfirmation(
        documents: [(canExport: Bool, aiRan: Bool, aiFailure: String?)]
    ) -> Bool {
        documents.contains { !$0.aiRan && $0.aiFailure != nil && $0.canExport }
    }
}
