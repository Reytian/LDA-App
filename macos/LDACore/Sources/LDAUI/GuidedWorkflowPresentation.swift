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
    static func rescanAdvice(for warnings: [SessionModel.RescanWarning]) -> String? {
        guard !warnings.isEmpty else { return nil }
        let sentences = [
            rescanSentence(for: warnings.filter { $0.rescannablePartyCount > 0 }),
            suppressedSentence(for: warnings.filter { $0.suppressedPartyCount > 0 })
        ].compactMap { $0 }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    /// The gap a re-scan really would close.
    private static func rescanSentence(
        for warnings: [SessionModel.RescanWarning]
    ) -> String? {
        guard !warnings.isEmpty else { return nil }
        let names = warnings.map(\.documentName).joined(separator: ", ")
        let subject = warnings.count == 1 ? "\(names) still contains" : "\(names) still contain"
        let total = warnings.reduce(0) { $0 + $1.rescannablePartyCount }
        let object = total == 1 ? "1 name" : "\(total) names"
        let action = warnings.count == 1 ? "Run Scan on it again" : "Run Scan on them again"
        return "\(subject) \(object) protected elsewhere in this session. \(action), then copy."
    }

    /// The gap a re-scan would refuse to close, because the user already
    /// decided against redacting the value.
    private static func suppressedSentence(
        for warnings: [SessionModel.RescanWarning]
    ) -> String? {
        guard !warnings.isEmpty else { return nil }
        let names = warnings.map(\.documentName).joined(separator: ", ")
        let subject = warnings.count == 1 ? "\(names) still contains" : "\(names) still contain"
        let total = warnings.reduce(0) { $0 + $1.suppressedPartyCount }
        let object = total == 1 ? "1 name" : "\(total) names"
        let skipped = total == 1 ? "it" : "them"
        let candidate = total == 1 ? "it" : "they"
        return "\(subject) \(object) you chose not to redact before. "
            + "Scan will skip \(skipped) again, so use Protect a missed item "
            + "if \(candidate) should be protected here."
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
    static func unresolvedSeamAdvice(for seams: [String]) -> String? {
        guard !seams.isEmpty else { return nil }
        let sites = seams.count == 1 ? "1 redacted site" : "\(seams.count) redacted sites"
        return "Do not send this copy. Restoring the AI's reply would put the "
            + "wrong party's name at \(sites). Clear any replacement text you "
            + "typed by hand for these names (Use Automatic), or change Output style "
            + "in Settings, then copy again."
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
    /// preview stays aligned after Copy for AI. Before the first handoff, the
    /// tokenizer mints deterministic provisional tokens using the same rules as
    /// export. Rejected entities are omitted from the span list and therefore
    /// remain visible in the preview.
    nonisolated static func redactedPreviewText(
        text: String,
        entities: [ReviewEntity],
        style: SubstitutionStyle = .token
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

        return Tokenizer.tokenize(
            text: text,
            spans: accepted.map(\.span),
            sourceFile: "preview",
            createdAtISO8601: "preview",
            seedMapping: seed,
            style: style
        ).tokenizedText
    }
}
