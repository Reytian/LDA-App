//
//  AppShell.swift
//  LDAUI
//
//  The top-level review window: a NavigationSplitView with the entity sidebar on
//  the leading side and the paper document pane as the detail. The unified
//  toolbar carries the Open control (.fileImporter for txt/docx/pdf), the
//  prominent ink-accent Export control (a directory picker plus an optional
//  passphrase sheet), and the "AI entities" toggle bound to the model. The
//  current status is surfaced unobtrusively as a subtle banner above the pane.
//
//  Counsel direction: the detail is solid paper; the sidebar uses the default
//  sidebar material. Hairlines over shadows. A single ink-blue accent is
//  reserved for the primary Export action and selection.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LDACore

/// The Counsel review window shell. Hosts the sidebar and the document pane in a
/// NavigationSplitView and owns the toolbar that drives the staged round-trip:
/// bring in, review, hand to AI, bring back and restore, save.
public struct AppShell: View {
    @ObservedObject private var session: SessionModel

    /// The active document's review model (the session forwards its changes).
    private var model: ReviewModel { session.activeModel }

    /// True while the passphrase sheet is presented, after a directory is chosen.
    @State private var isPromptingPassphrase = false

    /// True while the paste-and-restore sheet is presented.
    @State private var isPasteRestorePresented = false

    /// The directory chosen for export, held while the passphrase is collected.
    @State private var pendingExportDir: URL?

    /// The optional passphrase typed into the sheet. Empty means use the
    /// Keychain instead of a passphrase.
    @State private var passphrase = ""

    /// A one-line outcome message shown after an export completes or fails.
    @State private var exportMessage: String?

    public init(session: SessionModel) {
        self.session = session
    }

    public var body: some View {
        NavigationSplitView {
            EntitySidebar(session: session, model: model)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            VStack(spacing: 0) {
                statusBanner
                DocumentPane(session: session, model: model)
            }
            .background(CounselTheme.paper)
        }
        .background(CounselTheme.appSurface)
        .navigationTitle(windowTitle)
        .toolbar { toolbarContent }
        .sheet(isPresented: $isPromptingPassphrase) {
            passphraseSheet
        }
        .sheet(isPresented: $isPasteRestorePresented) {
            PasteRestoreSheet(session: session, isPresented: $isPasteRestorePresented)
        }
        .onChange(of: model.exportRequestToken) { _, _ in
            beginExport()
        }
        .onChange(of: model.restoreRequestToken) { _, _ in
            presentRestore()
        }
        .onChange(of: session.copyForAIRequestToken) { _, _ in
            runCopyForAI()
        }
        .onChange(of: session.pasteRestoreRequestToken) { _, _ in
            isPasteRestorePresented = true
        }
        .onChange(of: model.status) { _, status in
            announce(status)
        }
    }

    /// The window title: the client, the active document, or the product name.
    private var windowTitle: String {
        if let client = session.clientLabel {
            return model.documentName.map { "\(client) \u{00B7} \($0)" } ?? client
        }
        return model.documentName ?? "Legal Document Anonymizer"
    }

    /// Announce run completion to VoiceOver (status banners are otherwise silent).
    private func announce(_ status: ReviewStatus) {
        switch status {
        case .ready:
            AccessibilityNotification.Announcement(
                "Review ready. \(model.redactedCount) to redact, \(model.visibleCount) will remain visible."
            ).post()
        case .failed(let detail):
            AccessibilityNotification.Announcement("Could not process the document. \(detail)").post()
        default:
            break
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                presentOpenPanel()
            } label: {
                Label("Open", systemImage: "doc.badge.plus")
            }
            .help("Add .txt, .docx, .pdf documents or a .zip to the session")

            clientMenu
        }

