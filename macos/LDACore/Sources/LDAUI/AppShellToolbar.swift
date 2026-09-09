//
//  AppShellToolbar.swift
//  LDAUI
//
//  The review window's unified toolbar: Open, the matter menu, two common
//  exports, and a menu for workspace and report actions. Kept out of AppShell because
//  that file already carries the shell and this is large and self contained.
//
//  The mode's primary action (Scan for PII) is deliberately NOT here. It
//  lives in the status banner, because toolbar items overflow into the >>
//  menu on narrow windows and the primary action must never disappear.
//
//  Stored properties are plain references rather than observed objects: this
//  content is rebuilt by AppShell's body, which is what observes the session,
//  so every value read here is already current.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

/// The toolbar for the Counsel review window.
struct AppShellToolbar: ToolbarContent {

    let session: SessionModel

    /// Whether this shell is the frontmost mode. Gates the whole toolbar:
    /// RootShell keeps every mode's view alive in a ZStack, and SwiftUI merges
    /// toolbar items from all live layers, so an inactive shell must
    /// contribute none.
    let isActive: Bool

    let findingsVisible: Bool
    let onToggleFindings: () -> Void

    let exportFlow: ExportFlowModel
    let workspaceFlow: WorkspaceFlowModel
    let reportFlow: ComplianceReportFlowModel
    let clientFlow: ClientMatterFlowModel

    /// Opens the guided Matters workspace for choosing an existing matter.
    let onOpenMatters: () -> Void

    /// Raises the document open panel.
    let onOpen: () -> Void

    /// Runs the Export for AI handoff.
    let onExportForAI: () -> Void

    /// Where the toolbar reports its one-line outcome (the shell's banner).
    let report: (String?) -> Void

    /// The active document's review model.
    private var model: ReviewModel { session.activeModel }

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if isActive {
            ToolbarItemGroup(placement: .navigation) {
                if !session.entries.isEmpty {
                    Button(action: onToggleFindings) {
                        L10n.label(findingsVisible ? "Hide findings" : "Show findings",
                                   systemImage: "sidebar.left")
                    }
                    .l10nHelp(findingsVisible ? "Hide findings" : "Show findings")
                    .accessibilityIdentifier("toggleFindingsSidebar")
                }
                Button {
                    onOpen()
                } label: {
                    L10n.label("Open", systemImage: "doc.badge.plus")
                }
                .l10nHelp("Add documents, evidence images, or a ZIP to the session")

                ClientMatterMenu(
                    session: session,
                    flow: clientFlow,
                    onOpenMatters: onOpenMatters,
                    report: report
                )
            }

            if !session.entries.isEmpty {
                ToolbarItemGroup(placement: .automatic) {
                    // The mode's primary action (Scan for PII) lives in the status
                    // banner, not here: toolbar items overflow into the >> menu on
                    // narrow windows, and the primary action must never disappear.
                    // Two doors, one Restore. Export for AI writes the whole
                    // session as ONE Markdown file for chat or upload; Save
                    // Redacted writes one document in its original format for
                    // editors that keep formatting. They leave their key in
                    // different places (Export for AI beside its Markdown, Save
                    // Redacted in the document's workspace on this Mac), and
                    // Restore finds either without being told.
                    Button {
                        onExportForAI()
                    } label: {
                        L10n.label("Export for AI\u{2026}", systemImage: "doc.richtext")
                    }
                    .labelStyle(.titleAndIcon)
                    .disabled(!session.exportForAIAvailability.isAvailable)
                    .help(exportForAIHelp)

                    Button {
                        exportFlow.requestExport()
                    } label: {
                        L10n.label("Save Redacted", systemImage: "square.and.arrow.up")
                    }
                    .labelStyle(.titleAndIcon)
                    // Still disabled, and deliberately so: an enabled button that
                    // fails is worse. What changed is that the status banner now
                    // renders the reason from this same availability value, so the
                    // click that produces nothing is no longer unexplained.
                    .disabled(!model.exportAvailability.isAvailable)
                    .l10nHelp("Save this document redacted in its original format. The mapping is kept in a workspace on this Mac, and Restore brings the document back with formatting preserved.")

                    Menu {
                        Button {
                            workspaceFlow.requestSave()
                        } label: {
                            L10n.label("Save Workspace", systemImage: "shippingbox")
                        }
                        .disabled(!session.workspaceAvailability.isAvailable)
                        .help(L10n.string(WorkspacePresentation.saveHelp))

                        Button {
                            reportFlow.requestExport()
                        } label: {
                            L10n.label("Export Report", systemImage: "list.clipboard")
                        }
                        .disabled(!session.complianceReportAvailability.isAvailable)
                        .help(L10n.string(ComplianceReportPresentation.exportHelp))
                    } label: {
                        L10n.label("More", systemImage: "ellipsis.circle")
                    }
                    .labelStyle(.titleAndIcon)
                    .l10nHelp("Save a workspace or export a review report")
                }
            }
        }
    }

    /// The Export for AI tooltip, enriched with how many of the session's
    /// documents are ready so a multi-document user is not silently handed a
    /// partial session (F5, partially: a tooltip is hover-only, so this cannot
    /// be the whole answer. See the audit doc.)
    private var exportForAIHelp: String {
        let ready = session.entries.filter { $0.model.exportAvailability.isAvailable }.count
        // A failed import can never become ready, so counting it in the
        // denominator reads as "you are about to leave that document out" when
        // there is in fact nothing in it to leave out.
        let candidates = session.entries.filter {
            if case .failed = $0.model.status { return false }
            return true
        }.count
        return AnonymizeWorkflowPresentation.exportForAIHelp(
            ready: ready,
            candidates: candidates
        )
    }
}
