//
//  ExportFlow.swift
//  LDAUI
//
//  The Save Redacted flow, as a view modifier the review shell applies:
//  a directory picker, then the sheet that says where the mapping is kept and
//  offers to write one next to the document. Modelled on WorkspaceFlow and
//  ComplianceReportFlow, for the same reason: AppShell is the largest file in
//  the module and this is self contained.
//
//  WHAT THIS SHEET IS FOR NOW. It used to collect an OPTIONAL passphrase for a
//  .ldamap that was written on every export. Both halves of that are gone: no
//  sidecar unless the user asks, and a passphrase whenever they do. The sheet's
//  job is therefore to state where the key IS being kept (a workspace on this
//  Mac, named after the document) before it offers the extra file, so a user
//  who declines is not left wondering whether they can still restore. See
//  MappingSidecarPresentation for the rule and DefaultWorkspace for the home.
//
//  The destination is collected BEFORE the sheet, because the sheet's
//  iCloud warning depends on which folder was chosen.
//
//  The flow reads the active document through the session rather than holding
//  a ReviewModel, for the reason spelled out on the seal candidate binding:
//  the tray can change the active document under an open sheet, and a
//  captured model would keep writing to the document the user left.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import LDACore

// MARK: - Flow state

/// Owns which step of the Save Redacted flow is on screen.
@MainActor
final class ExportFlowModel: ObservableObject {

    /// True while the mapping sheet is presented, after a directory is chosen.
    @Published var isPromptingPassphrase = false

    /// The directory chosen for export, held while the sheet is up.
    @Published var pendingExportDir: URL?

    /// Whether the user asked for a .ldamap next to the redacted document.
    /// Off is the default and the whole point of it: the key is kept in the
    /// document's workspace either way.
    @Published var wantsSidecar = false

    /// The passphrase for that sidecar. Only read when `wantsSidecar` is on,
    /// and then required; a blank one no longer means "use the Keychain".
    @Published var passphrase = ""

    /// Typed a second time, because nothing about it is recoverable from this
    /// Mac and the file exists to be opened somewhere else.
    @Published var confirmation = ""

    @Published var isChoosingDirectory = false
    @Published private(set) var isSaving = false
    @Published private(set) var saveError: String?
    @Published private(set) var savedExport: ExportResult?
    @Published var isShowingSuccess = false

    var isBusy: Bool {
        isChoosingDirectory || isPromptingPassphrase || isSaving || savedExport != nil
    }

    var savedFiles: [URL] {
        guard let savedExport else { return [] }
        return [savedExport.redactedURL] + (savedExport.redactedImageURL.map { [$0] } ?? [])
    }

    /// Bumped by the toolbar to raise the directory picker.
    @Published var requestToken = 0

    func requestExport() {
        guard !isBusy else { return }
        requestToken += 1
    }

    /// Keep the confirmation visible until the file and its mapping are saved.
    /// A failure leaves the destination and inputs available for retry.
    @discardableResult
    func save(using operation: () async throws -> ExportResult) async -> ExportResult? {
        guard !isSaving else { return nil }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            let output = try await operation()
            savedExport = output
            isPromptingPassphrase = false
            pendingExportDir = nil
            resetInput()
            return output
        } catch {
            saveError = String(
                format: L10n.string("Save failed: %@"),
                error.localizedDescription as NSString
            )
            return nil
        }
    }

    /// Wait for the save sheet to close before presenting another modal.
    /// Cancelled and failed saves have no completed export to announce.
    func saveSheetDismissed() {
        isShowingSuccess = savedExport != nil
    }

    func dismissSuccess() {
        isShowingSuccess = false
        savedExport = nil
    }

    /// Clear everything the sheet collected.
    func resetInput() {
        wantsSidecar = false
        passphrase = ""
        confirmation = ""
        saveError = nil
    }
}

// MARK: - Flow modifier

/// Attaches the Save Redacted flow to a shell.
struct ExportFlow: ViewModifier {

    @ObservedObject var session: SessionModel
    @ObservedObject var flow: ExportFlowModel

    /// Where the flow reports its one-line outcome (the shell's banner).
    let report: (String?) -> Void

    /// Where the flow reports a finished export (the shell's completion card).
    let complete: (HandoffCompletion) -> Void

    /// The active document's review model, read fresh on every access.
    private var model: ReviewModel { session.activeModel }