        ToolbarItemGroup(placement: .automatic) {
            Button {
                Task { await model.anonymize() }
            } label: {
                Label("Anonymize", systemImage: "wand.and.rays")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            .tint(CounselTheme.inkAccentFill)
            .disabled(!canAnonymize)
            .help("Detect sensitive information in the open document")

            Button {
                runCopyForAI()
            } label: {
                Label("Copy for AI", systemImage: "arrow.right.doc.on.clipboard")
            }
            .labelStyle(.titleAndIcon)
            .disabled(!session.entries.contains { $0.model.canExport })
            .help("Copy the redacted text so you can paste it into any AI tool. Nothing leaves this Mac.")

            Button {
                isPasteRestorePresented = true
            } label: {
                Label("Restore from AI", systemImage: "arrow.left.doc.on.clipboard")
            }
            .labelStyle(.titleAndIcon)
            .help("Paste the AI's answer and restore the real values")

            Button {
                beginExport()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.titleAndIcon)
            .disabled(!model.canExport)
            .help("Write the redacted document and its encrypted mapping")
        }
    }

    /// The client profile menu (R10): pick a client so this session reuses and
    /// extends that client's identities, or work without one.
    private var clientMenu: some View {
        Menu {
            Button {
                session.clientLabel = nil
            } label: {
                if session.clientLabel == nil {
                    Label("No Client", systemImage: "checkmark")
                } else {
                    Text("No Client")
                }
            }

            let labels = session.clientLabels()
            if !labels.isEmpty {
                Divider()
                ForEach(labels, id: \.self) { label in
                    Button {
                        session.clientLabel = label
                    } label: {
                        if session.clientLabel == label {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
            }

            Divider()
            Button("New Client\u{2026}") {
                promptNewClient()
            }
        } label: {
            Label(session.clientLabel ?? "No Client", systemImage: "person.crop.square")
        }
        .help("Sessions under a client keep the same placeholders for the same values, every time")
    }

    /// Ask for a new client label with a small input alert and select it.
    private func promptNewClient() {
        let alert = NSAlert()
        alert.messageText = "New client profile"
        alert.informativeText = "Documents processed under this client keep consistent "
            + "placeholders across sessions. The mapping stays encrypted on this Mac."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Client or matter name"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        session.clientLabel = label
    }

    // MARK: - Hand to AI (stage 3)

    /// Build the session's redacted Markdown, put it on the clipboard, and give
    /// plain next-step guidance in the banner.
    private func runCopyForAI() {
        do {
            let createdAt = ISO8601DateFormatter().string(from: Date())
            guard let handoff = try session.buildHandToAI(createdAtISO8601: createdAt) else {
                exportMessage = "Anonymize a document first, then copy it for the AI."
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(handoff.combined, forType: .string)

            var message = "Redacted copy of \(handoff.documentCount) "
                + (handoff.documentCount == 1 ? "document" : "documents")
                + " is on the clipboard. Paste it into your AI tool, then bring the answer "
                + "back with Restore from AI."
            if handoff.skippedCount > 0 {
                message += "  \u{00B7}  \(handoff.skippedCount) "
                    + (handoff.skippedCount == 1 ? "document was" : "documents were")
                    + " skipped (not anonymized yet)."
            }
            exportMessage = message
        } catch {
            exportMessage = "Could not prepare the redacted copy. \(error.localizedDescription)"
        }
    }

    /// Anonymize is available once a document is imported, and again after a run
    /// (so the user can re-run, for example after toggling AI entities). It is not
    /// available while a pass is in flight.
    private var canAnonymize: Bool {
        switch model.status {
        case .imported, .ready:
            return true
        case .idle, .importing, .detecting, .failed:
            return false
        }
    }

    // MARK: - Status banner

    /// A subtle, unobtrusive banner that reflects model.status and the most
    /// recent export outcome. Hidden when idle with nothing to report.
    @ViewBuilder
    private var statusBanner: some View {
        if case .detecting = model.status {
            bannerChrome {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(CounselTheme.inkAccent)
                    .frame(maxWidth: 300)
                Text(detectingLabel)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(CounselTheme.textSecondary)
                Spacer(minLength: 0)
            }
        } else if case .ready = model.status {
            reviewSummaryBanner
        } else if let text = bannerText {
            bannerChrome {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(text)
                    .font(.callout)
                    .foregroundStyle(bannerIsError
                        ? CounselTheme.danger
                        : CounselTheme.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }

    /// The post-anonymize review summary: how many will be redacted, how many the
    /// user rejected (so will remain visible), an AI-unavailable warning, the
    /// learning note, and any export outcome. Gives the lawyer a trust signal
    /// before relying on the output.
    @ViewBuilder
    private var reviewSummaryBanner: some View {
        bannerChrome {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(CounselTheme.inkAccent)
            Text("\(model.redactedCount) to redact")
                .font(.callout).monospacedDigit()
                .foregroundStyle(CounselTheme.textPrimary)

            if model.visibleCount > 0 {
                Text("\u{00B7}  \(model.visibleCount) will remain visible")
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(CounselTheme.danger)
            }

            if !model.aiActive {
                Label("Pattern matching only", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.danger)
                    .help(model.aiWarning
                        ?? "The AI model was unavailable, so names, companies, and addresses may have been missed.")
            }

            if let warning = model.aiWarning {
                Text("\u{00B7}  \(warning)")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.danger)
                    .lineLimit(1)
                    .help(warning)
            }

            if let note = model.learningNote {
                Text("\u{00B7}  \(note)")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
            }

            Spacer(minLength: 0)

            if let exportMessage {
                Text(exportMessage)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// Shared banner container chrome.
    private func bannerChrome<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CounselTheme.hairline)
                .frame(height: 1)
        }
    }

    /// "Anonymizing 42%  ·  about 12s remaining"
    private var detectingLabel: String {
        let pct = Int((model.progress * 100).rounded())
        var label = "Anonymizing \(pct)%"
        if let eta = model.etaText {
            label += "  \u{00B7}  \(eta)"
        }
        return label
    }

    private var bannerText: String? {
        switch model.status {
        case .idle:
            return exportMessage
        case .importing:
            return "Importing document"
        case .imported:
            return "Document ready. Click Anonymize to detect sensitive information."
        case .detecting:
            return "Detecting entities"
        case .ready:
            if let exportMessage { return exportMessage }
            if let note = model.learningNote { return "Ready for review. \(note)." }
            return "Ready for review"
        case .failed(let detail):
            return detail
        }
    }

    private var bannerIsError: Bool {
        if case .failed = model.status { return true }
        return false
    }

    private var isWorking: Bool {
        switch model.status {
        case .importing, .detecting:
            return true
        default:
            return false
        }
    }

    // MARK: - Passphrase sheet

    private var passphraseSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Protect the mapping")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            Text("Enter an optional passphrase to encrypt the mapping sidecar. "
                + "Leave it blank to protect the mapping with the system Keychain.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Confidentiality nudge: the mapping sidecar holds the original
            // values (encrypted). Exporting into an iCloud-synced folder ships
            // that file off this Mac.
            if let dir = pendingExportDir, Self.isUnderICloud(dir) {
                Label(
                    "This folder syncs to iCloud. The encrypted mapping (which "
                        + "contains the original names) will be uploaded with it.",
                    systemImage: "icloud.and.arrow.up"
                )
                .font(.callout)
                .foregroundStyle(CounselTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
            }

            // Trust confirmation: what is and is not being redacted.
            (Text("\(model.redactedCount)").bold() + Text(" entities will be redacted.")
                + (model.visibleCount > 0
                    ? Text("  \(model.visibleCount) you rejected will remain visible in the exported file.")
                        .foregroundColor(CounselTheme.danger)
                    : Text("")))
                .font(.callout)
                .foregroundStyle(CounselTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Passphrase (optional)", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    cancelPassphrase()
                }
                .keyboardShortcut(.cancelAction)

                Button("Export") {
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

    // MARK: - Open flow

    /// Present a native open panel for the session's documents. NSOpenPanel is
    /// used instead of SwiftUI .fileImporter because two .fileImporter modifiers
    /// on the same view conflict and silently fail to present.
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.openContentTypes
        panel.message = "Choose .txt, .docx, .pdf documents, or a .zip of them. Several files become one session."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        exportMessage = nil
        let scoped = panel.urls.map { (url: $0, needsScope: $0.startAccessingSecurityScopedResource()) }
        Task {
            // defer releases the sandbox scopes even if the Task is cancelled
            // mid-import; leaking one can make later opens of the same URL fail.
            defer {
                for item in scoped where item.needsScope {
                    item.url.stopAccessingSecurityScopedResource()
                }
            }
            await session.addDocuments(scoped.map { $0.url })
        }
    }

    // MARK: - Export flow

    private func beginExport() {
        guard model.canExport else { return }
        exportMessage = nil
        passphrase = ""
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for the redacted document and encrypted mapping."
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        pendingExportDir = dir
        isPromptingPassphrase = true
    }

    private func cancelPassphrase() {
        isPromptingPassphrase = false
        pendingExportDir = nil
        passphrase = ""
    }

    private func confirmExport() {
        isPromptingPassphrase = false
        guard let dir = pendingExportDir else { return }

        let phrase = passphrase.isEmpty ? nil : passphrase
        let createdAt = ISO8601DateFormatter().string(from: Date())
        pendingExportDir = nil
        passphrase = ""

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
                var message = "Exported \(outcome.tokenCount) "
                    + (outcome.tokenCount == 1 ? "token to " : "tokens to ")
                    + outcome.redactedURL.lastPathComponent
                if outcome.embeddedMediaCount > 0 {
                    message += "  \u{00B7}  Warning: \(outcome.embeddedMediaCount) embedded "
                        + (outcome.embeddedMediaCount == 1 ? "image was" : "images were")
                        + " copied unscanned (signatures or stamps may remain)."
                }
                exportMessage = message
            } catch {
                exportMessage = "Export failed. \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Restore flow (de-anonymize)

    /// Restore an edited redacted document back to its originals: pick the file,
    /// locate or pick its .ldamap, ask for the passphrase if any, choose an
    /// output, run the restore, and report the result (including any tokens that
    /// could not be restored).
    private func presentRestore() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.allowedContentTypes = Self.openContentTypes
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
            showAlert(title: "Restore failed", text: error.localizedDescription, warning: true)
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
        alert.informativeText = "If you protected this mapping with a passphrase, enter it. Leave it blank if it uses the Keychain."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func showRestoreResult(_ report: RestoreReport) {
        if report.orphanTokens.isEmpty && report.suspectPlaceholders.isEmpty {
            showAlert(
                title: "Document restored",
                text: "Restored \(report.restoredCount) value"
                    + (report.restoredCount == 1 ? "" : "s")
                    + " to \(report.outputURL.lastPathComponent).",
                warning: false
            )
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
            showAlert(
                title: "Restored with warnings",
                text: "Restored \(report.restoredCount) values. "
                    + problems.joined(separator: " ")
                    + " Nothing was guessed; please review these in "
                    + "\(report.outputURL.lastPathComponent) and fix them by hand.",
                warning: true
            )
        }
    }

    private func showAlert(title: String, text: String, warning: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = warning ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// True when the directory lives inside iCloud Drive (any app container or
    /// the Desktop and Documents sync surface).
    private static func isUnderICloud(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/Library/Mobile Documents/")
    }

    // MARK: - Content types

    /// The document types the Open panel accepts: plain text, Word, and PDF.
    private static let openContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .pdf, .zip]
        if let docx = UTType(
            "org.openxmlformats.wordprocessingml.document"
        ) {
            types.append(docx)
        }
        return types
    }()
}

