//
//  DeanonymizeShell.swift
//  LDAUI
//
//  The Restore mode: everything that brings REAL values back after work
//  was done on redacted text. One card: restore a redacted file. A
//  previously exported redacted document plus its .ldamap sidecar (and
//  passphrase, if one was set) round-trips back to the original values. This
//  flow lived behind the Cmd+R menu item inside the Anonymize shell before;
//  as the second half of the product's core promise it deserves a first-class
//  surface.
//
//  The heavy lifting stays in ReviewModel.restore / LDAService.restore; this
//  view is chrome, file pickers, and honest result reporting (orphaned or
//  damaged placeholders are listed, never guessed at).
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import UniformTypeIdentifiers
import LDACore

// MARK: - DeanonymizeShell

/// The Restore mode surface.
public struct DeanonymizeShell: View {
    @ObservedObject private var session: SessionModel

    /// The active document's review model (used for the restore entry point;
    /// restore itself is stateless with respect to the review session).
    private var model: ReviewModel { session.activeModel }

    /// Whether this shell is the frontmost mode. Gates the toolbar so hidden
    /// layers do not contribute items.
    private let isActive: Bool

    /// A one-line outcome message shown after a restore completes or fails.
    @State private var resultMessage: String?
    @State private var resultIsWarning = false
    @State private var windowChromeTopInset: CGFloat = 0

