//
//  WorkspaceFlow.swift
//  LDAUI
//
//  The Save Workspace and Open Workspace flows, as a view modifier the review
//  shell applies. Kept out of AppShell because that file is already the
//  largest in the module and these are self-contained: a save panel, two
//  passphrase sheets, and one confirmation dialog.
//
//  The stage machine exists for one requirement: opening a workspace REPLACES
//  the window's live work, so it must never happen silently. With documents
//  open, the user is asked first, and "Save Current Work First" chains into the
//  save flow and then continues into the open it interrupted.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LDACore

// MARK: - Flow state

/// Owns which step of the workspace flow is on screen.
@MainActor
final class WorkspaceFlowModel: ObservableObject {

    enum Stage: Equatable {
        case idle
        /// Live work would be replaced by the workspace at this URL.
        case confirmReplacement(URL)
        /// Collecting a passphrase to write the workspace to this URL.
        case saving(URL)
        /// Collecting a passphrase to open the workspace at this URL.
        case opening(URL)
    }

    @Published var stage: Stage = .idle
    @Published var passphrase = ""
    @Published var confirmation = ""

    /// An error shown inside the open sheet, so a mistyped passphrase can be
    /// corrected without starting over.
    @Published var sheetMessage: String?

    /// Bumped by the toolbar and the File menu to raise the save panel.
    @Published var saveRequestToken = 0

    /// The workspace to open once the interrupting save finishes.
    var pendingOpenAfterSave: URL?

    func requestSave() { saveRequestToken += 1 }

    /// Begin opening a workspace, asking first when live work would be lost.
    func requestOpen(_ url: URL, hasActiveWork: Bool) {
        resetInput()
        switch WorkspacePresentation.openConflict(hasActiveWork: hasActiveWork) {
        case .openImmediately:
            stage = .opening(url)
        case .confirmReplacement:
            stage = .confirmReplacement(url)
        }
    }

    func cancel() {
        stage = .idle
        pendingOpenAfterSave = nil
        resetInput()
    }

    func resetInput() {
        passphrase = ""
        confirmation = ""
        sheetMessage = nil
    }

    var confirmationURL: URL? {
        if case .confirmReplacement(let url) = stage { return url }
        return nil
    }

    var isSheetPresented: Bool {
        switch stage {
        case .saving, .opening: return true
        case .idle, .confirmReplacement: return false
        }
    }
}

// MARK: - Flow modifier

/// Attaches the workspace save and open flows to a shell.
struct WorkspaceFlow: ViewModifier {

    @ObservedObject var session: SessionModel
    @ObservedObject var flow: WorkspaceFlowModel

    /// Where the flow reports its one-line outcome (the shell's banner).
    let report: (String?) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: sheetBinding) { sheet }
            .confirmationDialog(
                "Open workspace?",
                isPresented: confirmationBinding,
                titleVisibility: .visible
            ) {
                confirmationButtons
            } message: {
                Text(WorkspacePresentation.replacementPrompt)
            }
            .onChange(of: flow.saveRequestToken) { _, _ in presentSavePanel() }
            .onChange(of: session.pendingWorkspaceURL) { _, url in
                guard let url else { return }
                session.pendingWorkspaceURL = nil
                // hasActiveMatterWork, not just the tray: an unfinished restore
                // context is work too, and opening a workspace discards it.
                flow.requestOpen(url, hasActiveWork: session.hasActiveMatterWork)
            }
    }

    @ViewBuilder
    private var confirmationButtons: some View {
        if let url = flow.confirmationURL {
            // Offered only when there is something saveable. Unfinished restore
            // context without documents still triggers the prompt, because
            // opening would discard it, but it cannot be written to a
            // workspace, so the button would be dead.
            if session.canSaveWorkspace {
                Button("Save Current Work First\u{2026}") {
                    flow.pendingOpenAfterSave = url
                    flow.stage = .idle
                    flow.requestSave()
                }
            }
            Button("Discard and Open", role: .destructive) {
                flow.stage = .opening(url)
            }
        }
        Button("Cancel", role: .cancel) { flow.cancel() }
    }

    @ViewBuilder
    private var sheet: some View {
        switch flow.stage {
        case .saving:
            WorkspaceSaveSheet(flow: flow, onConfirm: confirmSave)
        case .opening:
            WorkspaceOpenSheet(flow: flow, onConfirm: confirmOpen)
        case .idle, .confirmReplacement:
            EmptyView()
        }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { flow.isSheetPresented },
            set: { if !$0 { flow.cancel() } }
        )
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { flow.confirmationURL != nil },
            set: { if !$0 { flow.cancel() } }
        )
    }

    // MARK: - Save

    private func presentSavePanel() {
        guard session.canSaveWorkspace else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = WorkspacePresentation.proposedFileName()
        panel.canCreateDirectories = true
        panel.message = "Choose where to keep this matter's workspace file."
        panel.prompt = "Save Workspace"
        if let type = UTType(filenameExtension: WorkspaceArchive.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            // Cancelling the save must not silently swallow the open it
            // interrupted; put the user back on the question they answered.
            if let pending = flow.pendingOpenAfterSave {
                flow.pendingOpenAfterSave = nil
                flow.stage = .confirmReplacement(pending)
            }
            return
        }
        flow.resetInput()
        flow.stage = .saving(url)
    }

    private func confirmSave() {
        guard case .saving(let url) = flow.stage else { return }
        let passphrase = flow.passphrase
        let pendingOpen = flow.pendingOpenAfterSave
        flow.stage = .idle
        flow.resetInput()

        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        do {
            try session.saveWorkspace(
                to: url,
                passphrase: passphrase,
                createdAtISO8601: ISO8601DateFormatter().string(from: Date())
            )
            report("Workspace saved as \(url.lastPathComponent).")
            // The save was only ever an interruption of an open; continue it.
            if let pendingOpen {
                flow.pendingOpenAfterSave = nil
                flow.stage = .opening(pendingOpen)
            }
        } catch {
            flow.pendingOpenAfterSave = nil
            report(WorkspacePresentation.failure(error, action: "Saving the workspace"))
        }
    }

    // MARK: - Open

    private func confirmOpen() {
        guard case .opening(let url) = flow.stage else { return }
        let passphrase = flow.passphrase
        flow.sheetMessage = nil

        let needsScope = url.startAccessingSecurityScopedResource()
        Task {
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try await session.openWorkspace(at: url, passphrase: passphrase)
                flow.stage = .idle
                flow.resetInput()
                report(WorkspacePresentation.summary(summary))
            } catch {
                // Stay on the sheet: a mistyped passphrase is the likely cause
                // and retyping it should not mean starting the flow again.
                flow.sheetMessage = error.localizedDescription
            }
        }
    }
}

extension View {

    /// Attach the workspace save and open flows.
    func workspaceFlow(
        session: SessionModel,
        flow: WorkspaceFlowModel,
        report: @escaping (String?) -> Void
    ) -> some View {
        modifier(WorkspaceFlow(session: session, flow: flow, report: report))
    }
}
