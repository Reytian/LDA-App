//
//  GuidedWorkflowPresentation.swift
//  LDAUI
//
//  Pure presentation decisions shared by the guided Anonymize and Fill flows.
//  Keeping these choices outside the views makes step progression and primary
//  action selection deterministic and testable.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import SwiftUI
import LDACore

enum AnonymizeWorkflowStep: Int, CaseIterable, Equatable {
    case add
    case scan
    case review
    case share

    var title: String {
        switch self {
        case .add: return "Add"
        case .scan: return "Scan"
        case .review: return "Review"
        case .share: return "Share"
        }
    }

    var systemImage: String {
        switch self {
        case .add: return "doc.badge.plus"
        case .scan: return "text.magnifyingglass"
        case .review: return "checkmark.shield"
        case .share: return "square.and.arrow.up"
        }
    }
}

enum AnonymizeWorkflowPresentation {
    static func currentStep(
        status: ReviewStatus,
        hasDocument: Bool,
        hasSharedOutput: Bool
    ) -> AnonymizeWorkflowStep {
        if hasSharedOutput { return .share }

        switch status {
        case .idle, .importing:
            return .add
        case .imported, .detecting:
            return .scan
        case .ready:
            return .review
        case .failed:
            return hasDocument ? .scan : .add
        }
    }

    static func hasSharedActiveDocument(
        activeDocumentID: UUID?,
        includedDocumentIDs: Set<UUID>
    ) -> Bool {
        guard let activeDocumentID else { return false }
        return includedDocumentIDs.contains(activeDocumentID)
    }

    static func exportCompletionDetail(
        documentCount: Int,
        skippedCount: Int,
        fileName: String,
        language: AppLanguage? = nil
    ) -> String {
        let readyKey = documentCount == 1
            ? "%lld redacted document is in %@. Upload it to your AI tool, then bring the answer back in Restore."
            : "%lld redacted documents are in %@. Upload it to your AI tool, then bring the answer back in Restore."
        var detail = String(
            format: L10n.string(readyKey, language: language),
            Int64(documentCount),
            fileName as NSString
        )

        if skippedCount > 0 {
            let skippedKey = skippedCount == 1
                ? "%lld unscanned document was not included."
                : "%lld unscanned documents were not included."
            detail += " " + String(
                format: L10n.string(skippedKey, language: language),
                Int64(skippedCount)
            )
        }
        return detail
    }

    static func detectingLabel(
        progress: Double,
        eta: String?,
        language: AppLanguage? = nil
    ) -> String {
        let percent = Int64((progress * 100).rounded())
        guard let eta else {
            return String(
                format: L10n.string("Spotting PII %lld%%", language: language),
                percent
            )
        }
        return String(
            format: L10n.string("Spotting PII %lld%%  \u{00B7}  %@", language: language),
            percent,
            eta as NSString
        )
    }

    static func exportForAIHelp(
        ready: Int,
        candidates: Int,
        language: AppLanguage? = nil
    ) -> String {
        guard candidates > 1 else {
            return L10n.string(
                "Save the redacted text as one Markdown file to upload to any AI tool.",
                language: language
            )
        }
        return String(
            format: L10n.string(
                "Save the redacted text from %lld of %lld documents (only the ones already scanned are included) as one Markdown file to upload to any AI tool.",
                language: language
            ),
            Int64(ready),
            Int64(candidates)
        )
    }

    /// DOCX with tracked changes: the count and what the redactor does with
    /// them, or nil for a plain document. Both sentences live in one place so
    /// the advice and the author-blanking fact are never shown apart.
    static func trackedChangesAdvice(
        count: Int,
        language: AppLanguage? = nil
    ) -> String? {
        guard count > 0 else { return nil }
        let warning = String(
            format: L10n.string(
                "This document carries tracked changes (%lld). Accept all changes before redacting for an exact round trip; a value that spans a tracked change is restored into the live text and the change is flattened.",
                language: language
            ),
            Int64(count)
        )
        let authors = L10n.string(
            "Tracked-change and comment authors are blanked in the redacted copy and are not restored.",
            language: language
        )
        return warning + " " + authors
    }