    public init(
        session: SessionModel,
        isActive: Bool = true
    ) {
        self.session = session
        self.isActive = isActive
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            CounselTheme.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                WindowChromeTopSpacer(height: windowChromeTopInset, background: CounselTheme.paper)

                ScrollView {
                    VStack(spacing: 24) {
                        header
                        HStack(alignment: .top, spacing: 20) {
                            fileCard
                        }
                        .frame(maxWidth: 860)
                        if let resultMessage {
                            Label {
                                Text(verbatim: resultMessage)
                            } icon: {
                                Image(systemName: resultIsWarning
                                    ? "exclamationmark.triangle.fill"
                                    : "checkmark.circle.fill")
                            }
                                .font(CounselTheme.Typography.supporting)
                                .foregroundStyle(resultIsWarning ? CounselTheme.danger : CounselTheme.textSecondary)
                                .frame(maxWidth: 860, alignment: .leading)
                                .accessibilityLabel(Text(verbatim: resultMessage))
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(WindowContentTopInsetReader(topInset: $windowChromeTopInset))
        .onChange(of: model.restoreRequestToken) { _, _ in
            presentRestore()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("Restore")
                .font(CounselTheme.Typography.pageTitle)
                .foregroundStyle(CounselTheme.textPrimary)
            Text("Bring the real values back. Both paths run entirely on this Mac.")
                .font(CounselTheme.Typography.readingBody)
                .foregroundStyle(CounselTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Cards

    private var fileCard: some View {
        card(
            icon: "doc.badge.arrow.up",
            title: "Restore a redacted file",
            body: LocalizedStringKey(
                "You exported a redacted document earlier and it came back edited. "
                    + "Choose the file; its .ldamap mapping sidecar is picked up automatically "
                    + "from the same folder. If the mapping was protected with a passphrase, "
                    + "you will be asked for it."
            ),
            buttonTitle: "Choose File & Restore\u{2026}",
            buttonHelp: "Pick an edited redacted document and write the restored original (Cmd+R)",
            isProminent: true,
            action: presentRestore
        )
    }

    private func card(
        icon: String,
        title: LocalizedStringKey,
        body: LocalizedStringKey,
        buttonTitle: LocalizedStringKey,
        buttonHelp: String,
        isProminent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(CounselTheme.Typography.sectionTitle)
                .foregroundStyle(CounselTheme.textPrimary)
            Text(body)
                .font(CounselTheme.Typography.readingBody)
                .foregroundStyle(CounselTheme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Group {
                if isProminent {
                    Button(action: action) {
                        Text(buttonTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                } else {
                    Button(action: action) {
                        Text(buttonTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
            .help(L10n.string(buttonHelp))
        }
        .padding(24)
        .frame(minHeight: 240)
        .background(CounselTheme.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(CounselTheme.hairline, lineWidth: 1)
        )
    }

    // MARK: - Restore flow (file based)

    /// Restore an edited redacted document back to its originals: pick the file,
    /// locate or pick its .ldamap, ask for the passphrase if any, choose an
    /// output, run the restore, and report the result (including any tokens that
    /// could not be restored).
    private func presentRestore() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = Self.restoreContentTypes
        openPanel.message = L10n.string("Choose the edited redacted document to restore.")
        openPanel.prompt = L10n.string("Choose")
        guard openPanel.runModal() == .OK, let redacted = openPanel.url else { return }

        guard let mapping = locateMapping(for: redacted) else { return }
        guard let entered = askRestorePassphrase() else { return }
        let phrase = entered.isEmpty ? nil : entered

        let savePanel = NSSavePanel()
        savePanel.message = L10n.string("Save the restored document.")
        let base = redacted.deletingPathExtension().lastPathComponent
        let ext = redacted.pathExtension.isEmpty ? "txt" : redacted.pathExtension
        savePanel.nameFieldStringValue = "\(base)_restored.\(ext)"
        guard savePanel.runModal() == .OK, let output = savePanel.url else { return }

        do {
            let report = try model.restore(
                editedRedacted: redacted,
                mapping: mapping,
                passphrase: phrase,
                output: output
            )
            showRestoreResult(report)
        } catch {
            resultMessage = RestoreResultPresentation.failureResult(
                errorDescription: DocumentErrorPresentation.describeOrFallback(error)
            )
            resultIsWarning = true
        }
    }

    /// Find the sibling <base>.ldamap next to the redacted file, or let the user
    /// pick it. Returns nil if the user cancels.
    private func locateMapping(for redacted: URL) -> URL? {
        let sibling = redacted.deletingPathExtension().appendingPathExtension("ldamap")
        if FileManager.default.fileExists(atPath: sibling.path) { return sibling }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.string("Choose the .ldamap mapping that goes with this document.")
        panel.prompt = L10n.string("Choose")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Ask for the mapping passphrase. Returns the entered string (which may be
    /// empty, meaning Keychain), or nil if the user cancels.
    private func askRestorePassphrase() -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.string("Mapping passphrase")
        alert.informativeText = L10n.string(
            "If you protected this mapping with a passphrase, enter it. Leave it blank if it uses the Keychain."
        )
        alert.addButton(withTitle: L10n.string("Restore"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func showRestoreResult(_ report: RestoreReport) {
        if report.orphanTokens.isEmpty && report.suspectPlaceholders.isEmpty
            && report.ambiguousReplacements.isEmpty {
            resultMessage = RestoreResultPresentation.cleanResult(
                restoredCount: report.restoredCount,
                outputFileName: report.outputURL.lastPathComponent
            )
            resultIsWarning = false
        } else {
            var problems: [String] = []
            if let orphan = RestoreResultPresentation.orphanSentence(
                report.orphanTokens
            ) {
                problems.append(orphan)
            }
            if let damaged = RestoreResultPresentation.damagedSentence(
                report.suspectPlaceholders
            ) {
                problems.append(damaged)
            }
            if let ambiguous = RestoreResultPresentation
                .ambiguousSentence(report.ambiguousReplacements) {
                problems.append(ambiguous)
            }
            resultMessage = RestoreResultPresentation.warningResult(
                restoredCount: report.restoredCount,
                problems: problems,
                outputFileName: report.outputURL.lastPathComponent
            )
            resultIsWarning = true
        }
    }

    // MARK: - Content types

    /// The document types the restore Open panel accepts: the edit surfaces the
    /// export writes (plain text and Word).
    private static let restoreContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text]
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") {
            types.append(docx)
        }
        return types
    }()
}
