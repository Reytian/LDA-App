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

    /// The three buttons a gate dialog can carry.
    ///
    /// `fix` leads to the remedy, `proceed` is the one that scans blind or
    /// writes the copy, and `cancel` leaves the state alone.
    enum GateButton: Equatable {
        case fix
        case proceed
        case cancel
    }

    /// Which button Return reaches in a gate dialog.
    ///
    /// The invariant: never `proceed`. The fix owns Return wherever a fix
    /// exists, so an accidental keypress spends bandwidth. Where none does,
    /// Cancel owns it, because the safe path has to be the keypress even when
    /// there is no remedy to offer: a Mac that can run no model never reaches
    /// the scan gate, but it does reach the export gate.
    ///
    /// A decision rather than an ordering, on purpose. It is not established
    /// that SwiftUI's macOS `confirmationDialog` binds Return to the first
    /// listed button, and a sibling dialog in `ClientMatterFlow` lists a
    /// destructive action first with no shortcut at all, so listing the fix
    /// first is not by itself the safety property.
    static func gateDefault(offersFix: Bool) -> GateButton {
        offersFix ? .fix : .cancel
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
    ///
    /// `.download` and `.importOnly` share "Choose a detection model": the
    /// old "First, add a detection model" framed the ask as a chore to clear
    /// before the app was usable, when what the page actually offers is a
    /// choice among four routes (three rungs, an import, or defer).
    static func askTitleKey(route: AskRoute) -> String {
        switch route {
        case .download, .importOnly:
            return "Choose a detection model"
        case .unavailable:
            return "This Mac cannot run a detection model"
        }
    }

    /// The ask page's body paragraphs, in render order.
    ///
    /// `.download` and `.importOnly` collapse to ONE sentence (#10 in the
    /// wizard spec): what a scan without a model does not look for, and what
    /// that means for a copy about to reach an AI tool. The Chinese-street-form
    /// caveat and the twelve-item pattern enumeration that used to sit here
    /// moved to the pre-scan gate (`scanConfirmation`), which fires before any
    /// actual scan and already carries both; repeating them here was reading
    /// the same disclosure twice before anything had happened yet. The
    /// measured "32 of 36" evidence moved to `deferConsequenceLine`, on the
    /// wizard's defer ("Not Now") row, where the decision it informs actually
    /// is.
    static func askBody(route: AskRoute, language: AppLanguage? = nil) -> [String] {
        switch route {
        case .download, .importOnly:
            return [
                L10n.string("Only a detection model finds the names of people and organisations. Without one, those names stay in the document, they are not in the review list, and the copy you hand to an AI tool still identifies your client.", language: language)
            ]
        case .unavailable:
            return [
                L10n.string("This Mac does not have the memory to run a detection model, so LDA does not offer one here. Scans on this Mac match patterns only, and names and company names stay in the document. Adding a model file by hand would not change that.", language: language)
            ]
        }
    }

    /// The measured evidence, shown only on the wizard's defer ("Not Now")
    /// row: what a patterns-only scan still finds, what it measurably misses,
    /// and that LDA asks again before every document. `PatternOnlyRecallClaimTests`
    /// pins the three numbers against `bench/fulldocs`, so this sentence
    /// cannot drift from the corpus in either direction.
    static func deferConsequenceLine(language: AppLanguage? = nil) -> String {
        L10n.string("No model runs. In our own test on two agreements, a scan with no model missed 32 of the 36 names, organisations, and addresses. Fixed formats are still found, and LDA asks again before the first scan of each document.", language: language)
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

    // MARK: - The wizard's model step (page 2)

    /// The model step's title.
    static func modelStepTitle(language: AppLanguage? = nil) -> String {
        L10n.string("Choose a detection model", language: language)
    }

    /// The model step's one sentence, always visible: what a scan without a
    /// model does not look for, and what an exported copy still reveals.
    /// Identical to `askBody(route:)`'s single paragraph for `.download` and
    /// `.importOnly`, kept as its own accessor so the wizard reads as calling
    /// the model step's own copy rather than reaching into the ask's.
    static func modelStepExplanation(language: AppLanguage? = nil) -> String {
        askBody(route: .download, language: language).first ?? ""
    }

    /// The "Recommended" badge on the pre-selected rung.
    static func recommendedBadge(language: AppLanguage? = nil) -> String {
        L10n.string("Recommended", language: language)
    }

    /// Why a rung is recommended: fits with room to spare (the ordinary
    /// case), or offline mode leaves the import as the only route.
    static func recommendedReason(route: AskRoute, language: AppLanguage? = nil) -> String {
        switch route {
        case .importOnly:
            return L10n.string("Recommended because offline mode is on.", language: language)
        case .download, .unavailable:
            return L10n.string("Recommended: it fits this Mac with room to spare and leaves the least to dismiss.", language: language)
        }
    }

    /// "Download and Use": the primary action both installs the tier AND
    /// selects it (`AISettings.setDetectionLevel`), so the button never reads
    /// as an offer the app itself declines to act on.
    static func downloadAndUseButtonTitle(language: AppLanguage? = nil) -> String {
        L10n.string("Download and Use", language: language)
    }

    /// The collapsed sentence naming every rung `MemoryGate` blocks on this
    /// Mac, in ladder order, joined with `ListFormatter` at `language`'s
    /// locale so zh-Hans reads "标准和深度" and fr reads "Équilibré et Le plus
    /// complet" without a separator key of its own.
    static func blockedRungsLine(
        blockedLevels: [DetectionLevel],
        installedGB: Int,
        language: AppLanguage? = nil
    ) -> String {
        let selectedLanguage = language ?? AppLanguage.selected()
        let names = blockedLevels.map { L10n.string($0.displayName, language: language) }
        let formatter = ListFormatter()
        formatter.locale = selectedLanguage.locale
        let joined = formatter.string(from: names) ?? names.joined(separator: ", ")
        return String(
            format: L10n.string(
                "This Mac has %lld GB of memory, so %@ cannot run here.",
                language: language
            ),
            locale: selectedLanguage.locale,
            Int64(installedGB),
            joined as NSString
        )
    }

    /// Names the download host and the offline alternative in one sentence,
    /// on `.download`; states that offline mode is on and names the same
    /// alternative, on `.importOnly`. Stays on screen through `.downloading`,
    /// `.verifying`, `.failed` and `.installed` (`ModelSetupGateTests
    /// .testTheOfflineRemedySurvivesAFailedDownload`), so a mainland download
    /// failure never hides the one route that still works.
    static func provenanceLine(
        route: AskRoute,
        hostDescription: String,
        language: AppLanguage? = nil
    ) -> String {
        switch route {
        case .download:
            return String(
                format: L10n.string(
                    "Downloading connects to %@. If that is unreachable, add a file you got on another Mac.",
                    language: language
                ),
                hostDescription as NSString
            )
        case .importOnly:
            return L10n.string(
                "Offline mode is on, so downloads are off. You can still add a file you got on another Mac.",
                language: language
            )
        case .unavailable:
            return ""
        }
    }

    /// The in-progress and installed lines on the model step, replacing the
    /// old "You can read the next steps while it arrives" / "A scan will look
    /// for names, companies, and addresses" pair, which described a sheet
    /// that no longer has a next page waiting behind the download.
    static func modelDownloadingLine(language: AppLanguage? = nil) -> String {
        L10n.string("Downloading the detection model.", language: language)
    }

    static func modelInstalledLine(language: AppLanguage? = nil) -> String {
        L10n.string(
            "Installed and in use. Scans will now find the names of people and organisations.",
            language: language
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

    /// Why the Export for AI gate is on screen.
    ///
    /// Two different disclosures, and the copy has to keep them apart. A pass
    /// that never ran looked for no names at all. A pass that ran and stopped
    /// short found some names and not others, so its review list reads as a
    /// finished job while the text still holds what the pass never reached,
    /// which is arguably the more dangerous of the two to describe loosely.
    enum ExportGateReason: Equatable {
        case didNotRun
        case ranPartially
    }

    /// Why the export gate must fire, or nil when it must not.
    ///
    /// Pure: the shell maps `session.entries` into it. The `aiFailure` term is
    /// what separates a REQUESTED pass that could not run from a deliberate
    /// patterns-only run, which produces the same entity output and must not
    /// raise a dialog. A document that cannot be exported carries nothing into
    /// the handoff, so it cannot be the reason for one.
    ///
    /// A mixed tray answers `.ranPartially`, because that body describes a
    /// review list the reader will otherwise trust, and its remedy (read the
    /// copy, scan again) covers the never-ran document in the same tray.
    static func exportGateReason(
        documents: [(canExport: Bool, aiRan: Bool, aiFailure: String?, aiRanPartially: Bool)]
    ) -> ExportGateReason? {
        let triggering = documents.filter { !$0.aiRan && $0.aiFailure != nil && $0.canExport }
        guard !triggering.isEmpty else { return nil }
        return triggering.contains(where: \.aiRanPartially) ? .ranPartially : .didNotRun
    }

    /// True when the Export for AI gate must fire at all.
    static func exportNeedsConfirmation(
        documents: [(canExport: Bool, aiRan: Bool, aiFailure: String?, aiRanPartially: Bool)]
    ) -> Bool {
        exportGateReason(documents: documents) != nil
    }

    /// The Export for AI gate's title, message and proceed button.
    ///
    /// A second confirmation sits here rather than on Scan alone because this
    /// is the step that actually discloses. It fires on every Export for AI
    /// while the condition holds: low frequency, and the handoff is the moment
    /// the copy leaves the Mac.
    ///
    /// The partial body does not say the pass "did not run", because it did.
    /// It names what partial coverage means for the list in front of the
    /// reader, and it drops the "add a detection model" remedy, which is
    /// usually already satisfied when a pass got far enough to stop short.
    static func exportConfirmation(
        reason: ExportGateReason,
        language: AppLanguage? = nil
    ) -> (title: String, message: String, proceed: String) {
        switch reason {
        case .didNotRun:
            return (
                title: L10n.string("Export a copy where the AI pass did not run?", language: language),
                message: L10n.string("The AI pass did not run on at least one of these documents, so people's names and company names were not looked for there and are still in the copy you are about to write. Read that copy before you hand it to an AI tool, or add a detection model and scan those documents again.", language: language),
                proceed: L10n.string("Export Anyway", language: language)
            )
        case .ranPartially:
            return (
                title: L10n.string("Export a copy where the AI pass did not finish?", language: language),
                message: L10n.string("The AI pass started on at least one of these documents and did not cover all of it, so some people's names and company names were found there and others were not. A review list can look complete and still be short of what the text holds. Read the copy you are about to write before you hand it to an AI tool, or scan those documents again.", language: language),
                proceed: L10n.string("Export Anyway", language: language)
            )
        }
    }
}