    /// Why the sidecar the user asked for cannot be written yet, or nil.
    /// Always nil while the sidecar toggle is off, which is the default.
    private var sidecarIssue: WorkspacePresentation.PassphraseIssue? {
        MappingSidecarPresentation.issue(
            wantsSidecar: flow.wantsSidecar,
            passphrase: flow.passphrase,
            confirmation: flow.confirmation
        )
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $flow.isPromptingPassphrase, onDismiss: flow.saveSheetDismissed) {
                passphraseSheet
                    .interactiveDismissDisabled(flow.isSaving)
            }
            .l10nAlert("Redacted document saved", isPresented: $flow.isShowingSuccess) {
                L10n.button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(flow.savedFiles)
                    flow.dismissSuccess()
                }
                L10n.button("Done", role: .cancel) {
                    flow.dismissSuccess()
                }
            } message: {
                if let saved = flow.savedExport {
                    L10n.text("%@\n\nSaved in: %@",
                              flow.savedFiles.map(\.lastPathComponent).joined(separator: "\n") as NSString,
                              saved.redactedURL.deletingLastPathComponent().path as NSString)
                }
            }
            // Two independent triggers, one panel: the toolbar bumps the
            // flow's own token, and the Save Redacted menu command bumps the
            // document's. Watching both here keeps each path one hop long.
            .onChange(of: flow.requestToken) { _, _ in presentExportPanel() }
            .onChange(of: model.exportRequestToken) { _, _ in presentExportPanel() }
    }

    // MARK: - Passphrase sheet

    private var passphraseSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            L10n.text("Save Redacted")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            if let dir = flow.pendingExportDir {
                Text(verbatim: dir.path)
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(dir.path)
            }

            // Said BEFORE the offer below, because the answer to "can I still
            // restore this?" must not depend on the user opting into anything.
            L10n.text("LDA keeps this document's mapping in a workspace on this Mac, named after the document. Restore finds it there, so the redacted document you send carries no key beside it.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Trust confirmation: what is and is not being redacted. The
            // count is the whole export, headers and footers included, not
            // the length of the review list.
            ExportCoverageSummary(
                redactedCount: model.totalRedactedCount,
                visibleCount: model.visibleCount
            )
                .font(.callout)
                .foregroundStyle(CounselTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let note = AnonymizeWorkflowPresentation.supplementaryCoverageNote(
                count: model.supplementaryRedactedCount
            ) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            sidecarSection
                .disabled(flow.isSaving)

            if flow.isSaving {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    L10n.text("Saving the redacted document and its mapping. Large documents can take a little longer.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("saveRedactedProgress")
            }

            if let error = flow.saveError {
                Text(verbatim: error)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("saveRedactedError")
            }

            HStack {
                Spacer()
                L10n.button("Cancel", role: .cancel) {
                    cancelPassphrase()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(flow.isSaving)

                L10n.button(flow.isSaving ? "Saving Redacted…" : "Save Redacted") {
                    confirmExport()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
                // Disabled while saving or for an INCOMPLETE sidecar passphrase, never on
                // the save gate: the save gate was already answered before
                // this sheet appeared, and reading it a second time here is
                // how the retired Bool gates used to multiply. With the
                // sidecar toggle off there is no issue and the button is live,
                // which is the default path.
                .disabled(sidecarIssue != nil || flow.isSaving)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(CounselTheme.raised)
    }

    /// The one choice left on this sheet: a mapping file the user can carry to
    /// another Mac, and the passphrase it needs to be worth carrying.
    @ViewBuilder
    private var sidecarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            L10n.toggle(
                "Also save a mapping file next to the redacted document",
                isOn: $flow.wantsSidecar
            )

            if flow.wantsSidecar {
                L10n.text("Only this file can restore the document on another Mac. Send it to someone who should be able to, and give them the passphrase separately.")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Confidentiality nudge: the mapping sidecar holds the
                // original values (encrypted). Exporting into an iCloud
                // synced folder ships that file off this Mac. Shown only
                // when a sidecar will actually be written, since with no
                // sidecar nothing carrying the names goes into that folder.
                if let dir = flow.pendingExportDir, Self.isUnderICloud(dir) {
                    Label {
                        L10n.text("This folder syncs to iCloud. The encrypted mapping (which contains the original names) will be uploaded with it.")
                    } icon: {
                        Image(systemName: "icloud.and.arrow.up")
                    }
                    .font(.callout)
                    .foregroundStyle(CounselTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                }

                L10n.secureField("Passphrase", text: $flow.passphrase)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                L10n.secureField("Confirm passphrase", text: $flow.confirmation)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)

                // Suppressed until something has been typed, exactly as
                // WorkspaceSaveSheet does it: nagging an untouched field
                // reads as an error the user caused.
                if !flow.passphrase.isEmpty, let issue = sidecarIssue {
                    Text(verbatim: MappingSidecarPresentation.message(for: issue))
                        .font(.caption)
                        .foregroundStyle(CounselTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Export

    private func presentExportPanel() {
        guard !flow.isBusy else { return }
        // Not a bare `guard ... else { return }`. Both triggers watched above
        // can fire while the gate is shut (the flow's own token, and the
        // document's, which the Cmd+E menu command bumps), and a silent return
        // here is indistinguishable from a save that worked. Report the reason
        // into the banner instead.
        let availability = model.exportAvailability
        guard availability.isAvailable else {
            report(SaveAvailabilityPresentation.notice(availability))
            return
        }
        report(nil)
        flow.resetInput()
        flow.isChoosingDirectory = true
        let panel = NSOpenPanel()
        panel.title = L10n.string("Save Redacted Document…")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // No longer promises a mapping in this folder: by default nothing but
        // the redacted document is written here.
        panel.message = L10n.string("Choose a folder for the redacted document.")
        panel.prompt = L10n.string("Choose Folder")
        // Do not nest a modal event loop inside SwiftUI's onChange update.
        // Present the confirmation after the native picker has closed.
        panel.begin { response in
            DispatchQueue.main.async {
                flow.isChoosingDirectory = false
                guard response == .OK, let dir = panel.url else { return }
                flow.pendingExportDir = dir
                flow.isPromptingPassphrase = true
            }
        }
    }

    private func cancelPassphrase() {
        flow.isPromptingPassphrase = false
        flow.pendingExportDir = nil
        flow.resetInput()
    }

    private func confirmExport() {
        guard let dir = flow.pendingExportDir else { return }

        // One function decides whether a sidecar is written and under what.
        // nil is the default answer and is exactly what export reads as
        // "write no sidecar".
        let phrase = MappingSidecarPresentation.sidecarPassphrase(
            wantsSidecar: flow.wantsSidecar,
            passphrase: flow.passphrase,
            confirmation: flow.confirmation
        )
        let createdAt = ISO8601DateFormatter().string(from: Date())
        let exportMatterID = session.matterScopeID
        let exportMatterLabel = session.clientLabel
        Task {
            let needsScope = dir.startAccessingSecurityScopedResource()
            defer {
                if needsScope { dir.stopAccessingSecurityScopedResource() }
            }
            guard let outcome = await flow.save(using: {
                // Through the SESSION, not the model: the mapping's home is a
                // workspace, and only the session knows the matter, the
                // overrides, and the document's tray identity that go into one.
                return try await session.exportRedacted(
                    to: dir,
                    passphrase: phrase,
                    createdAtISO8601: createdAt
                )
            }) else { return }
            complete(.exported(outcome))
            // Create the local receipt while the selected directory remains accessible.
            let files = [outcome.redactedURL] + (outcome.redactedImageURL.map { [$0] } ?? [])
            let warning = await Task.detached(priority: .utility) {
                LocalExportHistory.record(files, kind: .redacted,
                    workspaceID: exportMatterID, matterLabel: exportMatterLabel)
            }.value
            if let warning { report(warning) }
        }
    }

    /// True when the directory lives inside iCloud Drive (any app container or
    /// the Desktop and Documents sync surface).
    private static func isUnderICloud(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/Library/Mobile Documents/")
    }
}

extension View {

    /// Attach the Save Redacted flow.
    func exportFlow(
        session: SessionModel,
        flow: ExportFlowModel,
        report: @escaping (String?) -> Void,
        complete: @escaping (HandoffCompletion) -> Void
    ) -> some View {
        modifier(ExportFlow(session: session, flow: flow, report: report, complete: complete))
    }
}

/// The export sheet's coverage sentence, as concatenated `Text` runs so the
/// count can be bold and the rejected-count clause can be red.
///
/// This is a view rather than a `L10n.text` call because `+` composition
/// needs real `Text` values, and `L10n.text` returns an opaque `some View`
/// on purpose so that it cannot be spliced into a sentence by accident.
/// The count-first shape is not an English accident: all four catalogs
/// translate " entities will be redacted." as a suffix to a leading number
/// (zh-Hans " 个实体将被隐去。", fr " entités seront caviardées."), so the
/// concatenation reads correctly in every language the app ships.
private struct ExportCoverageSummary: View {
    @Environment(\.appLanguage) private var language
    let redactedCount: Int
    let visibleCount: Int

    var body: some View {
        let head = Text(verbatim: L10n.formatted("%lld", language: language, [redactedCount]))
            .bold()
            + Text(verbatim: L10n.string(" entities will be redacted.", language: language))
        if visibleCount > 0 {
            return head
                + Text(
                    verbatim: L10n.formatted(
                        "  %lld you rejected will remain visible in the exported file.",
                        language: language,
                        [visibleCount]
                    )
                )
                .foregroundColor(CounselTheme.danger)
        }
        return head
    }
}
