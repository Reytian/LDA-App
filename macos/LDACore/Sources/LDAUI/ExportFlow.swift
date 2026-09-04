//
//  ExportFlow.swift
//  LDAUI
//
//  The Save Redacted flow, as a view modifier the review shell applies:
//  a directory picker, then the optional passphrase sheet that protects the
//  mapping sidecar. Modelled on WorkspaceFlow and ComplianceReportFlow, for
//  the same reason: AppShell is the largest file in the module and this is
//  self contained.
//
//  The destination is collected BEFORE the passphrase, because the sheet's
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

    /// True while the passphrase sheet is presented, after a directory is chosen.
    @Published var isPromptingPassphrase = false

    /// The directory chosen for export, held while the passphrase is collected.
    @Published var pendingExportDir: URL?

    /// The optional passphrase typed into the sheet. Empty means use the
    /// Keychain instead of a passphrase.
    @Published var passphrase = ""

    /// Bumped by the toolbar to raise the directory picker.
    @Published var requestToken = 0

    func requestExport() { requestToken += 1 }
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

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $flow.isPromptingPassphrase) {
                passphraseSheet
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
            L10n.text("Protect the mapping")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            L10n.text("Enter an optional passphrase to encrypt the mapping sidecar. Leave it blank to protect the mapping with the system Keychain.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Confidentiality nudge: the mapping sidecar holds the original
            // values (encrypted). Exporting into an iCloud-synced folder ships
            // that file off this Mac.
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

            L10n.secureField("Passphrase (optional)", text: $flow.passphrase)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()
                L10n.button("Cancel", role: .cancel) {
                    cancelPassphrase()
                }
                .keyboardShortcut(.cancelAction)

                L10n.button("Export") {
                    confirmExport()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(CounselTheme.raised)
    }

    // MARK: - Export

    private func presentExportPanel() {
        guard model.canExport else { return }
        report(nil)
        flow.passphrase = ""
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.string("Choose a folder for the redacted document and encrypted mapping.")
        panel.prompt = L10n.string("Export Here")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        flow.pendingExportDir = dir
        flow.isPromptingPassphrase = true
    }

    private func cancelPassphrase() {
        flow.isPromptingPassphrase = false
        flow.pendingExportDir = nil
        flow.passphrase = ""
    }

    private func confirmExport() {
        flow.isPromptingPassphrase = false
        guard let dir = flow.pendingExportDir else { return }

        let phrase = flow.passphrase.isEmpty ? nil : flow.passphrase
        let protection = flow.passphrase.isEmpty
            ? L10n.string("Mac Keychain")
            : L10n.string("Passphrase protected")
        let createdAt = ISO8601DateFormatter().string(from: Date())
        flow.pendingExportDir = nil
        flow.passphrase = ""

        let needsScope = dir.startAccessingSecurityScopedResource()
        Task {
            defer {
                if needsScope { dir.stopAccessingSecurityScopedResource() }
            }
            do {
                let outcome = try await model.export(
                    to: dir,
                    passphrase: phrase,
                    createdAtISO8601: createdAt
                )
                complete(.exported(
                    result: outcome,
                    protection: protection
                ))
            } catch {
                report(String(
                    format: L10n.string("Export failed: %@"),
                    error.localizedDescription as NSString
                ))
            }
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
