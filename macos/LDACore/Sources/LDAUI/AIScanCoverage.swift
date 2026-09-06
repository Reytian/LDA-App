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
