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
        entities: [ReviewEntity]
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
                sourceFile: "preview"
            )

        return Tokenizer.tokenize(
            text: text,
            spans: accepted.map(\.span),
            sourceFile: "preview",
            createdAtISO8601: "preview",
            seedMapping: seed
        ).tokenizedText
    }
}
