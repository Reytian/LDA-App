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
//  workspace LDA keeps for this document, the matter's stored mapping, and
//  only then a picker. A passphrase is asked for only after a Keychain load
//  fails.
//
//  Word documents restore through LDAService with their formatting kept.
//  Markdown and text restore as text, or as a plain regenerated Word file
//  when the reader picks Word in the preview sheet's format control; merging
//  AI edits back into the original Word runs is not offered.
//
//  ORDER OF OPERATIONS, which changed: resolve the mapping, compute the
//  restore WITHOUT writing, show it, and only on approval ask where the
//  document goes and write it. Cancel writes nothing. This flow used to pick
//  the destination first and write unconditionally, so the reader saw the
//  result, and every warning about it, only after the file was on disk.
//
//  The heavy lifting stays in SessionModel+RestoreFile / LDAService; this view
//  is chrome, file pickers, and honest result reporting (orphaned or damaged
//  placeholders are listed, never guessed at, and the result names which key
//  opened the file).
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

    /// The restore awaiting approval, and the sheet that shows it. Nil means
    /// no restore is in flight and nothing is pending a write.
    @State private var pending: PendingRestore?

    /// The sandbox grant a DROPPED file arrived with, held for the whole flow.
    ///
    /// This is the hazard the preview sheet introduces. The grant used to be
    /// released in a `defer` on restore(dropped:), which was correct only
    /// because the write finished before that function returned. It no longer
    /// does: the write now happens after the reader approves, on a later run
    /// loop turn. A `defer` would therefore revoke the grant before the file
    /// is read or the output written, and only under the App Sandbox, which
    /// neither XCTest nor the unsandboxed dev binary exercises. So the grant
    /// is held here for as long as the flow needs it and released in exactly
    /// two places: the sheet's dismissal, whichever way it ends, and the early
    /// return in beginRestore(file:) where no sheet will ever appear.
    @State private var droppedAccess: ScopedFileAccess?

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
        // onDismiss covers both ways the sheet closes, the reader's Cancel and
        // the Escape key, so the dropped file's grant is given back on every
        // path that reaches a sheet at all.
        .sheet(item: $pending, onDismiss: releaseDroppedAccess) { request in
            RestorePreviewSheet(
                request: request,
                onApprove: { amendments, format in
                    approve(request, amendments: amendments, format: format)
                },
                onCancel: { pending = nil }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            L10n.text("Restore")
                .font(CounselTheme.Typography.pageTitle)
                .foregroundStyle(CounselTheme.textPrimary)
            L10n.text("Bring the real values back. Restore runs on this Mac.")
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
            body: "Choose or drop a redacted Word, Markdown, or text file. Review the restored values before saving a new copy.",
            buttonTitle: "Choose File & Preview\u{2026}",
            buttonHelp: "Pick the file that came back, review the restored document, then save it (Cmd+R)",
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
        title: String,
        body: String,
        buttonTitle: String,
        buttonHelp: String,
        isProminent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            L10n.label(title, systemImage: icon)
                .font(CounselTheme.Typography.sectionTitle)
                .foregroundStyle(CounselTheme.textPrimary)
            L10n.text(body)
                .font(CounselTheme.Typography.readingBody)
                .foregroundStyle(CounselTheme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Group {
                if isProminent {
                    Button(action: action) {
                        L10n.text(buttonTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                } else {
                    Button(action: action) {
                        L10n.text(buttonTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
            .help(L10n.string(buttonHelp))

            DisclosureGroup {
                L10n.text("LDA looks for the mapping in this session, the document workspace, or a .ldamap beside the file. If needed, you can choose a mapping file. Word documents keep their formatting.")
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } label: {
                L10n.text("How restoration works")
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textSecondary)
            }
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

    /// The button path: pick the file, then run the shared flow. A file chosen
    /// in an open panel is granted on its own and needs no held scope.
    private func presentRestore() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = Self.restoreContentTypes
        openPanel.message = L10n.string("Choose the edited redacted document to restore.")
        openPanel.prompt = L10n.string("Choose")
        guard openPanel.runModal() == .OK, let file = openPanel.url else { return }
        _ = beginRestore(file: file)
    }

    /// The drop path: the same flow, holding the sandbox grant a dropped URL
    /// needs for as long as the flow needs it, after refusing files Restore
    /// cannot open.
    private func restore(dropped file: URL) {
        guard Self.supportedExtensions.contains(file.pathExtension.lowercased()) else {
            showFailure(String(
                format: L10n.string("Restore opens .md, .txt, and .docx files. %@ is not one of them."),
                file.lastPathComponent as NSString
            ))
            return
        }
        // Taken BEFORE the mapping and preview work, both of which read the
        // file and its sibling .ldamap. See droppedAccess for why this is not
        // a `defer` any more.
        let access = ScopedFileAccess(file)
        droppedAccess = access
        if !beginRestore(file: file) {
            // No sheet will be presented, so nothing will call onDismiss.
            // Give the grant back here rather than leaving it to deinit.
            droppedAccess = nil
            access.release()
        }
    }

    /// Resolve the mapping, compute the restore without writing, and present
    /// it for approval. Returns whether a sheet is now pending, which is what
    /// tells the drop path whether its grant will be released on dismissal.
    private func beginRestore(file: URL) -> Bool {
        guard let key = resolveMapping(for: file) else { return false }
        do {
            let preview = try LDAService.restorePreview(
                editedRedacted: file,
                mapping: key.mapping
            )
            // Fingerprinted here, next to the read the preview is computed
            // from, so the approval can refuse a file that changed while the
            // sheet was up. See RestoreSourceGuard.swift.
            let previewedSource = try SourceFingerprint.of(file)
            pending = PendingRestore(
                file: file,
                mapping: key.mapping,
                keySource: key.source,
                preview: preview,
                previewedSource: previewedSource
            )
            resultMessage = nil
            return true
        } catch {
            showFailure(DocumentErrorPresentation.describeOrFallback(error))
            return false
        }
    }

    /// The approved path: apply the amendments, ask where the document goes,
    /// write it, report. The save panel comes LAST, so a reader who backs out
    /// of it has written nothing and keeps their amendments on the sheet.
    private func approve(
        _ request: PendingRestore,
        amendments: [String: String],
        format: RestoreOutputFormat
    ) {
        let outcome = RestoreApproval.run(
            file: request.file,
            mapping: request.mapping,
            preview: request.preview,
            previewedSource: request.previewedSource,
            amendments: amendments,
            format: format,
            chooseOutput: chooseOutput,
            write: { file, mapping, output in
                try session.restoreFile(file, mapping: mapping, output: output)
            }
        )
        switch outcome {
        case .cancelled:
            // Deliberately leaves the sheet up: backing out of the save panel
            // is not backing out of the restore.
            return
        case .written(let report):
            showRestoreResult(report, keySource: request.keySource)
        case .failed(let error):
            showFailure(DocumentErrorPresentation.describeOrFallback(error))
        }
        pending = nil
    }

    /// Give back a dropped file's sandbox grant. Called from the sheet's
    /// dismissal, so it runs for an approval, a Cancel, and an Escape alike.
    private func releaseDroppedAccess() {
        droppedAccess?.release()
        droppedAccess = nil
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
            // The sibling is reachable only as the chosen file's related item.
            return openSidecar(sidecar, primary: file).map { ($0, .sidecar) }
        case .session(let mapping), .clientProfile(let mapping):
            return (mapping, .session)
        case .defaultWorkspace(let mapping):
            return (mapping, .defaultWorkspace)
        case .none:
            guard confirmChoosingAMapping(), let picked = pickMapping() else { return nil }
            // Picked in an open panel, so granted on its own.
            return openPickedKey(picked).map { ($0, .chosenMapping) }
        }
    }

    /// Open a key the user picked by hand: a .ldamap sidecar, or a workspace.
    ///
    /// A workspace is offered here because it is now where an ordinary Save
    /// Redacted leaves its key, so a picker that took only .ldamap files would
    /// send the user hunting for a file this app no longer writes by default.
    /// It is also the honest answer for the case the resolver deliberately
    /// refuses to guess at: two documents with the same name, where the app
    /// can see two candidate workspaces and only the user knows which matter
    /// the file came from.
    private func openPickedKey(_ picked: URL) -> Mapping? {
        guard picked.pathExtension == WorkspaceArchive.fileExtension else {
            return openSidecar(picked, primary: nil)
        }
        return openPickedWorkspace(picked)
    }

    /// Read a picked workspace's mapping, trying this Mac's own key first and
    /// asking for a passphrase only when that fails.
    ///
    /// Same shape as openSidecar, and for the same reason: a workspace LDA
    /// keeps for a document opens with no question, while one a colleague sent
    /// needs the passphrase they chose. Only the mapping member is read, so a
    /// picked workspace never unpacks its documents to disk.
    private func openPickedWorkspace(_ workspaceURL: URL) -> Mapping? {
        func read(_ protection: MappingProtection) throws -> Mapping? {
            try WorkspaceArchive.readMapping(from: workspaceURL, protection: protection)
        }
        do {
            let keychain = MappingProtection.keychain(
                account: DefaultWorkspace.keychainAccount(for: workspaceURL)
            )
            if let mapping = try read(keychain) { return mapping }
            showFailure(L10n.string("That workspace file holds no mapping yet."))
            return nil
        } catch {
            guard let passphrase = askWorkspacePassphrase() else { return nil }
            do {
                guard let mapping = try read(.passphrase(passphrase)) else {
                    showFailure(L10n.string("That workspace file holds no mapping yet."))
                    return nil
                }
                return mapping
            } catch {
                showFailure(
                    WorkspacePresentation.archiveErrorDescription(error)
                        ?? DocumentErrorPresentation.describeOrFallback(error)
                )
                return nil
            }
        }
    }

    /// Open a sidecar through its Keychain account, and ask for a passphrase
    /// only when that fails for a key reason.
    private func openSidecar(_ sidecar: URL, primary: URL?) -> Mapping? {
        do {
            return try SessionModel.loadSidecarMapping(at: sidecar, primary: primary)
        } catch where SessionModel.sidecarLoadNeedsPassphrase(error) {
            guard let passphrase = askRestorePassphrase() else { return nil }
            do {
                return try SessionModel.loadSidecarMapping(
                    at: sidecar,
                    primary: primary,
                    passphrase: passphrase
                )
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
        alert.messageText = L10n.string("No single mapping was found for this file.")
        alert.informativeText = L10n.string(
            "Choose the .ldamap saved with it, or the workspace for the document it came from."
        )
        alert.addButton(withTitle: L10n.string("Choose Mapping\u{2026}"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func pickMapping() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            MappingStore.fileExtension,
            WorkspaceArchive.fileExtension
        ].compactMap { UTType(filenameExtension: $0) }
        panel.message = L10n.string(
            "Choose the .ldamap or workspace file that goes with this document."
        )
        panel.prompt = L10n.string("Choose")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Ask for a picked workspace's passphrase, shown only after this Mac's
    /// own key could not open it. Returns nil when the user cancels or types
    /// nothing.
    private func askWorkspacePassphrase() -> String? {
        let alert = NSAlert()
        alert.messageText = L10n.string("Workspace passphrase")
        alert.informativeText = L10n.string(
            "Enter the passphrase this workspace file was saved with. Its contents are decrypted locally after you enter the passphrase."
        )
        alert.addButton(withTitle: L10n.string("Restore"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.isEmpty ? nil : field.stringValue
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

    /// Where the restored document goes, in the container the reader picked on
    /// the preview sheet.
    ///
    /// The panel is now filtered to that ONE type, so the choice reaches
    /// LDAService (which decides the writer from the output extension) without
    /// the reader having to retype an extension. It used to be filtered to
    /// every allowed type at once with no control to pick among them, which is
    /// why the Markdown to Word restore was unreachable in practice.
    private func chooseOutput(suggestedName: String, format: RestoreOutputFormat) -> URL? {
        let panel = NSSavePanel()
        panel.message = L10n.string("Save the restored document.")
        panel.allowedContentTypes = [Self.contentType(for: format)].compactMap { $0 }
        panel.nameFieldStringValue = suggestedName
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

    /// The save panel's filter for one chosen output format. The only place
    /// the reader's choice is turned into a system type; the format itself
    /// stays Foundation only so it can be tested without a panel.
    private static func contentType(for format: RestoreOutputFormat) -> UTType? {
        switch format {
        case .markdown: return markdownType
        case .plainText: return .plainText
        case .word: return wordType
        }
    }
}
