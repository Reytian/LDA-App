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

    /// Switches the window to Restore after an Export for AI or Save Redacted
    /// handoff.
    private let onOpenRestore: () -> Void

    /// Opens the guided Matters workspace for choosing an existing matter.
    private let onOpenMatters: () -> Void

    /// A one-line outcome message shown after an export completes or fails.
    @State private var exportMessage: String?

    /// The most recent successful export or save handoff, shown as a recovery
    /// card with the exact next action instead of a truncated banner sentence.
    @State private var handoffCompletion: HandoffCompletion?

    /// Tracks whether this document reached the Share step independently from
    /// whether the dismissible completion card is still visible.
    @State private var hasSharedOutput = false

    /// Narrow windows hide the workflow row so it cannot slide under the
    /// compact toolbar during live resize.
    @State private var isWindowNarrow = false

    /// Full-screen and AppKit-zoomed windows have room for the product name.
    /// Ordinary windows keep the short title even when their content is wide.
    @State private var usesFullProductTitle = false

    /// First-run flag: the onboarding sheet shows once (R13/R17).
    @AppStorage("com.haotianyi.LDA.hasCompletedFirstRun") private var hasCompletedFirstRun = false

    /// True while the onboarding sheet is presented.
    @State private var isOnboardingPresented = false

    /// A requested client change that must first close the current documents
    /// so one matter's live content cannot be relabeled as another matter.
    @State private var pendingClientSelection: PendingClientSelection?

    /// Which step of the Save Redacted flow is on screen. The directory
    /// picker and the passphrase sheet live in ExportFlow.
    @StateObject private var exportFlow = ExportFlowModel()

    /// Which step of the save-or-open workspace flow is on screen. The flow
    /// itself (panels, sheets, and the replace-live-work prompt) lives in
    /// WorkspaceFlow so this file does not grow another set of sheets.
    @StateObject private var workspaceFlow = WorkspaceFlowModel()

    /// Which step of the export-or-open compliance report flow is on screen.
    /// Same arrangement as the workspace flow, and for the same reason: the
    /// panels and sheets live in ComplianceReportFlow, not in this file.
    @StateObject private var reportFlow = ComplianceReportFlowModel()

    public init(
        session: SessionModel,
        isActive: Bool = true,
        onOpenRestore: @escaping () -> Void = {},
        onOpenMatters: @escaping () -> Void = {}
    ) {
        self.session = session
        self.isActive = isActive
        self.onOpenRestore = onOpenRestore
        self.onOpenMatters = onOpenMatters
    }

    public var body: some View {
        NavigationSplitView {
            EntitySidebar(session: session, model: model)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            VStack(spacing: 0) {
                if WindowLayoutPolicy.showsWorkflowProgress(isWindowNarrow: isWindowNarrow) {
                    AppShellWorkflowHeader(
                        session: session,
                        hasSharedOutput: hasSharedOutput
                    )
                }
                AppShellStatusBanner(session: session, exportMessage: exportMessage)
                if let advice = AnonymizeWorkflowPresentation.trackedChangesAdvice(
                    count: model.trackedChangeCount
                ) {
                    trackedChangesAdvisory(advice)
                }
                if let completion = handoffCompletion {
                    HandoffCompletionCard(
                        completion: completion,
                        onOpenRestore: onOpenRestore,
                        onDismiss: { handoffCompletion = nil }
                    )
                }
                DocumentPane(session: session, model: model)
            }
            .background(CounselTheme.paper)
        }
        .background(CounselTheme.appSurface)
        .background(
            WindowPresentationStateReader(
                isNarrow: $isWindowNarrow,
                usesFullProductTitle: $usesFullProductTitle
            )
                .frame(width: 0, height: 0)
        )
        .navigationTitle(windowTitle)
        .toolbar { toolbarContent }
        .exportFlow(
            session: session,
            flow: exportFlow,
            report: { exportMessage = $0 }
        ) { completion in
            exportMessage = nil
            handoffCompletion = completion
            hasSharedOutput = true
        }
        .workspaceFlow(session: session, flow: workspaceFlow) { message in
            exportMessage = message
        }
        .complianceReportFlow(session: session, flow: reportFlow) { message in
            exportMessage = message
        }
        .sheet(isPresented: $isOnboardingPresented, onDismiss: { hasCompletedFirstRun = true }) {
            OnboardingView(
                isPresented: $isOnboardingPresented,
                modelAvailable: model.modelPath.map {
                    FileManager.default.fileExists(atPath: $0)
                } == true
            )
        }
        .confirmationDialog(
            "Close current work?",
            isPresented: Binding(
                get: { pendingClientSelection != nil },
                set: { if !$0 { pendingClientSelection = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingClientSelection {
                Button("Close Active Work and Switch", role: .destructive) {
                    completeClientSelection(pendingClientSelection.label)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingClientSelection = nil
            }
        } message: {
            Text("Switching matters closes the documents and any unfinished restore context in this window. Saved files are not affected.")
        }
        .onAppear {
            if !hasCompletedFirstRun {
                isOnboardingPresented = true
            }
        }
        .onChange(of: model.anonymizeRequestToken) { _, _ in
            guard model.canAnonymize else { return }
            Task { await model.anonymize() }
        }
        .onChange(of: session.exportForAIRequestToken) { _, _ in
            runExportForAI()
        }
        .onChange(of: session.openRequestToken) { _, _ in
            presentOpenPanel()
        }
        .onChange(of: model.status) { _, status in
            announce(status)
            if case .detecting = status {
                handoffCompletion = nil
                hasSharedOutput = false
            }
        }
        .onChange(of: model.entities.map(\.accepted)) { oldValue, newValue in
            if oldValue != newValue {
                handoffCompletion = nil
                hasSharedOutput = false
            }
        }
        .onChange(of: session.selectedID) { _, _ in
            exportMessage = nil
            handoffCompletion = nil
            hasSharedOutput = false
        }
        .onChange(of: session.clientLabel) { _, _ in
            exportMessage = nil
            handoffCompletion = nil
            hasSharedOutput = false
        }
    }

    /// The window title: the client, the active document, or the product name.
    private var windowTitle: String {
        WindowTitleResolver.resolve(
            client: session.clientLabel,
            document: model.documentName,
            usesFullProductTitle: usesFullProductTitle
        )
    }

    /// Announce run completion to VoiceOver (status banners are otherwise silent).
    private func announce(_ status: ReviewStatus) {
        switch status {
        case .ready:
            AccessibilityNotification.Announcement(
                String(
                    format: L10n.string("Review ready. %lld to redact, %lld will remain visible."),
                    Int64(model.totalRedactedCount),
                    Int64(model.visibleCount)
                )
            ).post()
        case .failed(let detail):
            AccessibilityNotification.Announcement(String(
                format: L10n.string("Could not process the document. %@"),
                detail as NSString
            )).post()
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
                // Two doors, one Restore. Export for AI writes the whole
                // session as ONE Markdown file for chat or upload; Save
                // Redacted writes one document in its original format for
                // editors that keep formatting. Both leave an encrypted
                // .ldamap next to the file, and Restore opens either.
                Button {
                    runExportForAI()
                } label: {
                    Label("Export for AI\u{2026}", systemImage: "doc.richtext")
                }
                .labelStyle(.titleAndIcon)
                .disabled(!session.entries.contains { $0.model.canExport })
                .help(exportForAIHelp)

                Button {
                    exportFlow.requestExport()
                } label: {
                    Label("Save Redacted", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.titleAndIcon)
                .disabled(!model.canExport)
                .help("Save this document redacted in its original format, plus the encrypted mapping. Restore brings it back with formatting preserved.")

                // Next to Save Redacted, because it is the other thing a user
                // saves at the end of a sitting: the redacted output goes out,
                // the workspace stays with the matter.
                Button {
                    workspaceFlow.requestSave()
                } label: {
                    Label("Save Workspace", systemImage: "shippingbox")
                }
                .labelStyle(.titleAndIcon)
                .disabled(!session.canSaveWorkspace)
                .help(L10n.string(WorkspacePresentation.saveHelp))

                Button {
                    beginReportExport()
                } label: {
                    Label("Export Report", systemImage: "list.clipboard")
                }
                .labelStyle(.titleAndIcon)
                .disabled(!session.canExportComplianceReport)
                .help(L10n.string(ComplianceReportPresentation.exportHelp))
            }
        }
    }

    /// The client profile menu (R10): pick a client so this session reuses and
    /// extends that client's identities, or work without one.
    private var clientMenu: some View {
        Menu {
            Button {
                requestClientSelection(nil)
            } label: {
                if session.clientLabel == nil {
                    Label("No Matter", systemImage: "checkmark")
                } else {
                    Text("No Matter")
                }
            }

            Divider()
            Button {
                onOpenMatters()
            } label: {
                Label("Choose Saved Matter\u{2026}", systemImage: "briefcase")
            }

            Button("New Matter\u{2026}") {
                promptNewClient()
            }

            // Matter-scoped learned rules (F4): where this session's accept
            // and reject decisions are remembered. Only meaningful with a
            // matter selected, so the item hides without one.
            if session.clientLabel != nil {
                Divider()
                Toggle(
                    "Apply learned rules to this matter only",
                    isOn: matterScopeBinding
                )
            }
        } label: {
            Label(
                session.clientLabel ?? L10n.string("No Matter"),
                systemImage: "person.crop.square"
            )
        }
        .help("Work under a matter keeps the same placeholders for the same values, every time")
    }

    /// Routes the matter-scope toggle through the session, which persists the
    /// choice per matter and creates the matter's scope identity on first use.
    private var matterScopeBinding: Binding<Bool> {
        Binding(
            get: { session.scopeLearnedRulesToMatter },
            set: { enabled in
                do {
                    try session.setScopeLearnedRulesToMatter(enabled)
                } catch {
                    exportMessage = String(
                        format: L10n.string("Could not change the matter scope. %@"),
                        error.localizedDescription as NSString
                    )
                }
            }
        )
    }

    /// Ask for a new client label with a small input alert and select it.
    private func promptNewClient() {
        let alert = NSAlert()
        alert.messageText = L10n.string("New matter")
        alert.informativeText = L10n.string(
            "Documents processed under this matter keep consistent placeholders across sessions. The mapping stays encrypted on this Mac."
        )
        alert.addButton(withTitle: L10n.string("Create"))
        alert.addButton(withTitle: L10n.string("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = L10n.string("Client or matter name")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let label = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return }
        requestClientSelection(label)
    }

    private func requestClientSelection(_ label: String?) {
        do {
            if try session.selectMatter(label) == false {
                pendingClientSelection = PendingClientSelection(label: label)
            }
        } catch {
            exportMessage = error.localizedDescription
        }
    }

    private func completeClientSelection(_ label: String?) {
        do {
            _ = try session.selectMatter(label, discardingDocuments: true)
        } catch {
            exportMessage = error.localizedDescription
        }
        pendingClientSelection = nil
    }

    // MARK: - Export for AI (stage 3)

    /// Ask where the redacted Markdown should go, THEN build the handoff and
    /// write it with its encrypted sidecar. ExportForAIFlow owns the ordering
    /// (panel first, so a cancelled export parks nothing and records nothing);
    /// this shell only shows the outcome.
    private func runExportForAI() {
        switch ExportForAIFlow.run(session: session) {
        case .cancelled:
            return
        case .nothingReady:
            exportMessage = L10n.string("Scan a document for PII first, then export it for the AI.")
        case .exported(let result):
            exportMessage = nil
            handoffCompletion = .exportedForAI(result)
            hasSharedOutput = AnonymizeWorkflowPresentation.hasSharedActiveDocument(
                activeDocumentID: session.selectedID,
                includedDocumentIDs: result.includedDocumentIDs
            )
        case .failed(let message):
            exportMessage = message
        }
    }

    // MARK: - Tracked changes advisory

    /// A Word document with tracked changes round-trips exactly only after
    /// the user accepts them, so the advice sits under the banner for as long
    /// as the document is open, whatever its scan state.
    private func trackedChangesAdvisory(_ advice: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(CounselTheme.danger)
            Text(verbatim: advice)
                .font(CounselTheme.Typography.supporting)
                .foregroundStyle(CounselTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: advice))
    }

    /// The Export for AI tooltip, enriched with how many of the session's
    /// documents are ready so a multi-document user is not silently handed a
    /// partial session (F5, partially: a tooltip is hover-only, so this cannot
    /// be the whole answer. See the audit doc.)
    private var exportForAIHelp: String {
        let ready = session.entries.filter { $0.model.canExport }.count
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

    // MARK: - Open flow

    /// Present a native open panel for the session's documents. NSOpenPanel is
    /// used instead of SwiftUI .fileImporter because two .fileImporter modifiers
    /// on the same view conflict and silently fail to present. Folders are
    /// selectable too (F3): each one contributes its supported documents
    /// recursively, budget-checked before anything enters the tray. A .zip
    /// INSIDE a folder is not one of them; only an archive the user picks
    /// directly expands. See FolderImporter.supportedExtensions.
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.openContentTypes
        panel.message = L10n.string("Choose .txt, .docx, .pdf documents, .png or .jpg evidence images, a .zip, or a folder of documents. Several files become one session.")
        panel.prompt = L10n.string("Open")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        exportMessage = nil
        handoffCompletion = nil
        hasSharedOutput = false
        let selectedURLs = panel.urls
        let scoped = selectedURLs.map {
            (url: $0, needsScope: $0.startAccessingSecurityScopedResource())
        }
        let releaseScopes = {
            for item in scoped where item.needsScope {
                item.url.stopAccessingSecurityScopedResource()
            }
        }
        Task {
            // defer releases the sandbox scopes even if the Task is cancelled
            // mid-import. SessionModel performs folder discovery while these
            // scopes remain live, so panel opens and drops share one boundary.
            defer { releaseScopes() }
            await session.addDocuments(selectedURLs)
            // A refused archive shows where a refused folder shows. Without
            // this the document would simply not appear and the user would be
            // left guessing which of their files the app dropped.
            if let failure = session.importFailure {
                exportMessage = failure
            }
        }
    }

    /// Export the session's compliance report. The report carries NO protected
    /// value, but it does carry the matter label and every document name, and
    /// in PRC legal practice those names are the parties, which is why the
    /// record it renders is encrypted at rest. So the export is passphrase
    /// protected by default, like the workspace file, and the readable pair is
    /// an explicit choice on the sheet. The panels and the sheet live in
    /// ComplianceReportFlow.
    private func beginReportExport() {
        reportFlow.requestExport()
    }

    // The Restore flow (choose or drop the file that came back) lives in
    // DeanonymizeShell.

    // MARK: - Content types

    /// The document types the Open panel accepts: plain text, Word, PDF, zip,
    /// and evidence images (PNG and JPEG).
    private static let openContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .pdf, .zip, .png, .jpeg]
        if let docx = UTType(
            "org.openxmlformats.wordprocessingml.document"
        ) {
            types.append(docx)
        }
        return types
    }()
}

enum WindowTitleResolver {
    static func resolve(
        client: String?,
        document: String?,
        usesFullProductTitle: Bool
    ) -> String {
        if let client {
            return document.map { "\(client) \u{00B7} \($0)" } ?? client
        }
        return document ?? (usesFullProductTitle ? "Legal Document Anonymizer" : "LDA")
    }
}

enum WindowLayoutPolicy {
    static let narrowWidthThreshold: CGFloat = 1_200

    static func isNarrow(windowWidth: CGFloat) -> Bool {
        windowWidth < narrowWidthThreshold
    }

    static func showsWorkflowProgress(isWindowNarrow: Bool) -> Bool {
        !isWindowNarrow
    }

    static func usesFullProductTitle(isFullScreen: Bool, isZoomed: Bool) -> Bool {
        isFullScreen || isZoomed
    }
}

private struct WindowPresentationStateReader: NSViewRepresentable {
    @Binding var isNarrow: Bool
    @Binding var usesFullProductTitle: Bool

    func makeNSView(context: Context) -> WindowPresentationStateView {
        let view = WindowPresentationStateView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: WindowPresentationStateView, context: Context) {
        configure(nsView)
        nsView.scheduleRefresh()
    }

    private func configure(_ view: WindowPresentationStateView) {
        view.onPresentationChange = { narrow, fullProductTitle in
            if isNarrow != narrow {
                isNarrow = narrow
            }
            if usesFullProductTitle != fullProductTitle {
                usesFullProductTitle = fullProductTitle
            }
        }
    }
}

private final class WindowPresentationStateView: NSView {
    var onPresentationChange: ((Bool, Bool) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var refreshIsScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeCurrentWindow()
        scheduleRefresh()
    }

    func scheduleRefresh() {
        guard !refreshIsScheduled else { return }
        refreshIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshIsScheduled = false
            guard let window = self.window else { return }
            let isNarrow = WindowLayoutPolicy.isNarrow(windowWidth: window.frame.width)
            let usesFullProductTitle = WindowLayoutPolicy.usesFullProductTitle(
                isFullScreen: window.styleMask.contains(.fullScreen),
                isZoomed: window.isZoomed
            )
            self.onPresentationChange?(isNarrow, usesFullProductTitle)
        }
    }

    private func observeCurrentWindow() {
        removeObservers()
        guard let window else { return }

        let notifications = [
            NSWindow.didResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification
        ]
        observers = notifications.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleRefresh()
            }
        }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    deinit {
        removeObservers()
    }
}

private struct PendingClientSelection {
    let label: String?
}
