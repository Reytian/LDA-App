//
//  AppShell.swift
//  LDAUI
//
//  The top-level review window: a NavigationSplitView with the entity sidebar on
//  the leading side and the paper document pane as the detail. This file keeps
//  the shell itself: the split layout, the window title, the state the pieces
//  share, and the open panel that fills the session.
//
//  The pieces live next door, each in its own file, so this one stays readable:
//  AppShellToolbar (the unified toolbar), AppShellStatusBanner (the status
//  strip and the mode's primary action), AppShellWorkflowHeader (the guided
//  workflow row), HandoffCompletionCard (what one finished export wrote),
//  ExportFlow (Save Redacted and its passphrase sheet), ClientMatterFlow (the
//  matter menu and the close-live-work confirmation), WorkspaceFlow and
//  ComplianceReportFlow.
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

    /// The tier manifest, loaded once per view instance rather than on every
    /// body pass.
    ///
    /// This matters more than it looks: `ModelCatalog.load()` probes up to five
    /// bundles, reads Models.json from disk and JSON-decodes it, and the
    /// missing-model check below runs on every body evaluation. `importer` is
    /// observed and publishes while a multi-gigabyte copy is in flight, so
    /// leaving both calls on their reloading default parameter put a disk read
    /// and a JSON parse on the main thread for every progress update. Same
    /// pattern as ModelManagementView.
    private let catalog = ModelCatalog.load()

    /// Whether THIS MAC has any detection model, read through the cached
    /// catalog. Decides the banner sentence, the scan tooltip and onboarding.
    private var hasDetectionModel: Bool {
        AISettings.hasAnyModelAvailable(catalog: catalog)
    }

    /// Whether any tier could run here at all. False on 8 GB and 12 GB, where
    /// the advisory carries no button and there is no scan gate, because a
    /// dialog with no available remedy is a ritual.
    private var canRunAModel: Bool {
        AISettings.canRunAnyModel(catalog: catalog)
    }

    /// The tier the model dialogs offer: Quick, the one rung that runs on the
    /// 16 GB minimum spec. Its published size is what the Download button
    /// shows, so the number has one source of truth in Models.json.
    private var quickTier: ModelTier? { catalog.tier(for: .quick) }

    /// True while ANY open document is scanning. Gates model removal in the
    /// Manage Models sheet reached from here: llama.cpp still has the file
    /// mmapped, so the disk would not actually come back.
    ///
    /// Note that this deliberately does NOT gate the IMPORT. Adding a file
    /// writes a new path and mutates nothing that is mmapped, and the imported
    /// tier cannot become the active model mid-scan because ReviewModel
    /// captures modelPath when the scan starts.
    private var isScanning: Bool {
        session.entries.contains { $0.model.status == .detecting }
    }

    /// The model downloader and the verified offline importer, both owned by
    /// LDAApp. Required parameters with no default: see RootShell.
    @ObservedObject private var installer: ModelInstaller
    @ObservedObject private var importer: ModelImporter

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
    /// Shared: the banner reads it, and every flow in this window reports
    /// into it.
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

    /// True while Manage Models is presented from here. Reached from the
    /// first-run setup step and from the pre-scan advisory, so both routes land
    /// in the one sheet that already carries every download gate.
    @State private var isModelSheetPresented = false

    /// Manage Models was asked for from INSIDE onboarding, so it opens from
    /// that sheet's onDismiss rather than in the same tick. This window has a
    /// documented case of two presentation modifiers silently never
    /// presenting, and a sheet swapped inside a sheet is that shape.
    @State private var pendingModelSheet = false

    /// Which onboarding this launch presents: the two-page first run, or the
    /// return visit for an unresolved model ask.
    @State private var onboardingMode: OnboardingView.Mode = .firstRun

    /// The parked scan or export request waiting on a model confirmation. The
    /// two dialogs live in ModelSetupFlow.
    @StateObject private var modelSetupFlow = ModelSetupFlowModel()

    /// Which step of the Save Redacted flow is on screen. The directory
    /// picker and the passphrase sheet live in ExportFlow.
    @StateObject private var exportFlow = ExportFlowModel()

    /// Which step of the save-or-open workspace flow is on screen. The flow
    /// itself (panels, sheets, and the replace-live-work prompt) lives in
    /// WorkspaceFlow so this file does not grow another set of sheets.
    @StateObject private var workspaceFlow = WorkspaceFlowModel()

    /// A requested matter change that must first close the current documents
    /// so one matter's live content cannot be relabeled as another matter.
    /// The menu and the confirmation live in ClientMatterFlow.
    @StateObject private var clientFlow = ClientMatterFlowModel()

    /// Which step of the export-or-open compliance report flow is on screen.
    /// Same arrangement as the workspace flow, and for the same reason: the
    /// panels and sheets live in ComplianceReportFlow, not in this file.
    @StateObject private var reportFlow = ComplianceReportFlowModel()

    public init(
        session: SessionModel,
        installer: ModelInstaller,
        importer: ModelImporter,
        isActive: Bool = true,
        onOpenRestore: @escaping () -> Void = {},
        onOpenMatters: @escaping () -> Void = {}
    ) {
        self.session = session
        self.installer = installer
        self.importer = importer
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
                AppShellStatusBanner(
                    session: session,
                    exportMessage: exportMessage,
                    hasDetectionModel: hasDetectionModel
                )
                // Above the tracked-changes row on purpose: a scan that is not
                // looking for names changes what the review list can possibly
                // contain, which outranks advice about how a value round trips.
                //
                // The catalog is the view's own cached copy, not a fresh load:
                // a load here would put a disk read and a JSON parse on the
                // main thread for every progress publish during a multi
                // gigabyte copy. The row still disappears the moment a model
                // arrives, because `importer` and `installer` are observed.
                if let advice = AnonymizeWorkflowPresentation.missingModelAdvice(
                    isModelMissing: AISettings.isModelMissing(catalog: catalog),
                    hasAnyModel: hasDetectionModel,
                    rungUsesLLM: AISettings.detectionLevel(catalog: catalog).usesLLM,
                    canRunAModel: canRunAModel
                ) {
                    // No trailing button on a Mac that cannot run a model: the
                    // sentence states the limit and there is nothing to press.
                    missingModelAdvisory(advice, offersSetUp: canRunAModel)
                }
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
        .toolbar {
            AppShellToolbar(
                session: session,
                isActive: isActive,
                exportFlow: exportFlow,
                workspaceFlow: workspaceFlow,
                reportFlow: reportFlow,
                clientFlow: clientFlow,
                onOpenMatters: onOpenMatters,
                onOpen: { presentOpenPanel() },
                onExportForAI: { requestExportForAI() },
                report: { exportMessage = $0 }
            )
        }
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
        .sheet(isPresented: $isOnboardingPresented, onDismiss: onboardingDismissed) {
            // hasAnyModelAvailable, not the selected rung: the old check was
            // model.modelPath, which is nil for a deliberate patterns-only user
            // too, so onboarding told them they had to add a model.
            OnboardingView(
                isPresented: $isOnboardingPresented,
                hasModel: hasDetectionModel,
                installer: installer,
                catalog: catalog,
                canRunAModel: canRunAModel,
                mode: onboardingMode,
                onOpenModelManagement: {
                    pendingModelSheet = true
                    isOnboardingPresented = false
                }
            )
        }
        .sheet(isPresented: $isModelSheetPresented) {
            ModelManagementView(
                installer: installer,
                importer: importer,
                isBusyElsewhere: isScanning
            )
        }
        .clientMatterFlow(session: session, flow: clientFlow) { message in
            exportMessage = message
        }
        .modelSetupFlow(
            flow: modelSetupFlow,
            canDownload: quickTier.map { AISettings.canDownload($0) } ?? false,
            canRunAModel: canRunAModel,
            sizeDescription: quickTier?.downloadSizeDescription ?? "",
            onScan: { request in
                acknowledgeScanTargets(request)
                runScan(request)
            },
            onExport: { runExportForAI() },
            onOpenModelManagement: { isModelSheetPresented = true }
        )
        .onAppear {
            if !hasCompletedFirstRun {
                onboardingMode = .firstRun
                isOnboardingPresented = true
            } else if AISettings.shouldPresentModelAsk(catalog: catalog) {
                // An unresolved ask: accepted, and still no file. Only the ask
                // returns, never the three steps.
                onboardingMode = .modelAskOnly
                isOnboardingPresented = true
            }
        }
        .onChange(of: model.anonymizeRequestToken) { _, _ in
            handleScanRequest(.active)
        }
        .onChange(of: session.scanAllRequestToken) { _, _ in
            handleScanRequest(.all)
        }
        .onChange(of: session.exportForAIRequestToken) { _, _ in
            requestExportForAI()
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

    // MARK: - Scan (stage 2)

    /// Every scan entry point lands here: the banner's Scan for PII, Re-scan,
    /// Scan All, and Cmd+Shift+S through the File menu. One gate covers all
    /// four, which is the only arrangement that cannot be bypassed by an entry
    /// point nobody rerouted.
    ///
    /// The gate fires once per tray document per session (and once for a Scan
    /// All), not on every press: a dialog whose text never changes trains Scan
    /// then Return as one gesture, and that reflex then fires through the
    /// genuinely different unresolved-seam advisory, which renders in the same
    /// region.
    private func handleScanRequest(_ request: ScanRequest) {
        guard let pending = resolveScan(request) else { return }
        guard AISettings.scanNeedsModelConfirmation(catalog: catalog) else {
            return runScan(pending)
        }
        guard !pending.targets.allSatisfy(modelSetupFlow.confirmedIDs.contains) else {
            return runScan(pending)
        }
        modelSetupFlow.pendingScan = pending
    }

    /// Fix which documents a request means, once, at the moment the user asked.
    ///
    /// The only place the live selection is read. Deriving the target again on
    /// the way out of the dialog made the acknowledgment and the dispatch
    /// depend on which document was active when the user answered, which the
    /// window-modal dialog probably made unreachable and which a request
    /// carrying its own target cannot depend on at all.
    ///
    /// nil means there is nothing to scan. The dispatch guards below reject
    /// the same states (an idle empty model cannot anonymize, and canScanAll
    /// is false with no imported document), so this is where they are caught
    /// before a dialog can ask about no documents.
    private func resolveScan(_ request: ScanRequest) -> PendingScan? {
        switch request {
        case .active:
            guard let id = session.activeEntryID else { return nil }
            return .active(id)
        case .all:
            let ids = session.entries
                .filter { $0.model.status == .imported }
                .map(\.id)
            return ids.isEmpty ? nil : .all(ids)
        }
    }

    /// Remember that the user chose to scan these documents without a model.
    private func acknowledgeScanTargets(_ request: PendingScan) {
        modelSetupFlow.confirmedIDs.formUnion(request.targets)
    }

    /// The one place a scan is dispatched, and the D1 fix.
    ///
    /// ReviewModel captures modelPath at model creation, and a completed
    /// install changes neither customModelPath nor detectionLevelRaw, so the
    /// two reapply triggers in LDAApp do not fire: a document opened before the
    /// download landed would keep scanning with no model while the advisory
    /// above had already cleared. Re-resolving HERE is correct after any
    /// change, including one made outside the app, and cannot be defeated by a
    /// publish nobody observes. Observing installer.phases instead would be
    /// wrong twice over: it republishes on every progress tick, and it says
    /// nothing about a file that arrived by another route.
    private func runScan(_ request: PendingScan) {
        session.reapplyConfiguration()
        switch request {
        case .active(let id):
            // The document the request named, not whichever one is selected
            // now. The local is called model so it reads like the shell's own
            // active-document property at the dispatch line below.
            guard let model = session.entries.first(where: { $0.id == id })?.model,
                  model.canAnonymize else { return }
            Task { await model.anonymize() }
        case .all:
            guard session.canScanAll else { return }
            Task { await session.anonymizeAll() }
        }
    }

    /// Export for AI, gated on whether any exportable document was scanned
    /// without the AI pass it asked for.
    ///
    /// The second confirmation sits here rather than on Scan alone because
    /// this is the step that actually discloses: a gate on Scan intercepts the
    /// earlier decision and can create false comfort at the later one.
    private func requestExportForAI() {
        guard let reason = ModelSetupPresentation.exportGateReason(
            documents: session.entries.map {
                (
                    $0.model.canExport,
                    $0.model.aiActive,
                    $0.model.aiWarning,
                    $0.model.aiRanPartially
                )
            }
        ) else { return runExportForAI() }
        modelSetupFlow.pendingExport = reason
    }

    // MARK: - Onboarding

    /// Closing onboarding, however it closed.
    ///
    /// The unanswered fallback is belt and braces: page 1 cannot be Escaped
    /// today, but if a future edit drops .interactiveDismissDisabled an escape
    /// is recorded as a decline rather than forgotten. hasCompletedFirstRun
    /// keeps its own meaning, which is only that the sheet was shown.
    ///
    /// It fires only when this Mac has no model, because that is the only
    /// state in which the ask was on screen at all. Recording a decline for
    /// someone who opened straight onto the three steps would be inferring an
    /// answer to a question they were never asked, and it would then silence
    /// the ask for them if they ever removed that model. A model that arrived
    /// DURING onboarding cannot reach this branch: both routes that install
    /// one record `.accepted` on the button first.
    private func onboardingDismissed() {
        hasCompletedFirstRun = true
        if !hasDetectionModel, AISettings.modelSetupAnswer() == nil {
            AISettings.recordModelSetupAnswer(canRunAModel ? .declined : .unavailable)
        }
        if pendingModelSheet {
            pendingModelSheet = false
            isModelSheetPresented = true
        }
    }

    // MARK: - Tracked changes advisory

    /// A Word document with tracked changes round-trips exactly only after
    /// the user accepts them, so the advice sits under the banner for as long
    /// as the document is open, whatever its scan state.
    private func trackedChangesAdvisory(_ advice: String) -> some View {
        AdvisoryRow(advice: advice)
    }

    /// No model for the selected rung: the scan will not look for names,
    /// companies or addresses, said BEFORE the Scan button is pressed.
    ///
    /// Deliberately not dismissible while the condition holds, and deliberately
    /// not a modal. A dismissible advisory would let a lawyer hide the fact
    /// that the scan does not look for names and then act on a review list that
    /// looks complete because every deterministic type is still in it. A modal
    /// would nag a legitimate patterns-only workflow. A persistent row directly
    /// above the Scan button is read before the click without blocking anyone.
    @ViewBuilder
    private func missingModelAdvisory(_ advice: String, offersSetUp: Bool) -> some View {
        if offersSetUp {
            AdvisoryRow(advice: advice) {
                // Recorded here too, because this is the route a decliner
                // takes back: without it a stored "declined" would survive the
                // user visibly acting to fix it, and the next launch would
                // stay quiet about an ask they had actually taken up.
                L10n.button("Set Up a Model\u{2026}") {
                    AISettings.recordModelSetupAnswer(.accepted)
                    isModelSheetPresented = true
                }
                .controlSize(.small)
            }
        } else {
            // 8 GB and 12 GB: the sentence states the limit, and there is no
            // button because there is nothing this user can press that would
            // change it. Apple silicon memory is soldered.
            AdvisoryRow(advice: advice)
        }
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
