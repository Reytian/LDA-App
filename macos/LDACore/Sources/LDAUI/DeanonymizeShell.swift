//
//  DeanonymizeShell.swift
//  LDAUI
//
//  The Restore mode: everything that brings REAL values back after work was
//  done on redacted text. One card, one flow: choose or drop the file that
//  came back (the Markdown exported for the AI, or a redacted Word document
//  saved with Save Redacted), and the mapping is resolved without questions
//  the app can answer itself. In order: the .ldamap saved next to the file,
//  the session mapping (the parked round trip is resumed just in time), the
//  matter's stored mapping, and only then a picker. A passphrase is asked for
//  only after a Keychain load fails.
//
//  Word documents restore through LDAService with their formatting kept.
//  Markdown and text restore as text, or as a plain regenerated Word file
//  when the user picks .docx in the save panel; merging AI edits back into
//  the original Word runs is not offered.
//
//  The heavy lifting stays in SessionModel+RestoreFile / LDAService.restore;
//  this view is chrome, file pickers, and honest result reporting (orphaned
//  or damaged placeholders are listed, never guessed at, and the result names
//  which key opened the file).
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LDACore

// MARK: - DeanonymizeShell

/// The Restore mode surface.
public struct DeanonymizeShell: View {
    @ObservedObject private var session: SessionModel

    /// The active document's review model: its restoreRequestToken is the
    /// Cmd+R menu hook.
    private var model: ReviewModel { session.activeModel }

    /// Whether this shell is the frontmost mode. Gates the toolbar so hidden
    /// layers do not contribute items.
    private let isActive: Bool

    /// A one-line outcome message shown after a restore completes or fails.
    @State private var resultMessage: String?
    @State private var resultIsWarning = false

