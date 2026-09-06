//
//  AIScanCoverage.swift
//  LDAUI
//
//  What the AI pass did for the scan result that is on screen, as ONE value.
//
//  ReviewModel publishes the three fields separately (aiActive, aiWarning,
//  aiRanPartially) because the window binds to each of them. But they describe
//  one fact about one result, and every path that moves a result around has
//  to move all three with it: a cancelled retry that puts the previous result
//  back, and a workspace that captures a result and re-applies it on another
//  Mac. Both paths once moved the entities and forgot the coverage, and a
//  failed or partial scan came back exportable without the warning that had
//  gated it. Handling the three as one value makes forgetting one impossible.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

/// The AI coverage of one scan result.
public struct AIScanCoverage: Equatable, Sendable {

    /// The AI pass ran to full coverage. See ReviewModel.aiActive.
    public var aiActive: Bool

    /// Why the AI pass was expected and did not fully run; nil when it ran
    /// cleanly or was not asked for. See ReviewModel.aiWarning.
    public var aiWarning: String?

    /// The pass examined the document and stopped short, as opposed to never
    /// examining it. See ReviewModel.aiRanPartially.
    public var aiRanPartially: Bool

    public init(aiActive: Bool, aiWarning: String?, aiRanPartially: Bool) {
        self.aiActive = aiActive
        self.aiWarning = aiWarning
        self.aiRanPartially = aiRanPartially
    }

    /// The coverage of a document that has not been scanned: nothing ran and
    /// nothing warns.
    public static let unscanned = AIScanCoverage(
        aiActive: false,
        aiWarning: nil,
        aiRanPartially: false
    )
}

// MARK: - Workspace persistence

extension AIScanCoverage {

    /// The structured form a workspace snapshot records.
    ///
    /// Only the state travels, never the warning prose: the sentence is
    /// regenerated in the reader's language when the snapshot is re-applied,
    /// because a colleague's Mac may not be set to the language the scan ran
    /// in. The mapping mirrors ModelSetupPresentation.exportGateReason, so
    /// what the gate would have said before saving is what the record says.
    var workspaceRecord: WorkspaceAICoverage {
        if aiActive { return .complete }
        guard aiWarning != nil else { return .notRequested }
        return aiRanPartially ? .ranPartially : .didNotRun
    }

    /// The coverage a snapshot's record re-applies as.
    ///
    /// A snapshot written before coverage was recorded (nil) is read as a
    /// pass that did not run. That is the conservative reading and the only
    /// defensible one: the alternative lets an unknown pass show as a clean
    /// one, which is exactly the loss this record exists to prevent.
    static func restored(
        from record: WorkspaceAICoverage?,
        language: AppLanguage? = nil
    ) -> AIScanCoverage {
        switch record {
        case .complete:
            return AIScanCoverage(aiActive: true, aiWarning: nil, aiRanPartially: false)
        case .notRequested:
            return .unscanned
        case .didNotRun:
            return AIScanCoverage(
                aiActive: false,
                aiWarning: L10n.string("When this workspace was saved, the AI pass had not run on this document, so people's names and company names were not looked for. Scan it again with a detection model, or read the copy before you hand it to an AI tool.", language: language),
                aiRanPartially: false
            )
        case .ranPartially:
            return AIScanCoverage(
                aiActive: false,
                aiWarning: L10n.string("When this workspace was saved, the AI pass had not covered all of this document, so some people's names and company names were found and others were not. Scan it again, or read the copy before you hand it to an AI tool.", language: language),
                aiRanPartially: true
            )
        case nil:
            return AIScanCoverage(
                aiActive: false,
                aiWarning: L10n.string("This workspace was saved before LDA recorded whether the AI pass ran, so this document is treated as if it did not. Scan it again, or read the copy before you hand it to an AI tool.", language: language),
                aiRanPartially: false
            )
        }
    }
}