    /// No model for the selected rung: what a scan will and will not look for,
    /// or nil when the rung has its model.
    ///
    /// Pure so it is unit-testable without a view, and phrased as an
    /// enumeration rather than a totalising claim: it lists what patterns match
    /// and states plainly that names, companies and addresses are not looked
    /// for. Do NOT add a reassuring clause such as "everything else is found"
    /// while polishing this; it is false, and it is close to a claim
    /// UIClaimsDisciplineTests bans outright.
    ///
    /// Four sentences because there are four situations and telling them apart
    /// matters. `hasAnyModel` false is a fresh install with nothing at all.
    /// `hasAnyModel` true is the reachable case on a Mac with 24 GB or more:
    /// the user installed Balanced from Manage Models and left the level on
    /// Quick, so the selected rung still cannot run. Saying "no detection model
    /// is installed" to that user would be a false sentence, which is the exact
    /// defect class this advisory exists to prevent.
    ///
    /// The two later parameters cover the two states the row was silent about.
    /// `canRunAModel` false is an 8 GB or 12 GB Mac, where "add a model" is
    /// advice the user cannot take, so the sentence states the limit and stops
    /// and the caller renders no button. `rungUsesLLM` false with no file
    /// anywhere is the genuinely silent one: `isModelMissing` short-circuits on
    /// the rung, so a patterns-only user with no model got no advisory, no
    /// dialog and only a neutral grey label, forever. It is reachable through
    /// the legacy `detectionMode == "fast"` migration, not just by choosing it.
    ///
    /// Both new parameters default to the pre-existing behaviour so every
    /// existing call site and both pinned nil-cases are unchanged.
    static func missingModelAdvice(
        isModelMissing: Bool,
        hasAnyModel: Bool,
        rungUsesLLM: Bool = true,
        canRunAModel: Bool = true,
        language: AppLanguage? = nil
    ) -> String? {
        if !canRunAModel, !hasAnyModel {
            return L10n.string(
                "This Mac does not have the memory to run a detection model, so scans here match patterns only. People's names and company names stay in the document.",
                language: language
            )
        }
        if !hasAnyModel, !rungUsesLLM {
            return L10n.string(
                "Patterns only is selected and no detection model is installed, so no scan on this Mac looks for people's names or company names. Those names stay in the document. Add a model, then choose a detection level in Settings.",
                language: language
            )
        }
        guard isModelMissing else { return nil }
        guard hasAnyModel else {
            return L10n.string(
                "No detection model is installed, so this scan will not look for people's names or company names, and it matches an address only in the Chinese street form. It still finds emails, phones, dates, amounts, ID numbers, and case numbers. Add a model to find names.",
                language: language
            )
        }
        return L10n.string(
            "The model for the detection level you chose is not installed, so this scan will not look for people's names or company names, and it matches an address only in the Chinese street form. It still finds emails, phones, dates, amounts, ID numbers, and case numbers. Add that model, or choose an installed level in Settings.",
            language: language
        )
    }

    static func embeddedMediaWarning(
        count: Int,
        language: AppLanguage? = nil
    ) -> String? {
        guard count > 0 else { return nil }
        let key = count == 1
            ? "Warning: %lld embedded image was copied without scanning."
            : "Warning: %lld embedded images were copied without scanning."
        return String(
            format: L10n.string(key, language: language),
            Int64(count)
        )
    }

    /// Why the coverage number is larger than the review list.
    ///
    /// A .docx is redacted in its headers, footers, notes, and comments too,
    /// and those hits are not offered for review, so without this line a
    /// careful reader counts the list, finds fewer items, and doubts the
    /// number. Nil when nothing sits outside the body.
    static func supplementaryCoverageNote(
        count: Int,
        language: AppLanguage? = nil
    ) -> String? {
        guard count > 0 else { return nil }
        let key = count == 1
            ? "Includes %lld value in headers, footers, or notes, always protected and not listed above."
            : "Includes %lld values in headers, footers, or notes, always protected and not listed above."
        return String(
            format: L10n.string(key, language: language),
            Int64(count)
        )
    }

    static func etaText(
        seconds: Double,
        language: AppLanguage? = nil
    ) -> String {
        let total = max(1, Int(seconds.rounded()))
        if total < 60 {
            return String(
                format: L10n.string("about %llds remaining", language: language),
                Int64(total)
            )
        }
        let minutes = total / 60
        let seconds = total % 60
        if seconds == 0 {
            return String(
                format: L10n.string("about %lldm remaining", language: language),
                Int64(minutes)
            )
        }
        return String(
            format: L10n.string("about %lldm %llds remaining", language: language),
            Int64(minutes),
            Int64(seconds)
        )
    }

