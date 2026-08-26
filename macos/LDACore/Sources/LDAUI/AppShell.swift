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

    /// Whether this shell is the frontmost mode. Gates the toolbar: RootShell
    /// keeps every mode's view alive in a ZStack, and SwiftUI merges toolbar
    /// items from all live layers, so an inactive shell must contribute none.
    private let isActive: Bool

    /// True while the passphrase sheet is presented, after a directory is chosen.
    @State private var isPromptingPassphrase = false

    /// The directory chosen for export, held while the passphrase is collected.
    @State private var pendingExportDir: URL?

    /// The optional passphrase typed into the sheet. Empty means use the
    /// Keychain instead of a passphrase.
    @State private var passphrase = ""

    /// A one-line outcome message shown after an export completes or fails.
    @State private var exportMessage: String?

    /// First-run flag: the onboarding sheet shows once (R13/R17).
    @AppStorage("com.haotianyi.LDA.hasCompletedFirstRun") private var hasCompletedFirstRun = false

    /// True while the onboarding sheet is presented.
    @State private var isOnboardingPresented = false

    /// Whether Touch ID protection actually took effect. Shown next to the
    /// On-device badge when it did not, so the trust claim in the UI matches
    /// what the Keychain is really doing.
    @StateObject private var keychainAdvisory = KeychainAdvisoryStore()

    public init(session: SessionModel, isActive: Bool = true) {
        self.session = session
        self.isActive = isActive
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
        .sheet(isPresented: $isOnboardingPresented, onDismiss: { hasCompletedFirstRun = true }) {
            OnboardingView(
                isPresented: $isOnboardingPresented,
                modelAvailable: model.modelPath.map {
                    FileManager.default.fileExists(atPath: $0)
                } == true
            )
        }
        .onAppear {
            if !hasCompletedFirstRun {
                isOnboardingPresented = true
            }
        }
        .onChange(of: model.exportRequestToken) { _, _ in
            beginExport()
        }
        .onChange(of: model.anonymizeRequestToken) { _, _ in
            guard model.canAnonymize else { return }
            Task { await model.anonymize() }
        }
        .onChange(of: session.copyForAIRequestToken) { _, _ in
            runCopyForAI()
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
        if isActive {
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
                // The mode's primary action (Scan for PII) lives in the status
                // banner, not here: toolbar items overflow into the >> menu on
                // narrow windows, and the primary action must never disappear.
                Button {
                    runCopyForAI()
                } label: {
                    Label("Copy for AI", systemImage: "arrow.right.doc.on.clipboard")
                }
                .labelStyle(.titleAndIcon)
                .disabled(!session.entries.contains { $0.model.canExport })
                .help("Copy the redacted text so you can paste it into any AI tool. Nothing leaves this Mac.")

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
                exportMessage = "Scan a document for PII first, then copy it for the AI."
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(handoff.combined, forType: .string)

            var message = "Redacted copy of \(handoff.documentCount) "
                + (handoff.documentCount == 1 ? "document" : "documents")
                + " is on the clipboard. Paste it into your AI tool, then bring the answer "
                + "back in the De-anonymize tab."
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
    private var canAnonymize: Bool { model.canAnonymize }

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
                Button {
                    model.cancelAnonymize()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(CounselTheme.danger)
                .help("Stop anonymizing. The document stays loaded; no partial results are shown.")
                .accessibilityIdentifier("stopAnonymize")
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
                // The mode's primary action lives IN the banner, next to the
                // sentence that names it: it can never vanish into toolbar
                // overflow on a narrow window.
                if case .imported = model.status {
                    scanButton(title: "Scan for PII", prominent: true)
                }
            }
        }
    }

    /// The primary Scan for PII action, rendered with symmetric padding so the
    /// pill is visually even.
    private func scanButton(title: String, prominent: Bool) -> some View {
        Group {
            if prominent {
                Button {
                    Task { await model.anonymize() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.magnifyingglass")
                        Text(title)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
            } else {
                Button {
                    Task { await model.anonymize() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text(title)
                    }
                    .padding(.horizontal, 2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .disabled(!model.canAnonymize)
        .help("Spot PII in the open document: names, companies, addresses, dates, amounts (Cmd+Shift+S)")
        .accessibilityIdentifier("scanForPII")
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

            scanButton(title: "Re-scan", prominent: false)
        }
    }

    /// Shared banner container chrome. Every banner row ends with the labeled
    /// On-device indicator: the trust claim stays visible in this mode without
    /// spending toolbar width, and the label explains the lock icon.
    private func bannerChrome<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            content()

            Divider().frame(height: 14)

            Label("On-device", systemImage: "lock.laptopcomputer")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
                .help("Documents, placeholders, and mappings never leave this Mac. "
                    + "The app has no network access at all.")
                .accessibilityLabel(Text("On-device: nothing leaves this Mac"))

            // When the user-presence upgrade failed, say so here rather than
            // letting the On-device badge imply a Touch ID gate that is not
            // there. See KeychainAdvisoryStore.
            if let advisory = keychainAdvisory.advisory {
                Label("Touch ID inactive", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(CounselTheme.danger)
                    .help(advisory)
                    .accessibilityLabel(Text(advisory))
            }
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

    /// "Spotting PII 42%  ·  about 12s remaining"
    private var detectingLabel: String {
        let pct = Int((model.progress * 100).rounded())
        var label = "Spotting PII \(pct)%"
        if let eta = model.etaText {
            label += "  \u{00B7}  \(eta)"
        }
        return label
    }

    private var bannerText: String? {
        switch model.status {
        case .idle:
            return exportMessage ?? session.sessionNote
        case .importing:
            return "Importing document"
        case .imported:
            return "Document ready. Click Scan for PII to spot names, companies, and other personal data."
        case .detecting:
            return "Spotting PII"
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

    // The de-anonymize flows (paste-back sheet and file-based restore) live in
    // DeanonymizeShell; the sheet presentation is window-level in RootShell.

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

