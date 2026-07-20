//
//  DeanonymizeShell.swift
//  LDAUI
//
//  The De-anonymize mode: everything that brings REAL values back after work
//  was done on redacted text. Two paths, presented as two cards:
//
//  1. Paste back an AI reply. The counterpart of "Copy for AI" in the
//     Anonymize mode: the reply still carries placeholders; pasting it here
//     swaps the real values back in using the session's mappings. The sheet
//     itself is window-level (owned by RootShell) so the menu bar and the
//     companion can also summon it; this card just requests it.
//
//  2. Restore a redacted file. A previously exported redacted document plus
//     its .ldamap sidecar (and passphrase, if one was set) round-trips back
//     to the original values. This flow lived behind the Cmd+R menu item
//     inside the Anonymize shell before; as the second half of the product's
//     core promise it deserves a first-class surface.
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

/// The De-anonymize mode surface.
public struct DeanonymizeShell: View {
    @ObservedObject private var session: SessionModel

    /// The active document's review model (used for the restore entry point;
    /// restore itself is stateless with respect to the review session).
    private var model: ReviewModel { session.activeModel }

    /// Whether this shell is the frontmost mode. Gates the toolbar so hidden
    /// layers do not contribute items.
    private let isActive: Bool

    /// Asks the window to present the paste-and-restore sheet.
    private let onPasteFromAI: () -> Void

    /// A one-line outcome message shown after a restore completes or fails.
    @State private var resultMessage: String?
    @State private var resultIsWarning = false

    public init(
        session: SessionModel,
        isActive: Bool = true,
        onPasteFromAI: @escaping () -> Void
    ) {
        self.session = session
        self.isActive = isActive
        self.onPasteFromAI = onPasteFromAI
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            CounselTheme.paper.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    header
                    HStack(alignment: .top, spacing: 20) {
                        pasteCard
                        fileCard
                    }
                    .frame(maxWidth: 860)
                    if let resultMessage {
                        Label(resultMessage, systemImage: resultIsWarning
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(resultIsWarning ? CounselTheme.danger : CounselTheme.textSecondary)
                            .frame(maxWidth: 860, alignment: .leading)
                            .accessibilityLabel(Text(resultMessage))
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: model.restoreRequestToken) { _, _ in
            presentRestore()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("Restore")
                .font(.title2.weight(.semibold))
                .foregroundStyle(CounselTheme.textPrimary)
            Text("Bring the real values back. Both paths run entirely on this Mac.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
        }
        .padding(.top, 24)
    }

    // MARK: - Cards

    private var pasteCard: some View {
        card(
            icon: "arrow.left.doc.on.clipboard",
            title: "Paste back an AI reply",
            body: "You copied redacted text with Copy for AI and worked on it in an AI tool. "
                + "Paste the reply here: every placeholder is swapped back to the real value "
                + "using this session's mapping.",
            buttonTitle: "Paste from AI\u{2026}",
            buttonHelp: "Paste the AI's answer and restore the real values (Cmd+Shift+V)",
            isProminent: true,
            action: onPasteFromAI
        )
    }

    private var fileCard: some View {
        card(
            icon: "doc.badge.arrow.up",
            title: "Restore a redacted file",
            body: "You exported a redacted document earlier and it came back edited. "
                + "Choose the file; its .ldamap mapping sidecar is picked up automatically "
                + "from the same folder. If the mapping was protected with a passphrase, "
                + "you will be asked for it.",
            buttonTitle: "Choose File & Restore\u{2026}",
            buttonHelp: "Pick an edited redacted document and write the restored original (Cmd+R)",
            isProminent: false,
            action: presentRestore
        )
    }

    private func card(
        icon: String,
        title: String,
        body: String,
        buttonTitle: String,
        buttonHelp: String,
        isProminent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)
            Text(body)
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
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
            .help(buttonHelp)
        }
        .padding(20)
        .frame(minHeight: 220)
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
        openPanel.message = "Choose the edited redacted document to restore."
        openPanel.prompt = "Choose"
        guard openPanel.runModal() == .OK, let redacted = openPanel.url else { return }

        guard let mapping = locateMapping(for: redacted) else { return }
        guard let entered = askRestorePassphrase() else { return }
        let phrase = entered.isEmpty ? nil : entered

        let savePanel = NSSavePanel()
        savePanel.message = "Save the restored document."
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
            resultMessage = "Restore failed. \(error.localizedDescription)"
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
        panel.message = "Choose the .ldamap mapping that goes with this document."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Ask for the mapping passphrase. Returns the entered string (which may be
    /// empty, meaning Keychain), or nil if the user cancels.
    private func askRestorePassphrase() -> String? {
        let alert = NSAlert()
        alert.messageText = "Mapping passphrase"
        alert.informativeText = "If you protected this mapping with a passphrase, enter it. "
            + "Leave it blank if it uses the Keychain."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func showRestoreResult(_ report: RestoreReport) {
        if report.orphanTokens.isEmpty && report.suspectPlaceholders.isEmpty {
            resultMessage = "Restored \(report.restoredCount) value"
                + (report.restoredCount == 1 ? "" : "s")
                + " to \(report.outputURL.lastPathComponent)."
            resultIsWarning = false
        } else {
            var problems: [String] = []
            if !report.orphanTokens.isEmpty {
                let sample = report.orphanTokens.prefix(5).joined(separator: ", ")
                problems.append(
                    "\(report.orphanTokens.count) placeholder"
                        + (report.orphanTokens.count == 1 ? "" : "s")
                        + " could not be matched: \(sample)."
                )
            }
            if !report.suspectPlaceholders.isEmpty {
                let sample = report.suspectPlaceholders.prefix(5).joined(separator: ", ")
                problems.append(
                    "\(report.suspectPlaceholders.count) placeholder"
                        + (report.suspectPlaceholders.count == 1 ? " looks" : "s look")
                        + " damaged by editing: \(sample)."
                )
            }
            resultMessage = "Restored \(report.restoredCount) values with warnings. "
                + problems.joined(separator: " ")
                + " Nothing was guessed; review these in \(report.outputURL.lastPathComponent)"
                + " and fix them by hand."
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
