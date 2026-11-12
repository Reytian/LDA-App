//
//  AppCommandRelay.swift
//  LDAUI
//
//  The window's commands, each delivered once to the mode that handles it.
//
//  Review 2026-11-11 (F13). Commands used to be counters: three on every
//  document (Scan for PII, Save Redacted, Restore) and three on the session
//  (Open, Scan All, Export for AI), each watched with onChange. A document's
//  counter was read through the ACTIVE document, so selecting a document
//  whose count differed was itself a "request": the newly selected document
//  was scanned, a reviewed one was scanned again and lost its keep-visible
//  choices and manual protections, and the Save and Restore panels opened.
//  The Redact shell's handlers hung off Group { if isActive { ... } }, a
//  group with no child while another mode is shown, so a command issued
//  from Restore, Fill or Matters switched mode and was lost, and so was a
//  double-clicked workspace.
//
//  Now a command is a value in a queue the session owns. RootShell, which is
//  never torn down, shows the mode the oldest command is for, and that
//  mode's shell takes its commands while it is active, each once. Selecting
//  a document puts nothing in the queue.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation

/// One command for the main window.
public enum AppCommand: Equatable, Sendable {
    /// File > Open Documents.
    case openDocuments
    /// A workspace to open, double-clicked in Finder or chosen from the menu.
    case openWorkspace(URL)
    /// A compliance report to open, the same two ways.
    case openReport(URL)
    /// Scan for PII on this document.
    case scan(documentID: UUID)
    /// Scan All.
    case scanAll
    /// Export for AI.
    case exportForAI
    /// Save Redacted for this document.
    case saveRedacted(documentID: UUID)
    /// Restore.
    case restore

    /// The mode that handles the command.
    public var mode: AppMode {
        switch self {
        case .restore:
            return .deanonymize
        case .openDocuments, .openWorkspace, .openReport, .scan, .scanAll, .exportForAI, .saveRedacted:
            return .anonymize
        }
    }
}

/// The commands waiting for their mode, oldest first.
@MainActor
public final class AppCommandRelay: ObservableObject {

    /// One queued command. The id makes two equal commands two deliveries.
    public struct Envelope: Equatable, Identifiable, Sendable {
        public let id: Int
        public let command: AppCommand
    }

    @Published public private(set) var queue: [Envelope] = []
    private var lastID = 0

    public init() {}

    /// Queue a command.
    public func send(_ command: AppCommand) {
        lastID += 1
        queue.append(Envelope(id: lastID, command: command))
    }

    /// The mode the oldest waiting command is for. RootShell shows it.
    public var nextMode: AppMode? { queue.first?.command.mode }

    /// Take the oldest waiting command for `mode`, removing it from the queue.
    public func take(for mode: AppMode) -> AppCommand? {
        guard let index = queue.firstIndex(where: { $0.command.mode == mode }) else { return nil }
        return queue.remove(at: index).command
    }
}

/// What the Redact shell's completion card and messages belong to: the
/// matter and the document they were shown for. The shell's change handlers
/// do not run while another mode is shown, so it compares this when it comes
/// back and clears what belongs to a matter or document no longer shown.
struct AppShellCardContext: Equatable {
    let clientLabel: String?
    let matterGeneration: Int
    let documentID: UUID?

    @MainActor
    init(session: SessionModel) {
        clientLabel = session.clientLabel
        matterGeneration = session.matterGeneration
        documentID = session.activeEntryID
    }
}

/// Whether a Protect Selection request opens the kind chooser.
///
/// The request is a count on each document and the text view is shared by
/// every document, so a count that changed because another document is now
/// shown is no request (review 2026-11-11, F13).
struct ChooserRequestGate {
    private(set) var owner: ObjectIdentifier
    private(set) var token: Int

    init(owner: ObjectIdentifier, token: Int) {
        self.owner = owner
        self.token = token
    }

    /// Record what is shown now. True only when the shown document's own
    /// count moved.
    mutating func update(owner: ObjectIdentifier, token: Int) -> Bool {
        defer {
            self.owner = owner
            self.token = token
        }
        return owner == self.owner && token != self.token
    }
}