    /// True while a file is being dragged over the card.
    @State private var isDropTargeted = false
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
                        VStack(spacing: 16) {
                            restoreCard
                                .frame(maxWidth: 560)
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
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityLabel(Text(verbatim: resultMessage))
                            }
                        }
                        .frame(maxWidth: 860)
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
            Text("Bring the real values back. Restore runs on this Mac.")
                .font(CounselTheme.Typography.readingBody)
                .foregroundStyle(CounselTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - The card

    private var restoreCard: some View {
        card(
            icon: "doc.badge.arrow.up",
            title: "Restore a file",
            body: LocalizedStringKey(
                "Choose or drop the file that came back: the Markdown you exported for the AI, "
                    + "or a redacted Word document you saved. The mapping is found automatically "
                    + "from this session or from the .ldamap saved next to the file. "
                    + "Formatting is kept when the file is a Word document."
            ),
            buttonTitle: "Choose File & Restore\u{2026}",
            buttonHelp: "Pick the file that came back and write the restored document (Cmd+R)",
            isProminent: true,
            action: presentRestore
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isDropTargeted ? CounselTheme.inkAccent : .clear, lineWidth: 2)
        )
        // Dropping a file starts the same flow as the button.
        .dropDestination(for: URL.self) { urls, _ in
            guard let dropped = urls.first else { return false }
            restore(dropped: dropped)
            return true
        } isTargeted: { isDropTargeted = $0 }
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

    // MARK: - Restore flow

    /// The button path: pick the file, then run the shared flow.
    private func presentRestore() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = Self.restoreContentTypes
        openPanel.message = L10n.string("Choose the edited redacted document to restore.")
        openPanel.prompt = L10n.string("Choose")
        guard openPanel.runModal() == .OK, let file = openPanel.url else { return }
        restore(file: file)
    }

    /// The drop path: the same flow, inside the sandbox scope a dropped URL
    /// needs, after refusing files Restore cannot open.
    private func restore(dropped file: URL) {
        guard Self.supportedExtensions.contains(file.pathExtension.lowercased()) else {
            showFailure(String(
                format: L10n.string("Restore opens .md, .txt, and .docx files. %@ is not one of them."),
                file.lastPathComponent as NSString
            ))
            return
        }
        let needsScope = file.startAccessingSecurityScopedResource()
        defer { if needsScope { file.stopAccessingSecurityScopedResource() } }
        restore(file: file)
    }

    /// Resolve the mapping, choose the output, restore, report.
    private func restore(file: URL) {
        guard let key = resolveMapping(for: file) else { return }
        guard let output = chooseOutput(for: file) else { return }
        do {
            let report = try session.restoreFile(file, mapping: key.mapping, output: output)
            showRestoreResult(report, keySource: key.source)
        } catch {
            showFailure(DocumentErrorPresentation.describeOrFallback(error))
        }
    }

    /// The mapping for this file and which key it is. Nil when the user
    /// cancelled or a failure was already shown.
    private func resolveMapping(
        for file: URL
    ) -> (mapping: Mapping, source: RestoreResultPresentation.KeySource)? {
        let source: SessionModel.RestoreMappingSource
        do {
            source = try session.restoreMappingSource(for: file)
        } catch {
            showFailure(DocumentErrorPresentation.describeOrFallback(error))
            return nil
        }
        switch source {
        case .sidecar(let sidecar):
            return openSidecar(sidecar).map { ($0, .sidecar) }
        case .session(let mapping), .clientProfile(let mapping):
            return (mapping, .session)
        case .none:
            guard confirmChoosingAMapping(), let picked = pickMapping() else { return nil }
            return openSidecar(picked).map { ($0, .chosenMapping) }
        }
    }

    /// Open a sidecar through its Keychain account, and ask for a passphrase
    /// only when that fails for a key reason.
    private func openSidecar(_ sidecar: URL) -> Mapping? {
        do {
            return try SessionModel.loadSidecarMapping(at: sidecar)
        } catch where SessionModel.sidecarLoadNeedsPassphrase(error) {
            guard let passphrase = askRestorePassphrase() else { return nil }
            do {
                return try SessionModel.loadSidecarMapping(at: sidecar, passphrase: passphrase)
            } catch {
                showFailure(DocumentErrorPresentation.describeOrFallback(error))
                return nil
            }
        } catch {
            showFailure(DocumentErrorPresentation.describeOrFallback(error))
            return nil
        }
    }

    /// The one alert of the flow: nothing this session knows opens the file.
    private func confirmChoosingAMapping() -> Bool {
        let alert = NSAlert()
        alert.messageText = L10n.string("No mapping was found for this file.")
        alert.informativeText = L10n.string("Choose the .ldamap that was saved with it.")
        alert.addButton(withTitle: L10n.string("Choose Mapping\u{2026}"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func pickMapping() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let mappingType = UTType(filenameExtension: "ldamap") {
            panel.allowedContentTypes = [mappingType]
        }
        panel.message = L10n.string("Choose the .ldamap mapping that goes with this document.")
        panel.prompt = L10n.string("Choose")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Ask for the mapping passphrase, shown only after the Keychain could not
    /// open the sidecar. Returns nil when the user cancels or types nothing.
    private func askRestorePassphrase() -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.string("Mapping passphrase")
        alert.informativeText = L10n.string(
            "This mapping was protected with a passphrase. Enter it to restore."
        )
        alert.addButton(withTitle: L10n.string("Restore"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.isEmpty ? nil : field.stringValue
    }

    /// Where the restored document goes. A Word input stays Word; text input
    /// defaults to its own extension and may become a plain Word file.
    private func chooseOutput(for file: URL) -> URL? {
        let panel = NSSavePanel()
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension.lowercased()
        if ext == "docx" {
            panel.message = L10n.string("Save the restored document.")
            panel.allowedContentTypes = [Self.wordType].compactMap { $0 }
            panel.nameFieldStringValue = "\(base)_restored.docx"
        } else {
            panel.message = L10n.string("Word output from Markdown carries plain formatting.")
            panel.allowedContentTypes = Self.textOutputTypes(for: ext)
            panel.nameFieldStringValue = "\(base)_restored.\(ext.isEmpty ? "txt" : ext)"
        }
        guard panel.runModal() == .OK, let output = panel.url else { return nil }
        return output
    }

    // MARK: - Results

    private func showRestoreResult(
        _ report: RestoreReport,
        keySource: RestoreResultPresentation.KeySource
    ) {
        let keyNote = RestoreResultPresentation.keySentence(for: keySource)
        let problems = [
            RestoreResultPresentation.orphanSentence(report.orphanTokens),
            RestoreResultPresentation.damagedSentence(report.suspectPlaceholders),
            RestoreResultPresentation.ambiguousSentence(report.ambiguousReplacements)
        ].compactMap { $0 }
        guard problems.isEmpty else {
            resultMessage = RestoreResultPresentation.warningResult(
                restoredCount: report.restoredCount,
                problems: problems,
                outputFileName: report.outputURL.lastPathComponent,
                keyNote: keyNote
            )
            resultIsWarning = true
            return
        }
        resultMessage = RestoreResultPresentation.cleanResult(
            restoredCount: report.restoredCount,
            outputFileName: report.outputURL.lastPathComponent,
            keyNote: keyNote
        )
        resultIsWarning = false
    }

    private func showFailure(_ description: String) {
        resultMessage = RestoreResultPresentation.failureResult(errorDescription: description)
        resultIsWarning = true
    }

    // MARK: - Content types

    /// The files Restore opens: the Markdown export, plain text, and Word.
    static let supportedExtensions: Set<String> = ["md", "txt", "text", "docx"]

    private static let wordType = UTType("org.openxmlformats.wordprocessingml.document")
    private static let markdownType = UTType(filenameExtension: "md")

    /// The Open panel's filter.
    private static let restoreContentTypes: [UTType] =
        [markdownType, .plainText, .text, wordType].compactMap { $0 }

    /// The save panel's filter for a text input: its own kind first, then
    /// Word for the plain regenerated document.
    private static func textOutputTypes(for ext: String) -> [UTType] {
        var types: [UTType] = []
        if ext == "md", let markdownType { types.append(markdownType) }
        types.append(.plainText)
        if let wordType { types.append(wordType) }
        return types
    }
}
