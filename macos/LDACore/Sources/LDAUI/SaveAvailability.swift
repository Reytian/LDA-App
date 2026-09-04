//
//  SaveAvailability.swift
//  LDAUI
//
//  One availability type for the four things a user saves at the end of a
//  sitting: Save Redacted, Save Workspace, Export for AI, Export Report.
//
//  Why a type rather than the four Bools it replaces. A disabled SwiftUI
//  toolbar button swallows its own click and renders no tooltip you can rely
//  on, so a Bool gate can only ever say no; it cannot say why. For a lawyer
//  that is not a small gap: a click on Save Redacted that produces nothing
//  invites the conclusion that the work WAS saved.
//
//  The gaps were also ASYMMETRIC, and the asymmetry was the confusion. Save
//  Redacted needed a FINISHED scan (status == .ready) while Save Workspace
//  needed only an OPEN document (a non-empty tray), so Save Redacted was dead
//  for the whole window between opening a document and finishing a scan, which
//  is exactly when a first-time user reaches for it. Both gates are still
//  exactly as strict as they were; what changed is that the blocked answer now
//  carries a reason, and every entry point reads the reason rather than a bare
//  Bool.
//
//  The reason is rendered where the user already looks: the status banner
//  (AppShellStatusBanner) for the standing case, and the shell's one-line
//  outcome for a request that reaches a flow anyway.
//
//  Kept free of SwiftUI so the gating and the wording are tested directly
//  rather than through a window.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

// MARK: - Reason

/// Why a save or export cannot run right now.
///
/// One flat set shared by all four saves, because the states that block them
/// overlap: an empty tray blocks every one of them, and a scan in flight
/// blocks three. A per-button enum would have spelled the same sentence four
/// times and let the four drift apart.
public enum SaveBlockReason: String, CaseIterable, Equatable, Sendable {
    /// The tray is empty. Blocks every save.
    case noDocumentOpen
    /// A document is being read in. Blocks everything that needs its text.
    case documentStillOpening
    /// A detection pass is in flight.
    case scanStillRunning
    /// A document is loaded but has never been scanned.
    case scanNotFinished
    /// The import failed, so there is no text to redact.
    case documentFailedToOpen
    /// Export Report describes an Export for AI handoff and none has happened.
    case noHandoffToReportOn
}

// MARK: - Availability

/// Whether one save can run, and why not when it cannot.
///
/// `blockReason == nil` is the single definition of available, so the two can
/// never disagree the way two separate Bools could.
public struct SaveAvailability: Equatable, Sendable {

    /// Why this save cannot run, or nil when it can.
    public let blockReason: SaveBlockReason?

    /// The gate every `.disabled(...)` and every guard reads.
    public var isAvailable: Bool { blockReason == nil }

    private init(blockReason: SaveBlockReason?) {
        self.blockReason = blockReason
    }

    public static let available = SaveAvailability(blockReason: nil)

    public static func blocked(_ reason: SaveBlockReason) -> SaveAvailability {
        SaveAvailability(blockReason: reason)
    }
}

// MARK: - Rules

/// The pure derivations behind every save gate in the app. Each one maps the
/// state the old Bool read onto the same answer plus a reason, so the refactor
/// is behaviour preserving by construction and checkable state by state.
enum SaveAvailabilityRules {

    /// Save Redacted, for one document. Was `if case .ready = status`.
    static func saveRedacted(status: ReviewStatus) -> SaveAvailability {
        switch status {
        case .idle:
            return .blocked(.noDocumentOpen)
        case .importing:
            return .blocked(.documentStillOpening)
        case .imported:
            return .blocked(.scanNotFinished)
        case .detecting:
            return .blocked(.scanStillRunning)
        case .ready:
            return .available
        case .failed:
            return .blocked(.documentFailedToOpen)
        }
    }

    /// Save Workspace, for the session. Was `!entries.isEmpty`.
    ///
    /// Routed through WorkspacePresentation.canSave so the tray rule keeps one
    /// definition rather than gaining a second one here.
    static func saveWorkspace(documentCount: Int) -> SaveAvailability {
        WorkspacePresentation.canSave(documentCount: documentCount)
            ? .available
            : .blocked(.noDocumentOpen)
    }

    /// Export for AI, for the session. Was
    /// `entries.contains { $0.model.canExport }`, so still available as soon as
    /// ANY document is ready; the handoff deliberately includes what is ready
    /// and says how many it left out.
    ///
    /// The reason is picked by an ordered priority rather than by tray order,
    /// so a session reports the same reason however its documents are sorted.
    /// Work in flight outranks work not started, because waiting is then the
    /// user's next action.
    static func exportForAI(statuses: [ReviewStatus]) -> SaveAvailability {
        guard !statuses.isEmpty else { return .blocked(.noDocumentOpen) }
        if statuses.contains(where: { if case .ready = $0 { return true }; return false }) {
            return .available
        }
        if statuses.contains(where: { if case .detecting = $0 { return true }; return false }) {
            return .blocked(.scanStillRunning)
        }
        if statuses.contains(where: { if case .importing = $0 { return true }; return false }) {
            return .blocked(.documentStillOpening)
        }
        if statuses.contains(where: { if case .imported = $0 { return true }; return false }) {
            return .blocked(.scanNotFinished)
        }
        if statuses.contains(where: { if case .failed = $0 { return true }; return false }) {
            return .blocked(.documentFailedToOpen)
        }
        // Every entry is .idle: an entry exists but carries no document yet,
        // which is the empty tray as far as the user can tell.
        return .blocked(.noDocumentOpen)
    }

    /// Export Report, for the session. Was `currentRecordID != nil`.
    static func exportReport(hasHandoffRecord: Bool) -> SaveAvailability {
        hasHandoffRecord ? .available : .blocked(.noHandoffToReportOn)
    }
}

// MARK: - Copy

/// The sentence each reason renders.
///
/// Each one names the button it is about and says what to do next, not merely
/// what is missing: the user arrived here by clicking something that did
/// nothing, so "no document" alone would leave them exactly where they were.
enum SaveAvailabilityPresentation {

    /// The catalog key for a reason. Held here as the one spelling, so the
    /// sentence cannot drift from the key that has to exist in all four
    /// catalogs.
    static func reasonKey(_ reason: SaveBlockReason) -> String {
        switch reason {
        case .noDocumentOpen:
            return "Save Redacted and Save Workspace need a document. Click Open to add one."
        case .documentStillOpening:
            return "Save Redacted waits for this document to finish opening."
        case .scanStillRunning:
            return "Save Redacted waits for this scan to finish."
        case .scanNotFinished:
            return "Save Redacted needs a finished scan. Click Scan for PII first."
        case .documentFailedToOpen:
            return "This document did not open, so there is nothing to save. Open the file again."
        case .noHandoffToReportOn:
            return "Export Report covers an Export for AI handoff. Run one first."
        }
    }

    /// The reason as the user reads it.
    static func sentence(
        for reason: SaveBlockReason,
        language: AppLanguage? = nil
    ) -> String {
        L10n.string(reasonKey(reason), language: language)
    }

    /// The sentence for an availability, or nil when the save can run and
    /// there is nothing to explain.
    static func notice(
        _ availability: SaveAvailability,
        language: AppLanguage? = nil
    ) -> String? {
        guard let reason = availability.blockReason else { return nil }
        return sentence(for: reason, language: language)
    }
}