    /// The banner sentence for documents the cross-document sweep did not
    /// reach: which ones still carry a party another document confirmed, and
    /// the one action that fixes it. Value-free, so the banner never restates
    /// the PII it is warning about. Returns nil when there is nothing to say.
    ///
    /// Two sentences, because there are two different fixes. A party Scan
    /// would surface is closed by re-scanning. A party the user has net
    /// rejected before is dropped by learned suppression AFTER the sweep, so
    /// re-scanning is a no-op and the honest advice is to confirm it by hand
    /// (or forget the learned entry in Settings). Telling that user to run
    /// Scan leaves a banner they can never clear.
    static func rescanAdvice(
        for warnings: [SessionModel.RescanWarning],
        language: AppLanguage? = nil
    ) -> String? {
        guard !warnings.isEmpty else { return nil }
        let sentences = [
            rescanSentence(
                for: warnings.filter { $0.rescannablePartyCount > 0 },
                language: language
            ),
            suppressedSentence(
                for: warnings.filter { $0.suppressedPartyCount > 0 },
                language: language
            )
        ].compactMap { $0 }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// The gap a re-scan really would close.
    private static func rescanSentence(
        for warnings: [SessionModel.RescanWarning],
        language: AppLanguage?
    ) -> String? {
        guard !warnings.isEmpty else { return nil }
        let names = warnings.map(\.documentName).joined(separator: ", ")
        let total = warnings.reduce(0) { $0 + $1.rescannablePartyCount }
        let key: String
        if warnings.count == 1 {
            key = total == 1
                ? "%@ still contains 1 name protected elsewhere in this session. Run Scan on it again, then export again."
                : "%@ still contains %lld names protected elsewhere in this session. Run Scan on it again, then export again."
        } else {
            key = total == 1
                ? "%@ still contain 1 name protected elsewhere in this session. Run Scan on them again, then export again."
                : "%@ still contain %lld names protected elsewhere in this session. Run Scan on them again, then export again."
        }
        if total == 1 {
            return String(
                format: L10n.string(key, language: language),
                names as NSString
            )
        }
        return String(
            format: L10n.string(key, language: language),
            names as NSString,
            Int64(total)
        )
    }

    /// The gap a re-scan would refuse to close, because the user already
    /// decided against redacting the value.
    private static func suppressedSentence(
        for warnings: [SessionModel.RescanWarning],
        language: AppLanguage?
    ) -> String? {
        guard !warnings.isEmpty else { return nil }
        let names = warnings.map(\.documentName).joined(separator: ", ")
        let total = warnings.reduce(0) { $0 + $1.suppressedPartyCount }
        let key: String
        if warnings.count == 1 {
            key = total == 1
                ? "%@ still contains 1 name you chose not to redact before. Scan will skip it again, so use Protect a missed item if it should be protected here."
                : "%@ still contains %lld names you chose not to redact before. Scan will skip them again, so use Protect a missed item if they should be protected here."
        } else {
            key = total == 1
                ? "%@ still contain 1 name you chose not to redact before. Scan will skip it again, so use Protect a missed item if it should be protected here."
                : "%@ still contain %lld names you chose not to redact before. Scan will skip them again, so use Protect a missed item if they should be protected here."
        }
        if total == 1 {
            return String(
                format: L10n.string(key, language: language),
                names as NSString
            )
        }
        return String(
            format: L10n.string(key, language: language),
            names as NSString,
            Int64(total)
        )
    }

    /// The lead sentence for seams the session pass could not repair: what
    /// goes wrong on the way back, and the two levers that can move it.
    /// Returns nil when the session is clean, which is the ordinary case.
    ///
    /// Deliberately harsher than the rescan advice, because the failure is
    /// worse and completely invisible. A rescan warning means a name stayed
    /// visible, which the user can find by reading the copied text. An
    /// unresolved seam means a name was replaced correctly but will come back
    /// as SOMEBODY ELSE, and nothing the user can look at shows it: the
    /// copied text reads fine, the AI's reply reads fine, and the swap only
    /// exists in the restored document. So the sentence opens by telling the
    /// user not to send it, before explaining anything.
    ///
    /// The action names both levers without claiming which one applies. The
    /// pass gives up for exactly two reasons, replacement text the user typed
    /// by hand and a stored identity carried in from another output style,
    /// and the readable lines it hands back do not say which, so guessing one
    /// here would send half of these users to a control that cannot help.
    static func unresolvedSeamAdvice(
        for seams: [String],
        language: AppLanguage? = nil
    ) -> String? {
        unresolvedSeamAdvice(issueCount: seams.count, language: language)
    }

    static func unresolvedSeamAdvice(
        issueCount: Int,
        language: AppLanguage? = nil
    ) -> String? {
        guard issueCount > 0 else { return nil }
        let key = issueCount == 1
            ? "Do not upload this file. Restoring the AI's reply would put the wrong party's name at 1 redacted site. Clear any replacement text you typed by hand for these names (Use Automatic), or change Output style in Settings, then export again."
            : "Do not upload this file. Restoring the AI's reply would put the wrong party's name at %lld redacted sites. Clear any replacement text you typed by hand for these names (Use Automatic), or change Output style in Settings, then export again."
        guard issueCount > 1 else {
            return L10n.string(key, language: language)
        }
        return String(
            format: L10n.string(key, language: language),
            Int64(issueCount)
        )
    }

    /// Render one semantic seam issue in the selected interface language.
    /// Replacement values and document names remain verbatim user data.
    static func unresolvedSeamDescription(
        for issue: SessionSeamIssue,
        language: AppLanguage? = nil
    ) -> String {
        switch issue {
        case .verificationUnavailable(let index, let name):
            return String(
                format: L10n.string(
                    "%@: the seam check could not run on this document, so it is NOT known whether restoring it returns the original text. Read the restored output before relying on it.",
                    language: language
                ),
                localizedDocumentLabel(index: index, name: name, language: language) as NSString
            )
        case .unexpectedReplacement(let index, let name, let replacement):
            return String(
                format: L10n.string(
                    "%@: the redacted text spells %@ where it was never substituted, so restore would replace it there.",
                    language: language
                ),
                localizedDocumentLabel(index: index, name: name, language: language) as NSString,
                replacement as NSString
            )
        case .wrongEntity(let index, let name, let matched, let shadowed):
            return String(
                format: L10n.string(
                    "%@: the redacted text spells %@ across the site holding %@, so that site would restore to the wrong entity.",
                    language: language
                ),
                localizedDocumentLabel(index: index, name: name, language: language) as NSString,
                matched as NSString,
                shadowed as NSString
            )
        }
    }

    private static func localizedDocumentLabel(
        index: Int,
        name: String?,
        language: AppLanguage?
    ) -> String {
        guard let name else {
            return String(
                format: L10n.string("document %lld", language: language),
                Int64(index + 1)
            )
        }
        return name
    }
}

enum FillProfilePrimaryAction: Equatable {
    case addSources
    case extract
    case saveAndChooseTarget
    case chooseTarget

