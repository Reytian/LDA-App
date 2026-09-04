//
//  AppShellToolbar.swift
//  LDAUI
//
//  The review window's unified toolbar: Open, the matter menu, and the four
//  things a user saves at the end of a sitting. Kept out of AppShell because
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
                Button {
                    onOpen()
                } label: {
                    L10n.label("Open", systemImage: "doc.badge.plus")
                }
                .l10nHelp("Add .txt, .docx, .pdf documents or a .zip to the session")

                ClientMatterMenu(
                    session: session,
                    flow: clientFlow,
                    onOpenMatters: onOpenMatters,
                    report: report
                )
            }

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

                // Next to Save Redacted, because it is the other thing a user
                // saves at the end of a sitting: the redacted output goes out,
                // the workspace stays with the matter.
                Button {
                    workspaceFlow.requestSave()
                } label: {
                    L10n.label("Save Workspace", systemImage: "shippingbox")
                }
                .labelStyle(.titleAndIcon)
                .disabled(!session.workspaceAvailability.isAvailable)
                .help(L10n.string(WorkspacePresentation.saveHelp))

                // The report carries NO protected value, but it does carry the
                // matter label and every document name, and in PRC legal
                // practice those names are the parties. So the export is
                // passphrase protected by default, like the workspace file,
                // and the readable pair is an explicit choice on the sheet.
                // The panels and the sheet live in ComplianceReportFlow.
                Button {
                    reportFlow.requestExport()
                } label: {
                    L10n.label("Export Report", systemImage: "list.clipboard")
                }
                .labelStyle(.titleAndIcon)
                .disabled(!session.complianceReportAvailability.isAvailable)
                .help(L10n.string(ComplianceReportPresentation.exportHelp))
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
