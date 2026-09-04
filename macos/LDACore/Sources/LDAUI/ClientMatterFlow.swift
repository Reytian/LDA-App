//
//  ClientMatterFlow.swift
//  LDAUI
//
//  Choosing the matter this window works under (R10): the toolbar menu, the
//  new-matter prompt, and the confirmation that has to come first when live
//  documents would be relabeled. Kept out of AppShell because that file is
//  already the largest in the module and this is self contained: one menu,
//  one alert, one confirmation dialog.
//
//  Switching matters is never silent when there is live work. SessionModel
//  refuses the change and returns false; the request parks here until the
//  user agrees to close the documents, because one matter's content must
//  never end up labeled as another matter's.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import LDACore

// MARK: - Flow state

/// A requested client change that must first close the current documents
/// so one matter's live content cannot be relabeled as another matter.
struct PendingClientSelection {
    let label: String?
}

/// Owns the parked matter change, if any.
@MainActor
final class ClientMatterFlowModel: ObservableObject {
    @Published var pendingClientSelection: PendingClientSelection?
}

// MARK: - Toolbar menu

/// The client profile menu (R10): pick a client so this session reuses and
/// extends that client's identities, or work without one.
struct ClientMatterMenu: View {

    @ObservedObject var session: SessionModel
    @ObservedObject var flow: ClientMatterFlowModel

    /// Opens the guided Matters workspace for choosing an existing matter.
    let onOpenMatters: () -> Void

    /// Where the menu reports its one-line outcome (the shell's banner).
    let report: (String?) -> Void

    var body: some View {
        Menu {
            Button {
                requestClientSelection(nil)
            } label: {
                if session.clientLabel == nil {
                    L10n.label("No Matter", systemImage: "checkmark")
                } else {
                    L10n.text("No Matter")
                }
            }

            Divider()
            Button {
                onOpenMatters()
            } label: {
                L10n.label("Choose Saved Matter\u{2026}", systemImage: "briefcase")
            }

            L10n.button("New Matter\u{2026}") {
                promptNewClient()
            }

            // Matter-scoped learned rules (F4): where this session's accept
            // and reject decisions are remembered. Only meaningful with a
            // matter selected, so the item hides without one.
            if session.clientLabel != nil {
                Divider()
                L10n.toggle(
                    "Apply learned rules to this matter only",
                    isOn: matterScopeBinding
                )
            }
        } label: {
            Label(
                session.clientLabel ?? L10n.string("No Matter"),
                systemImage: "person.crop.square"
            )
        }
        .l10nHelp("Work under a matter keeps the same placeholders for the same values, every time")
    }

    /// Routes the matter-scope toggle through the session, which persists the
    /// choice per matter and creates the matter's scope identity on first use.
    private var matterScopeBinding: Binding<Bool> {
        Binding(
            get: { session.scopeLearnedRulesToMatter },
            set: { enabled in
                do {
                    try session.setScopeLearnedRulesToMatter(enabled)
                } catch {
                    report(String(
                        format: L10n.string("Could not change the matter scope. %@"),
                        error.localizedDescription as NSString
                    ))
                }
            }
        )
    }

    /// Ask for a new client label with a small input alert and select it.
    private func promptNewClient() {
        let alert = NSAlert()
        alert.messageText = L10n.string("New matter")
        alert.informativeText = L10n.string(
            "Documents processed under this matter keep consistent placeholders across sessions. The mapping stays encrypted on this Mac."
        )
        alert.addButton(withTitle: L10n.string("Create"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = L10n.string("Client or matter name")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        requestClientSelection(label)
    }

    private func requestClientSelection(_ label: String?) {
        do {
            if try session.selectMatter(label) == false {
                flow.pendingClientSelection = PendingClientSelection(label: label)
            }
        } catch {
            report(error.localizedDescription)
        }
    }
}

// MARK: - Flow modifier

/// Attaches the close-live-work confirmation to a shell.
struct ClientMatterFlow: ViewModifier {

    @ObservedObject var session: SessionModel
    @ObservedObject var flow: ClientMatterFlowModel

    /// Where the flow reports its one-line outcome (the shell's banner).
    let report: (String?) -> Void

    func body(content: Content) -> some View {
        content
            .l10nConfirmationDialog(
                "Close current work?",
                isPresented: Binding(
                    get: { flow.pendingClientSelection != nil },
                    set: { if !$0 { flow.pendingClientSelection = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let pendingClientSelection = flow.pendingClientSelection {
                    L10n.button("Close Active Work and Switch", role: .destructive) {
                        completeClientSelection(pendingClientSelection.label)
                    }
                }
                L10n.button("Cancel", role: .cancel) {
                    flow.pendingClientSelection = nil
                }
            } message: {
                L10n.text("Switching matters closes the documents and any unfinished restore context in this window. Saved files are not affected.")
            }
    }

    private func completeClientSelection(_ label: String?) {
        do {
            _ = try session.selectMatter(label, discardingDocuments: true)
        } catch {
            report(error.localizedDescription)
        }
        flow.pendingClientSelection = nil
    }
}

extension View {

    /// Attach the matter switch confirmation.
    func clientMatterFlow(
        session: SessionModel,
        flow: ClientMatterFlowModel,
        report: @escaping (String?) -> Void
    ) -> some View {
        modifier(ClientMatterFlow(session: session, flow: flow, report: report))
    }
}
