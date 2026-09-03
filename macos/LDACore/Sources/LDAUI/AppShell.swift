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

    /// True while the passphrase sheet is presented, after a directory is chosen.
    @State private var isPromptingPassphrase = false

    /// The directory chosen for export, held while the passphrase is collected.
    @State private var pendingExportDir: URL?

    /// The optional passphrase typed into the sheet. Empty means use the
    /// Keychain instead of a passphrase.
    @State private var passphrase = ""

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

    /// Whether Touch ID protection actually took effect. Shown next to the
    /// On-device badge when it did not, so the trust claim in the UI matches
    /// what the Keychain is really doing.
    @StateObject private var keychainAdvisory = KeychainAdvisoryStore()

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
                    workflowProgressHeader
                }
                statusBanner
                if let advice = AnonymizeWorkflowPresentation.trackedChangesAdvice(
                    count: model.trackedChangeCount
                ) {
                    trackedChangesAdvisory(advice)
                }
                if let handoffCompletion {
                    handoffCompletionCard(handoffCompletion)
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
        .sheet(isPresented: $isPromptingPassphrase) {
            passphraseSheet
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
        .onChange(of: model.exportRequestToken) { _, _ in
            beginExport()
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
                    Int64(model.redactedCount),
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
                    beginExport()
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

    /// Anonymize is available once a document is imported, and again after a run
    /// (so the user can re-run, for example after toggling AI entities). It is not
    /// available while a pass is in flight.
    private var canAnonymize: Bool { model.canAnonymize }

    // MARK: - Guided workflow

    private var workflowProgressHeader: some View {
        let current = AnonymizeWorkflowPresentation.currentStep(
            status: model.status,
            hasDocument: !model.documentText.isEmpty,
            hasSharedOutput: hasSharedOutput
        )

        return HStack(spacing: 0) {
            ForEach(Array(AnonymizeWorkflowStep.allCases.enumerated()), id: \.element) { index, step in
                workflowStep(step, current: current)

                if index < AnonymizeWorkflowStep.allCases.count - 1 {
                    Rectangle()
                        .fill(step.rawValue < current.rawValue
                            ? CounselTheme.inkAccent.opacity(0.55)
                            : CounselTheme.hairline)
                        .frame(height: 1)
                        .frame(maxWidth: 72)
                        .padding(.horizontal, 8)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(CounselTheme.appSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Anonymize workflow, current step \(L10n.string(current.title))"
        )
    }

    private func workflowStep(
        _ step: AnonymizeWorkflowStep,
        current: AnonymizeWorkflowStep
    ) -> some View {
        let completed = step.rawValue < current.rawValue
        let active = step == current

        return HStack(spacing: 6) {
            Image(systemName: completed ? "checkmark.circle.fill" : step.systemImage)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active || completed
                    ? CounselTheme.inkAccent
                    : CounselTheme.textSecondary)
            Text(step.localizedTitle)
                .font(.caption.weight(active ? .semibold : .regular))
                .foregroundStyle(active
                    ? CounselTheme.textPrimary
                    : CounselTheme.textSecondary)
        }
        .fixedSize()
    }

    @ViewBuilder
    private func handoffCompletionCard(_ completion: HandoffCompletion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(CounselTheme.inkAccent)

            switch completion {
            case .exportedForAI(let result):
                VStack(alignment: .leading, spacing: 3) {
                    Text("Redacted file saved")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(CounselTheme.textPrimary)
                    Text(verbatim: AnonymizeWorkflowPresentation.exportCompletionDetail(
                        documentCount: result.documentCount,
                        skippedCount: result.skippedCount,
                        fileName: result.markdownURL.lastPathComponent
                    ))
                        .font(CounselTheme.Typography.supporting)
                        .foregroundStyle(result.skippedCount > 0
                            ? CounselTheme.danger
                            : CounselTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // The cross-document sweep runs at scan time, so a
                    // document scanned before its partners were added can
                    // still carry their names. Saying which ones is the whole
                    // point: the user cannot see it from the exported file.
                    if let advice = AnonymizeWorkflowPresentation.rescanAdvice(for: result.rescanWarnings) {
                        Text(verbatim: advice)
                            .font(CounselTheme.Typography.supporting)
                            .foregroundStyle(CounselTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // A seam the session pass could not repair. Unlike every
                    // other warning on this card, the user cannot verify it
                    // by reading the exported file: the file is correct and
                    // the damage only appears once the AI's reply is restored.
                    // So the engine's own line is shown verbatim under the
                    // advice, naming the document and the swap.
                    if let seamAdvice = AnonymizeWorkflowPresentation
                        .unresolvedSeamAdvice(issueCount: result.seamIssues.count) {
                        Text(verbatim: seamAdvice)
                            .font(CounselTheme.Typography.supporting.weight(.semibold))
                            .foregroundStyle(CounselTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(result.seamIssues.enumerated()), id: \.offset) { _, issue in
                            Text(verbatim: AnonymizeWorkflowPresentation
                                .unresolvedSeamDescription(for: issue))
                                .font(CounselTheme.Typography.supporting)
                                .foregroundStyle(CounselTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

            case .exported(let result, let protection):
                exportedCompletionDetails(result: result, protection: protection)
            }

            Spacer(minLength: 12)

            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(completion.revealedFiles)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()

            Button("Go to Restore") {
                onOpenRestore()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(CounselTheme.inkAccentFill)
            .fixedSize()

            Button {
                handoffCompletion = nil
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss completion")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
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
                Text(verbatim: detectingLabel)
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
                Text(verbatim: text)
                    .font(.callout)
                    .foregroundStyle(bannerIsError
                        ? CounselTheme.danger
                        : CounselTheme.textSecondary)
                Spacer(minLength: 0)
                // The mode's primary action lives IN the banner, next to the
                // sentence that names it: it can never vanish into toolbar
                // overflow on a narrow window.
                if case .imported = model.status {
                    if session.entries.count > 1 {
                        scanAllButton
                    }
                    scanButton(title: "Scan for PII", prominent: true)
                }
            }
        }
    }

    /// Scan every not-yet-scanned document in tray order (F3). Sequential by
    /// design: one model pass at a time, and the order feeds the
    /// cross-document sweep. The banner's Stop cancels the current document
    /// and leaves the rest of the queue imported.
    private var scanAllButton: some View {
        Button {
            Task { await session.anonymizeAll() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                Text("Scan All")
            }
            .padding(.horizontal, 2)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!session.canScanAll)
        .help("Scan every document in the session that has not been scanned yet, one after another")
        .accessibilityIdentifier("scanAllDocuments")
    }

    /// The primary Scan for PII action, rendered with symmetric padding so the
    /// pill is visually even.
    private func scanButton(title: LocalizedStringKey, prominent: Bool) -> some View {
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
                // Two different states share this slot and MUST look different.
                // A deliberate patterns-only run is a normal, informational
                // choice. An AI pass that was asked for and could not run is a
                // warning: the user expected names and companies to be found
                // and they were not. Rendering both as the same red triangle
                // makes a failed redaction indistinguishable from an intended
                // one. See docs/design/model-tiers-prd.md section 7.
                if model.aiWarning == nil {
                    Label("Patterns only", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(CounselTheme.textSecondary)
                        .help(L10n.string("Emails, phones, dates, amounts, and ID numbers were detected. Names, companies, and addresses were not, because this detection level does not run the AI model."))
                } else {
                    Label("AI did not run", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(CounselTheme.danger)
                        .help(model.aiWarning ?? "")
                }
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

            if model.canChooseSealCandidates {
                sealCandidateToggle
            }

            Spacer(minLength: 0)

            if let exportMessage {
                Text(exportMessage)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .lineLimit(1)
            }

            // The active document is reviewed, but unscanned tray partners
            // can still be swept from here.
            if session.entries.count > 1 {
                scanAllButton
            }
            scanButton(title: "Re-scan", prominent: false)
        }
    }

    /// What one finished export wrote, and what the user still has to check.
    /// Informational lines and warnings are deliberately different colors: a
    /// boxed candidate is the feature working, an unboxed value is something
    /// the exported image may still show.
    @ViewBuilder
    private func exportedCompletionDetails(
        result: ExportResult,
        protection: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Redacted document saved")
                .font(.callout.weight(.semibold))
                .foregroundStyle(CounselTheme.textPrimary)
            completionFileLine(
                String(
                    format: L10n.string("Document: %@"),
                    result.redactedURL.lastPathComponent as NSString
                ),
                help: result.redactedURL.lastPathComponent
            )
            completionFileLine(
                String(
                    format: L10n.string("Encrypted mapping: %@  \u{00B7}  %@"),
                    result.mappingURL.lastPathComponent as NSString,
                    protection as NSString
                ),
                help: "\(result.mappingURL.lastPathComponent), \(protection)"
            )
            if let imageURL = result.redactedImageURL {
                completionFileLine(
                    String(
                        format: L10n.string(
                            "Redacted image: %@  \u{00B7}  boxes are permanent, not restorable"
                        ),
                        imageURL.lastPathComponent as NSString
                    ),
                    help: imageURL.lastPathComponent
                )
            }
            if let candidates = ImageExportPresentation
                .sealCandidateDetail(count: result.sealCandidateCount) {
                completionNote(candidates, color: CounselTheme.textSecondary)
            }
            if let unboxed = ImageExportPresentation
                .unboxedWarning(count: result.unboxedTokenCount) {
                completionNote(unboxed, color: CounselTheme.danger)
            }
            if let warning = AnonymizeWorkflowPresentation.embeddedMediaWarning(
                count: result.embeddedMediaCount
            ) {
                completionNote(warning, color: CounselTheme.danger)
            }
        }
    }

    /// One written-file line: single line, middle-truncated, full name on hover.
    private func completionFileLine(_ text: String, help: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(CounselTheme.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(help)
    }

    /// One wrapping note under the written-file lines.
    private func completionNote(_ text: String, color: Color) -> some View {
        Text(verbatim: text)
            .font(CounselTheme.Typography.supporting)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The per-document seal candidate choice. Shown only for image
    /// documents, through the model's gate rather than a local condition, so
    /// every entry point agrees on when the choice exists.
    private var sealCandidateToggle: some View {
        Toggle(
            LocalizedStringKey(ImageExportPresentation.sealCandidateToggleTitle),
            isOn: sealCandidateBinding
        )
        .toggleStyle(.checkbox)
        .font(.callout)
        .foregroundStyle(CounselTheme.textSecondary)
        .help(L10n.string(ImageExportPresentation.sealCandidateToggleHelp))
    }

    /// Reads and writes the choice on whichever document is active NOW. The
    /// binding deliberately does not capture the ReviewModel: the tray can
    /// change the active document under an open banner, and a captured model
    /// would keep writing to the document the user left.
    private var sealCandidateBinding: Binding<Bool> {
        Binding(
            get: { session.activeModel.includeSealCandidates },
            set: { session.activeModel.includeSealCandidates = $0 }
        )
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
                .help(L10n.string("Detection and redaction run on this Mac. A detection-model download uses a network connection while it runs."))
                .accessibilityLabel(Text("On-device detection and redaction"))

            // When the user-presence upgrade failed, say so here rather than
            // letting the On-device badge imply a Touch ID gate that is not
            // there. See KeychainAdvisoryStore.
            if let advisory = keychainAdvisory.advisory {
                Label("Touch ID inactive", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(CounselTheme.danger)
                    .help(advisory)
                    .accessibilityLabel(Text(verbatim: advisory))
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
        AnonymizeWorkflowPresentation.detectingLabel(
            progress: model.progress,
            eta: model.etaText
        )
    }

    private var bannerText: String? {
        switch model.status {
        case .idle:
            return exportMessage ?? session.sessionNote
        case .importing:
            return L10n.string("Importing document")
        case .imported:
            return L10n.string("Document ready. Click Scan for PII to spot names, companies, and other personal data.")
        case .detecting:
            return L10n.string("Spotting PII")
        case .ready:
            if let exportMessage { return exportMessage }
            if let note = model.learningNote {
                return String(
                    format: L10n.string("Ready for review. %@."),
                    note as NSString
                )
            }
            return L10n.string("Ready for review")
        case .failed(let detail):
            return detail
        }
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

            Text("Enter an optional passphrase to encrypt the mapping sidecar. Leave it blank to protect the mapping with the system Keychain.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Confidentiality nudge: the mapping sidecar holds the original
            // values (encrypted). Exporting into an iCloud-synced folder ships
            // that file off this Mac.
            if let dir = pendingExportDir, Self.isUnderICloud(dir) {
                Label {
                    Text("This folder syncs to iCloud. The encrypted mapping (which contains the original names) will be uploaded with it.")
                } icon: {
                    Image(systemName: "icloud.and.arrow.up")
                }
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
        panel.message = L10n.string("Choose a folder for the redacted document and encrypted mapping.")
        panel.prompt = L10n.string("Export Here")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        pendingExportDir = dir
        isPromptingPassphrase = true
    }

    private func cancelPassphrase() {
        isPromptingPassphrase = false
        pendingExportDir = nil
        passphrase = ""
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

    private func confirmExport() {
        isPromptingPassphrase = false
        guard let dir = pendingExportDir else { return }

        let phrase = passphrase.isEmpty ? nil : passphrase
        let protection = passphrase.isEmpty
            ? L10n.string("Mac Keychain")
            : L10n.string("Passphrase protected")
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
                exportMessage = nil
                handoffCompletion = .exported(
                    result: outcome,
                    protection: protection
                )
                hasSharedOutput = true
            } catch {
                exportMessage = String(
                    format: L10n.string("Export failed: %@"),
                    error.localizedDescription as NSString
                )
            }
        }
    }

    // The Restore flow (choose or drop the file that came back) lives in
    // DeanonymizeShell.

    /// True when the directory lives inside iCloud Drive (any app container or
    /// the Desktop and Documents sync surface).
    private static func isUnderICloud(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/Library/Mobile Documents/")
    }

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

private enum HandoffCompletion: Equatable {
    case exportedForAI(SessionModel.ExportForAIResult)
    case exported(result: ExportResult, protection: String)

    /// The files the Reveal in Finder button selects.
    var revealedFiles: [URL] {
        switch self {
        case .exportedForAI(let result):
            return [result.markdownURL, result.mappingURL]
        case .exported(let result, _):
            return [result.redactedURL, result.mappingURL]
                + (result.redactedImageURL.map { [$0] } ?? [])
        }
    }
}

private struct PendingClientSelection {
    let label: String?
}