    static func resolve(
        hasProfile: Bool,
        hasSources: Bool,
        needsSave: Bool
    ) -> FillProfilePrimaryAction {
        guard hasProfile else {
            return hasSources ? .extract : .addSources
        }
        return needsSave ? .saveAndChooseTarget : .chooseTarget
    }

    static func allowsProfilePersistence(during stage: FillStage) -> Bool {
        switch stage {
        case .importingSources, .extracting:
            return false
        default:
            return true
        }
    }

    static func offersUnsavedTargetOption(
        hasProfile: Bool,
        needsSave: Bool
    ) -> Bool {
        hasProfile && needsSave
    }
}

extension ReviewModel {
    /// Build the protected body text shown in Safe Preview. Existing token
    /// assignments from a client or session handoff are used as a seed so the
    /// preview stays aligned after Export for AI. Before the first handoff, the
    /// tokenizer mints deterministic provisional tokens using the same rules as
    /// export. Rejected entities are omitted from the span list and therefore
    /// remain visible in the preview.
    nonisolated static func redactedPreviewText(
        text: String,
        entities: [ReviewEntity],
        style: SubstitutionStyle = .token,
        language: AppLanguage? = nil
    ) -> String {
        let accepted = entities.filter(\.accepted)
        var seedEntries: [String: MappingEntry] = [:]

        for entity in accepted {
            guard let token = entity.token else { continue }
            if var existing = seedEntries[token] {
                let surface = entity.span.text
                if surface != existing.value,
                   surface != existing.surfaceText,
                   !existing.aliases.contains(surface) {
                    existing.aliases.append(surface)
                    seedEntries[token] = existing
                }
            } else {
                seedEntries[token] = MappingEntry(
                    token: token,
                    value: entity.span.text,
                    type: entity.span.type,
                    surfaceText: entity.span.text,
                    aliases: []
                )
            }
        }

        let seed = seedEntries.isEmpty
            ? nil
            : Mapping(
                entries: seedEntries,
                createdAtISO8601: "preview",
                sourceFile: "preview",
                style: style
            )

        let tokenized = Tokenizer.tokenize(
            text: text,
            spans: accepted.map(\.span),
            sourceFile: "preview",
            createdAtISO8601: "preview",
            seedMapping: seed,
            style: style
        )
        guard tokenized.unresolvedSeams.isEmpty else {
            return L10n.string(
                "Safe Preview unavailable: pseudonym restoration could not be verified.",
                language: language
            )
        }
        return tokenized.tokenizedText
    }
}
