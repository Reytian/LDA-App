//
//  SessionModel.swift
//  LDAUI
//
//  The multi-document session above ReviewModel (R12/R19): a tray of
//  documents, each with its own ReviewModel for import/detect/review, plus the
//  session-level round-trip actions: build the shared redacted Markdown for
//  the AI handoff (one mapping across every document, optionally seeded from
//  and saved back to a client profile, R10), and restore pasted AI output
//  against that session mapping.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Combine
import SwiftUI
import LDACore

// MARK: - SessionModel

public enum MatterManagementError: LocalizedError, Sendable {
    case emptyLabel
    case incompleteWorkspace
    case labelInUse(String)
    case reservedAlias(String, currentLabel: String)
    case archivedMatter(String)
    case renameRecoveryRequired
    case archiveRecoveryRequired

    public var errorDescription: String? {
        switch self {
        case .emptyLabel:
            return "Enter a client or matter name."
        case .incompleteWorkspace:
            return "Some matter data could not be unlocked. Try again before changing matter names."
        case .labelInUse(let label):
            return "A different matter already uses \"\(label)\"."
        case .reservedAlias(let alias, let currentLabel):
            return "\"\(alias)\" is a previous name for \"\(currentLabel)\". Open the current matter instead."
        case .archivedMatter(let label):
            return "\"\(label)\" is archived. Restore it from Matters before opening it."
        case .renameRecoveryRequired:
            return "The matter name could not be changed safely. Your data remains encrypted, but the rename needs attention before you continue."
        case .archiveRecoveryRequired:
            return "The matter could not be archived safely. Your data remains encrypted, but the archive state needs attention before you continue."
        }
    }
}

/// Owns the session's documents and the shared session mapping. @MainActor so
/// every published change is main-actor isolated.
@MainActor
public final class SessionModel: ObservableObject {

    /// One tray entry: a stable id, the source URL, and the per-document
    /// review model.
    public struct DocumentEntry: Identifiable {
        public let id: UUID
        public let url: URL
        public let model: ReviewModel

        public var name: String { url.lastPathComponent }
    }

    /// The session's documents, in tray order.
    @Published public private(set) var entries: [DocumentEntry] = []

    /// The selected tray document. The shell binds the sidebar and pane to its
    /// model.
    @Published public var selectedID: UUID? {
        didSet { rebindActiveModel() }
    }

    /// The active client profile label, or nil for a one-off session (R10).
    @Published public private(set) var clientLabel: String?

    /// The shared session mapping after the most recent hand-to-AI build.
    /// Restore-from-paste runs against this.
    @Published public private(set) var sessionMapping: Mapping?

    /// Bumped when the Copy for AI menu command fires.
    @Published public var copyForAIRequestToken = 0

    /// Bumped when the Restore from AI menu command fires.
    @Published public var pasteRestoreRequestToken = 0

    /// Bumped when the File > Open menu command fires.
    @Published public var openRequestToken = 0

    /// A .ldawork file the app has been asked to open, from a double-click in
    /// Finder or the File menu. The shell consumes it (clearing it) and runs
    /// the passphrase flow; the session never opens a workspace on its own,
    /// because doing so would replace live work without asking.
    @Published public var pendingWorkspaceURL: URL?

    /// A .ldareport file the app has been asked to open, from the File menu or
    /// a double-click in Finder. The shell consumes it (clearing it) and runs
    /// the passphrase flow. Opening one writes readable copies of a report, so
    /// it never happens without the user choosing a destination first.
    @Published public var pendingReportURL: URL?

    /// The menu-bar companion's last-action note ("Restored 4 values.").
    @Published public var companionNote: String?

    /// A quiet session-level note for the window banner (for example the
    /// resumed-parked-session hint).
    @Published public var sessionNote: String?

    /// Why the most recent addDocuments refused the batch, or nil when it did
    /// not. Cleared at the start of every import.
    ///
    /// A refusal used to be swallowed by a `try?`, so an archive that breached
    /// the unpacking ceiling simply vanished from the tray and the user was
    /// left to notice a missing document. The shell reads this and shows it
    /// where it shows the folder-budget refusal, so both halves of one import
    /// fail the same visible way.
    @Published public private(set) var importFailure: String?

    /// The current session's record id (R18), set by the hand-to-AI build so
    /// later restores append their events to the same record.
    @Published public private(set) var currentRecordID: UUID?

    /// Builds a configured ReviewModel for each added document (wired to the
    /// model path, custom vocabulary, and learning store by the app).
    private let makeModel: () -> ReviewModel

    /// Opens one imported document. Injectable so import cancellation can be
    /// tested at the suspension boundary.
    public var openDocument: (ReviewModel, URL) async -> Void = { model, url in
        await model.open(url)
    }

    /// Shown while the tray is empty so the shell always has a model to bind.
    public let emptyModel: ReviewModel

    /// The client mapping store. Injectable for tests.
    private let clientStore: () throws -> ClientMappingStore

    /// Distinguishes a cold launch from an explicit No Client selection. A
    /// cold launch may resume the most recent parked round trip; an explicit
    /// selection must remain a privacy boundary.
    private var hasExplicitClientSelection = false

    /// Changes whenever a document discard invalidates an in-flight import.
    private var documentImportGeneration = 0

    /// How a client's stored mapping is protected. Injectable for tests; the
    /// production default is the client's derived Keychain account.
    public var clientProtection: (String) -> MappingProtection = {
        ClientMappingStore.defaultProtection(label: $0)
    }

    /// The session record store (R18). Injectable for tests.
    public var recordStore: () throws -> SessionRecordStore = { try SessionRecordStore() }

    /// How session records are protected. Injectable for tests; the
    /// production default is the shared records Keychain key.
    public var recordProtection: () -> MappingProtection = {
        SessionRecordStore.defaultProtection()
    }

    /// The app version stamped into session records for the compliance
    /// report. Injectable so record tests stay deterministic; the production
    /// default reads the bundle's short version string.
    public var appVersionProvider: () -> String? = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Encrypted matter names, aliases, and archive state for the workspace.
    /// Access is user-initiated from Matters so Keychain prompts do not appear
    /// during an ordinary app launch.
    public var matterStore: () throws -> MatterMetadataStore = { try MatterMetadataStore() }

    /// Protection for workspace metadata. Injectable for hermetic tests.
    public var matterProtection: () -> MappingProtection = {
        MatterMetadataStore.defaultProtection()
    }

    /// Where the awaiting-AI parked mapping lives, so a session survives the
    /// user quitting while the AI works. Injectable for tests; the production
    /// default lives under ApplicationSupport/LDA.
    public var parkedMappingURL: () throws -> URL = {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("LDA", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("parked.ldamap")
    }

    /// How the parked mapping is protected. Injectable for tests.
    public var parkedProtection: () -> MappingProtection = {
        .keychain(account: "lda-parked-session")
    }

    /// Writes encrypted parked state. Injectable so failure paths remain
    /// deterministic in tests.
    public var saveParkedSession: (
        ParkedSessionState,
        URL,
        MappingProtection
    ) throws -> Void = { state, url, protection in
        try ParkedSessionStore.save(state, to: url, protection: protection)
    }

    /// Legacy UserDefaults key used only to migrate parked sessions created by
    /// older app versions. New parked matter labels stay encrypted.
    public static let parkedClientLabelKey = "com.haotianyi.LDA.parkedClientLabel"

    /// Applied to every newly created document model (custom vocabulary,
    /// learning store). Set by the app after init; applied retroactively to
    /// the empty model and any existing entries when set.
    public var configureNewModel: ((ReviewModel) -> Void)? {
        didSet {
            guard let configure = configureNewModel else { return }
            configure(emptyModel)
            applyScopedStores(to: emptyModel)
            for entry in entries {
                configure(entry.model)
                applyScopedStores(to: entry.model)
            }
        }
    }

    /// Supplies the output style for Copy for AI and the clipboard companion.
    /// The default reads the persisted setting live, so a change in Settings
    /// applies to the next handoff; tests inject a fixed closure.
    public var outputStyleProvider: () -> SubstitutionStyle = { AISettings.outputStyle() }

    /// Forwards the ACTIVE model's change notifications through the session,
    /// so a shell observing only the session still refreshes its toolbar and
    /// banners when the active document's review state changes.
    private var activeModelForwarder: AnyCancellable?

    public init(
        makeModel: @escaping () -> ReviewModel,
        clientStore: @escaping () throws -> ClientMappingStore = { try ClientMappingStore() }
    ) {
        self.makeModel = makeModel
        self.clientStore = clientStore
        self.emptyModel = makeModel()
        rebindActiveModel()
    }

    /// Re-subscribe the change forwarder to the current active model.
    private func rebindActiveModel() {
        activeModelForwarder = activeModel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Re-apply configureNewModel to every model (the empty one and every
    /// document's). Called when an app-level setting changes (model path,
    /// detection mode) so open documents pick it up on their next run.
    public func reapplyConfiguration() {
        guard let configure = configureNewModel else { return }
        configure(emptyModel)
        applyScopedStores(to: emptyModel)
        for entry in entries {
            configure(entry.model)
            applyScopedStores(to: entry.model)
        }
    }

    // MARK: - Active model

    /// The review model the shell should render: the selected document's, the
    /// first document's, or the idle empty model.
    public var activeModel: ReviewModel {
        activeEntry?.model ?? emptyModel
    }

    /// The selected entry, or the first one.
    public var activeEntry: DocumentEntry? {
        if let selectedID, let entry = entries.first(where: { $0.id == selectedID }) {
            return entry
        }
        return entries.first
    }

    /// Whether switching or archiving would close documents or an in-progress
    /// round trip that still holds a live mapping or activity record.
    public var hasActiveMatterWork: Bool {
        !entries.isEmpty || sessionMapping != nil || currentRecordID != nil
    }

    // MARK: - Tray management (R19)

    /// Add documents to the session. A .zip expands into its supported
    /// documents. Each document gets its own configured ReviewModel and is
    /// imported immediately; the last added document becomes selected.
    ///
    /// - Parameter budget: the unpacking allowance for this whole import. One
    ///   ledger covers every archive in the batch, so selecting many small
    ///   high-ratio archives cannot multiply the ceiling. A caller that is
    ///   already expanding something for the same user gesture (opening a
    ///   workspace) passes ITS ledger in.
    public func addDocuments(_ urls: [URL], budget: ArchiveBudget = ArchiveBudget()) async {
        let importGeneration = documentImportGeneration
        importFailure = nil
        // A .zip expands into a temp directory whose files stay readable for
        // as long as the tray holds them (re-scan and export both re-read the
        // source), so the expansion is cleaned when the tray empties and at
        // termination, not here. See discardExpandedArchives().
        guard let resolved = expandArchives(in: urls, budget: budget) else { return }

        for url in resolved {
            guard importGeneration == documentImportGeneration else { return }
            let model = makeModel()
            configureNewModel?(model)
            applyScopedStores(to: model)
            let entry = DocumentEntry(id: UUID(), url: url, model: model)
            // Cross-document recall sweep (the GUI half of the session-wide
            // sweep in LDAService.anonymizeSession): when this document
            // detects, the partners' confirmed person and company surfaces
            // join its rescan needles, and every hit enters ITS review list
            // as an ordinary entity. Only the id is captured; capturing the
            // entry would retain the model through its own closure.
            let entryID = entry.id
            model.sessionKnownEntitiesProvider = { [weak self] in
                self?.partnerConfirmedEntities(excludingEntryID: entryID) ?? []
            }
            entries.append(entry)
            selectedID = entry.id
            await openDocument(model, url)
            guard importGeneration == documentImportGeneration else { return }
        }
    }

    /// Expand every archive in the selection against one shared ledger, or
    /// report the refusal and return nil.
    ///
    /// Whole-batch semantics, matching FolderImporter.expandSelection: nothing
    /// reaches the tray unless the entire selection resolved, and the archives
    /// that DID expand before the refusal are deleted rather than left as
    /// un-redacted originals in the system temp directory. Only this import's
    /// expansions are swept: the snapshot taken first protects an expansion an
    /// earlier import (or the workspace being opened) still holds.
    private func expandArchives(in urls: [URL], budget: ArchiveBudget) -> [URL]? {
        let inheritedExpansions = ZipImporter.registeredExpansions()
        var resolved: [URL] = []
        for url in urls {
            guard ZipImporter.isZip(url) else {
                resolved.append(url)
                continue
            }
            do {
                resolved.append(contentsOf: try ZipImporter.expand(url, budget: budget).documents)
            } catch {
                ZipImporter.cleanUpExpansions(
                    ZipImporter.registeredExpansions().subtracting(inheritedExpansions)
                )
                importFailure = error.localizedDescription
                return nil
            }
        }
        return resolved
    }

    /// Remove a document from the tray.
    ///
    /// Emptying the tray also discards any .zip expansion: at that point no
    /// document references the temp directory, so the user's original files
    /// should not remain unpacked on disk.
    public func removeDocument(id: UUID) {
        entries.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = entries.first?.id
        }
        if entries.isEmpty {
            discardExpandedArchives()
        }
    }

    /// Delete the temporary directories holding documents unpacked from a .zip.
    ///
    /// Safe to call whenever the tray no longer references them: at that point
    /// they are un-redacted client documents sitting in the system temp
    /// directory with nothing left to read them. Also called at app
    /// termination, since a session that ends with the window closing should
    /// leave nothing behind either.
    public func discardExpandedArchives() {
        ZipImporter.cleanUpAllExpansions()
    }

    /// Whether the Scan All action can start: at least one document is
    /// waiting in the imported state, and no pass is currently running
    /// anywhere in the tray (only one model pass may be in flight).
    public var canScanAll: Bool {
        entries.contains { $0.model.status == .imported }
            && !entries.contains { $0.model.status == .detecting }
    }

    /// Detect entities in every document that has not run yet, sequentially so
    /// only one model pass is in flight at a time. The sequential order also
    /// feeds the cross-document sweep: each document's pass sees the partners
    /// confirmed so far, so a party found in an earlier document surfaces in
    /// every later one. Re-running Scan on a document picks up partners
    /// confirmed after its first pass.
    ///
    /// Selection follows the document being scanned so the pane shows the
    /// live pass and the banner's Stop button always reaches it. Stopping
    /// cancels the current document (restored to imported, nothing partial
    /// shown) and ends the queue, leaving the remainder imported.
    public func anonymizeAll() async {
        for entry in entries {
            switch entry.model.status {
            case .imported:
                selectedID = entry.id
                await entry.model.anonymize()
                // A user stop restores this document to .imported instead of
                // .ready; that is the signal to stop the whole queue.
                if entry.model.status == .imported { return }
            default:
                continue
            }
        }
    }

    /// The confirmed (accepted) PERSON and COMPANY spans of every session
    /// document except the given entry, used as that document's extra
    /// literal-rescan needles. Mirrors the session-wide sweep in
    /// LDAService.anonymizeSession with one GUI difference: hits become
    /// ordinary review entities instead of being redacted outright, so the
    /// human-review invariant holds. Only the surfaces cross documents; the
    /// offsets stay meaningless outside their own document and EntityRescan
    /// never uses them for blocking.
    private func partnerConfirmedEntities(excludingEntryID id: UUID) -> [Span] {
        entries
            .filter { $0.id != id }
            .flatMap { entry in
                entry.model.entities
                    .filter { $0.accepted && ($0.span.type == .person || $0.span.type == .company) }
                    .map { $0.span }
            }
    }

    // MARK: - Hand to AI (stage 3)

    /// The outcome of building the session's redacted Markdown.
    public struct HandToAIResult {
        /// The combined Markdown for the clipboard (per-document headers when
        /// the session has several documents).
        public let combined: String
        /// The per-document Markdown intermediates, keyed by entry id.
        public let perDocument: [UUID: String]
        /// How many documents were included.
        public let documentCount: Int
        /// How many documents were SKIPPED because they have not been
        /// anonymized yet. Surfaced so the user is never silently handed a
        /// partial session.
        public let skippedCount: Int
        /// Included documents that still carry a party another included
        /// document confirmed, so the user is never silently handed a session
        /// the cross-document sweep did not reach. Empty in the ordinary case.
        public let rescanWarnings: [RescanWarning]
        /// Sites in the copied text that would restore to a DIFFERENT entity
        /// than the one protected there, one readable line each
        /// (SessionTokenizeResult.unresolvedSeams). Empty in the ordinary
        /// case.
        ///
        /// The sibling channel to rescanWarnings, and the more serious of the
        /// two. A rescan warning says a name was left visible, which the user
        /// can see in the copied text. This says a name was replaced and will
        /// come BACK as somebody else, which the user cannot see anywhere:
        /// the copy looks correct, and the swap only appears once the AI's
        /// reply is restored into a real document. So it is carried out to
        /// the banner rather than left for the engine to know alone.
        public let unresolvedSeams: [String]
    }

    /// Build the session's redacted Markdown intermediates against ONE shared
    /// mapping, seeded from (and saved back to) the active client profile.
    ///
    /// Documents whose review is ready are included; documents still
    /// unprocessed are counted as skipped. Returns nil when nothing is ready.
    public func buildHandToAI(createdAtISO8601: String) throws -> HandToAIResult? {
        let ready = entries.filter { $0.model.canExport }
        guard !ready.isEmpty else { return nil }

        // Seed from the client profile so identities persist across sessions.
        var seed: Mapping?
        if let clientLabel {
            seed = try clientStore().load(
                label: clientLabel,
                protection: clientProtection(clientLabel)
            )
        }

        let documents = ready.map { entry in
            SessionDocument(
                name: entry.name,
                text: entry.model.documentText,
                spans: entry.model.entities.filter { $0.accepted }.map { $0.span }
            )
        }
        let label = clientLabel ?? (ready.first.map { $0.name } ?? "session")
        let style = outputStyleProvider()
        let result = try SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: label,
            createdAtISO8601: createdAtISO8601,
            seedMapping: seed,
            style: style,
            overrides: activePseudonymOverrides(for: style)
        )
        // Record the full-name/short-name grouping in the shared mapping,
        // mirroring LDAService.anonymizeSession. Tokens and values are
        // untouched (byte-identical restore); only grouping metadata is added.
        var linkedMapping = result.mapping
        for document in documents {
            linkedMapping = EntityRescan.linkAliases(
                in: linkedMapping,
                pairs: EntityRescan.aliasPairs(in: document.text, confirmed: document.spans)
            )
        }
        sessionMapping = linkedMapping

        // Save the union back under the client so the next session keeps
        // these identities (R10).
        if let clientLabel {
            try clientStore().save(
                linkedMapping,
                label: clientLabel,
                protection: clientProtection(clientLabel)
            )
        }

        // Show the assigned tokens on the accepted entities (sealed chips).
        let tokenBySurface = ReviewModel.tokenBySurface(mapping: linkedMapping)
        for entry in ready {
            for index in entry.model.entities.indices {
                entry.model.entities[index].token = entry.model.entities[index].accepted
                    ? tokenBySurface[entry.model.entities[index].span.text]
                    : nil
            }
        }

        // Cross-document recall check, read-only. The tray sweep runs at
        // DETECT time and only ever looks backwards, so a document scanned
        // before a partner confirmed a party never saw that party and nothing
        // in the UI said so. Here every ready document's accepted spans are in
        // hand at once, which makes the comparison order-independent like the
        // headless sweep in LDAService.anonymizeSession. Reported, never
        // acted on: adding the span or redacting it here would push a decision
        // into the handoff that no human reviewed.
        let rescanWarnings = crossDocumentRescanWarnings(ready: ready, documents: documents)

        var perDocument: [UUID: String] = [:]
        for (entry, document) in zip(ready, result.documents) {
            perDocument[entry.id] = document.tokenizedText
        }

        let combined: String
        if result.documents.count == 1 {
            combined = result.documents[0].tokenizedText
        } else {
            combined = result.documents
                .enumerated()
                .map { index, document in
                    "# Document \(index + 1)\n\n\(document.tokenizedText)"
                }
                .joined(separator: "\n\n---\n\n")
        }

        // Per-session record (R18): what was protected, value-free. Best
        // effort: a record failure must not block the handoff itself.
        saveSessionRecord(
            createdAtISO8601: createdAtISO8601,
            ready: ready,
            mapping: linkedMapping,
            rescanWarnings: rescanWarnings
        )

        // Park the session (awaiting-AI state): the mapping survives the user
        // quitting while the AI works, so the round-trip has no dead end.
        let parkedURL = try parkedMappingURL()
        let parked = ParkedSessionState(
            mapping: result.mapping,
            clientLabel: clientLabel
        )
        try saveParkedSession(parked, parkedURL, parkedProtection())
        UserDefaults.standard.removeObject(forKey: Self.parkedClientLabelKey)

        return HandToAIResult(
            combined: combined,
            perDocument: perDocument,
            documentCount: ready.count,
            skippedCount: entries.count - ready.count,
            rescanWarnings: rescanWarnings,
            unresolvedSeams: result.unresolvedSeams
        )
    }

    /// The distinct accepted entity-type wire strings of one document model.
    private func distinctTypes(of model: ReviewModel) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entity in model.entities where entity.accepted {
            let raw = entity.span.type.rawValue
            if seen.insert(raw).inserted {
                ordered.append(raw)
            }
        }
        return ordered
    }

    /// Accepted entity counts of one document model, keyed by entity-type wire
    /// string, for the compliance report's per-document breakdown.
    private func entityCountsByType(of model: ReviewModel) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entity in model.entities where entity.accepted {
            counts[entity.span.type.rawValue, default: 0] += 1
        }
        return counts
    }

    /// Build and best-effort persist the session record (R18) for one handoff,
    /// including the compliance report fields (F6): style, model, app version,
    /// per-type counts, and the scan-side verification summary.
    private func saveSessionRecord(
        createdAtISO8601: String,
        ready: [DocumentEntry],
        mapping: Mapping,
        rescanWarnings: [RescanWarning]
    ) {
        let record = SessionRecord(
            createdAtISO8601: createdAtISO8601,
            clientLabel: clientLabel,
            documents: ready.map { entry in
                SessionRecordDocument(
                    name: entry.name,
                    entityCount: entry.model.redactedCount,
                    entityTypes: distinctTypes(of: entry.model),
                    entityCountsByType: entityCountsByType(of: entry.model)
                )
            },
            protectedValueCount: mapping.entries.count,
            substitutionStyle: mapping.style,
            modelName: ready.first?.model.modelPath.map {
                URL(fileURLWithPath: $0).lastPathComponent
            },
            appVersion: appVersionProvider(),
            // Scan-side verification counts. The literal rescan hits are
            // folded into ordinary review entities at detect time and are not
            // separable here without re-running the sweep, so the hit count
            // records 0 until detection surfaces it. Forensics suspects are a
            // restore-side signal (SessionRestoreEvent.suspectCount), so the
            // scan-side count is 0 by construction.
            scanVerification: SessionScanVerification(
                rescanHitCount: 0,
                rescanWarningCount: rescanWarnings.count,
                forensicsSuspectCount: 0
            )
        )
        if let store = try? recordStore() {
            try? store.save(record, protection: recordProtection())
            currentRecordID = record.id
        }
    }

    // NOTE: the compliance report export (F6) lives in
    // SessionModel+ComplianceReport.swift, next to the encrypted report
    // format it writes.

    // MARK: - Matter-scoped learned rules (F4)

    /// The app-owned global store layers, attached once at launch. They stay
    /// shared with the Settings window. nil in sessions that never attach
    /// stores (most tests wire models directly), which keeps those paths
    /// byte-identical to the pre-scoping behavior.
    private var globalLearningStore: LearningStore?
    private var globalPatternStore: CustomPatternStore?

    /// The active matter's stable metadata id (MatterMetadata.id). nil when
    /// no matter is selected, or the matter has no metadata entry yet: one is
    /// created the first time the user scopes rules to the matter.
    @Published public private(set) var matterScopeID: UUID?

    /// Whether learned-rule writes from this session land in the matter layer
    /// instead of the global one. Persisted per matter under a key that
    /// embeds only the matter's random id, never its label.
    @Published public private(set) var scopeLearnedRulesToMatter = false

    /// Where the per-matter toggle persists. Injectable for hermetic tests.
    public var scopeDefaults: () -> UserDefaults = { .standard }

    /// Matter-layer store factories. Injectable so tests can pin a defaults
    /// suite and test-only base keys instead of the production vault accounts.
    public var makeMatterLearningStore: (UUID) -> LearningStore = {
        LearningStore(scope: .matter(id: $0))
    }
    public var makeMatterPatternStore: (UUID) -> CustomPatternStore = {
        CustomPatternStore(scope: .matter(id: $0))
    }

    /// The scoped facades the document models read. Rebuilt whenever the
    /// matter scope changes; nil until the app attaches the global layers.
    public private(set) var scopedLearningStore: ScopedLearningStore?
    public private(set) var scopedPatternStore: ScopedCustomPatternStore?

    /// The layer learned-rule writes land in right now. Matter writes require
    /// both the toggle and an attached matter layer; everything else is the
    /// pre-scoping global behavior.
    public var learnedRuleWriteTarget: ScopeTarget {
        scopeLearnedRulesToMatter && scopedLearningStore?.matter != nil
            ? .matter
            : .global
    }

    /// The per-matter UserDefaults key for the scope toggle. Derived like
    /// StoreScope.storageKey: the key embeds only the matter's random id, so
    /// a matter label can never leak into UserDefaults.
    public static func matterScopeToggleKey(for id: UUID) -> String {
        StoreScope.matter(id: id)
            .storageKey(base: "com.haotianyi.LDA.scopeLearnedRulesToMatter")
    }

    /// Attach the app's global vocabulary and learning layers and start
    /// injecting the scoped facades into every document model.
    public func attachStores(
        learning: LearningStore,
        patterns: CustomPatternStore
    ) {
        globalLearningStore = learning
        globalPatternStore = patterns
        rebuildScopedStores()
    }

    /// Turn matter scoping on or off for the active matter, creating the
    /// matter's metadata entry (its stable id) on first use and persisting
    /// the choice per matter. A session without a matter has nothing to
    /// scope to, so the call is a no-op there.
    public func setScopeLearnedRulesToMatter(_ enabled: Bool) throws {
        guard let clientLabel else { return }
        if enabled, matterScopeID == nil {
            matterScopeID = try matterStore().ensure(
                label: clientLabel,
                protection: matterProtection()
            ).id
        }
        scopeLearnedRulesToMatter = enabled && matterScopeID != nil
        if let id = matterScopeID {
            scopeDefaults().set(
                scopeLearnedRulesToMatter,
                forKey: Self.matterScopeToggleKey(for: id)
            )
        }
        rebuildScopedStores()
    }

    /// Adopt a matter scope identity that arrived inside a workspace archive.
    ///
    /// Needed because the matter itself may be unknown on this Mac: a
    /// colleague opening a handed-over workspace has no metadata entry for it,
    /// so there is no local id to adopt. Minting the matter layer from the
    /// ARCHIVED id lets the matter's own learned rules and vocabulary keep
    /// working standalone, which is the difference between a workspace that
    /// travels and one that only looks like it does.
    ///
    /// Scoping is turned on with it: an archive only carries matter-layer
    /// lists when the sending session was scoped, so the receiving session
    /// must be too, or those rules would be read but never written back to.
    func adoptWorkspaceMatterScope(id: UUID) {
        matterScopeID = id
        scopeLearnedRulesToMatter = true
        scopeDefaults().set(true, forKey: Self.matterScopeToggleKey(for: id))
        rebuildScopedStores()
    }

    /// Install a session mapping restored from a workspace, so restore from
    /// paste works the moment the workspace opens.
    func adoptWorkspaceMapping(_ mapping: Mapping?) {
        sessionMapping = mapping
    }

    /// Clear the session so a workspace can take its place.
    ///
    /// Deliberately unconditional, unlike selectClient's early return when the
    /// label is unchanged: opening a workspace for the matter already selected
    /// must still replace the tray, not merge into it. Expanded archives go
    /// too, because the outgoing session's unpacked originals have nothing left
    /// to read them.
    ///
    /// Call this only after the incoming workspace has been decrypted,
    /// validated AND unpacked. It destroys live work.
    ///
    /// Takes the expansions to discard rather than clearing the whole
    /// registry: by the time this runs the incoming workspace has already
    /// registered its own unpacked directory, and clearing everything would
    /// delete the very documents about to be adopted.
    func resetForWorkspaceOpen(discardingExpansions expansions: Set<URL>) {
        documentImportGeneration += 1
        entries.removeAll()
        selectedID = nil
        sessionMapping = nil
        currentRecordID = nil
        sessionNote = nil
        companionNote = nil
        pseudonymOverrides = [:]
        clientLabel = nil
        hasExplicitClientSelection = true
        adoptMatterScope(id: nil)
        ZipImporter.cleanUpExpansions(expansions)
    }

    /// Adopt the scope identity of a newly selected matter (nil for no
    /// matter) and restore its persisted toggle state.
    private func adoptMatterScope(id: UUID?) {
        matterScopeID = id
        scopeLearnedRulesToMatter = id.map {
            scopeDefaults().bool(forKey: Self.matterScopeToggleKey(for: $0))
        } ?? false
        rebuildScopedStores()
    }

    /// Rebuild the scoped facades for the current scope and inject them into
    /// every model. No-op until the app attaches the global layers.
    private func rebuildScopedStores() {
        guard let globalLearning = globalLearningStore,
              let globalPatterns = globalPatternStore else { return }
        let matterLearning = matterScopeID.map { makeMatterLearningStore($0) }
        let matterPatterns = matterScopeID.map { makeMatterPatternStore($0) }
        scopedLearningStore = ScopedLearningStore(
            global: globalLearning,
            matter: matterLearning
        )
        scopedPatternStore = ScopedCustomPatternStore(
            global: globalPatterns,
            matter: matterPatterns
        )
        applyScopedStores(to: emptyModel)
        for entry in entries {
            applyScopedStores(to: entry.model)
        }
    }

    /// Wire one model to the current facades. No-op until stores attach, so
    /// tests that configure model stores directly keep full control.
    private func applyScopedStores(to model: ReviewModel) {
        guard scopedLearningStore != nil else { return }
        model.learningStore = scopedLearningStore
        model.customPatternProvider = { [weak self] in
            self?.scopedPatternStore?.activePatterns ?? []
        }
        model.learningWriteTarget = { [weak self] in
            self?.learnedRuleWriteTarget ?? .global
        }
    }

    // MARK: - Editable pseudonym replacements (F5)

    /// User-forced replacement text keyed by the exact surface, applied to
    /// every later hand-to-AI build of this session (pseudonym style only).
    @Published public private(set) var pseudonymOverrides: [String: String] = [:]

    /// Set, replace, or clear (nil or empty replacement) the forced
    /// replacement for one surface. The WHOLE updated set is validated
    /// against the session corpus and the mapping entries already in force,
    /// so a rejected edit changes nothing.
    public func setPseudonymOverride(surface: String, replacement: String?) throws {
        let trimmed = replacement?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var updated = pseudonymOverrides
        updated[surface] = trimmed.isEmpty ? nil : trimmed
        if !updated.isEmpty {
            try PseudonymOverrideValidator.validate(
                overrides: updated,
                style: outputStyleProvider(),
                corpus: entries.map { $0.model.documentText },
                existingEntries: sessionMapping?.entries ?? [:]
            )
        }
        pseudonymOverrides = updated
    }

    /// The overrides the build applies: the stored set under the pseudonym
    /// style, empty otherwise. Overrides are a pseudonym-only feature, and a
    /// style change in Settings must never break the next build.
    func activePseudonymOverrides(for style: SubstitutionStyle) -> [String: String] {
        style == .pseudonym ? pseudonymOverrides : [:]
    }

    /// Resume an awaiting-AI parked session after a relaunch: reload the
    /// parked mapping (and its client label) so Restore from AI works without
    /// redoing anything. No-op when nothing is parked.
    public func resumeParkedSession() {
        guard sessionMapping == nil,
              let url = try? parkedMappingURL(),
              FileManager.default.fileExists(atPath: url.path),
              let loaded = loadParkedSession(from: url),
              let parked = canonicalizedParkedSession(loaded, at: url) else {
            return
        }
        if hasExplicitClientSelection, clientLabel != parked.clientLabel {
            return
        }
        if let selectedClient = clientLabel, selectedClient != parked.clientLabel {
            return
        }
        sessionMapping = parked.mapping
        if clientLabel == nil {
            clientLabel = parked.clientLabel
            // A resume bypasses selectMatter, so adopt the resumed matter's
            // scope here too. canonicalizedParkedSession already resolved the
            // metadata, so this read stays within the same user action.
            if let label = parked.clientLabel {
                adoptMatterScope(
                    id: (try? matterMetadata())?.metadata
                        .first { $0.label == label }?.id
                )
            }
        }
        sessionNote = "Resumed your last session. When the AI answer is ready, "
            + "use Restore to bring the real values back."
    }

    /// Load the current encrypted parked format, or migrate the legacy mapping
    /// plus UserDefaults label in place after a successful unlock.
    private func loadParkedSession(from url: URL) -> ParkedSessionState? {
        let protection = parkedProtection()
        if let parked = try? ParkedSessionStore.load(from: url, protection: protection) {
            return parked
        }
        guard let mapping = try? MappingStore.load(from: url, protection: protection) else {
            return nil
        }
        let parked = ParkedSessionState(
            mapping: mapping,
            clientLabel: UserDefaults.standard.string(forKey: Self.parkedClientLabelKey)
        )
        if (try? ParkedSessionStore.save(parked, to: url, protection: protection)) != nil {
            UserDefaults.standard.removeObject(forKey: Self.parkedClientLabelKey)
        }
        return parked
    }

    /// Resolve a parked label through encrypted rename aliases and refuse to
    /// reactivate archived matters. Canonical rewrites are best effort because
    /// the in-memory session can still use the validated current label safely.
    private func canonicalizedParkedSession(
        _ parked: ParkedSessionState,
        at url: URL,
        allowArchived: Bool = false
    ) -> ParkedSessionState? {
        guard let label = parked.clientLabel else { return parked }
        guard let resolution = try? matterMetadata(), resolution.unreadableCount == 0 else {
            return nil
        }
        guard let owner = resolution.metadata.first(where: {
            $0.label == label || $0.aliases.contains(label)
        }) else {
            return parked
        }
        guard allowArchived || !owner.isArchived else { return nil }
        guard owner.label != label else { return parked }

        var canonical = parked
        canonical.clientLabel = owner.label
        if canonical.mapping.sourceFile == label {
            canonical.mapping.sourceFile = owner.label
        }
        try? saveParkedSession(canonical, url, parkedProtection())
        return canonical
    }

    /// Whether an encrypted parked round trip belongs to the named matter.
    /// Unreadable state fails closed because its encrypted label is unknown.
    public func hasParkedMatterWork(_ candidate: String) throws -> Bool {
        let label = try validatedMatterLabel(candidate)
        return try workspaceParkedSession()?.state.clientLabel == label
    }

    /// Load parked work for a user-initiated workspace action. The encrypted
    /// owner, not the current in-memory selection, controls any discard.
    private func workspaceParkedSession() throws -> (
        url: URL,
        state: ParkedSessionState
    )? {
        let url = try parkedMappingURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let loaded = loadParkedSession(from: url),
              let parked = canonicalizedParkedSession(
                loaded,
                at: url,
                allowArchived: true
              ) else {
            throw MatterManagementError.incompleteWorkspace
        }
        return (url, parked)
    }

    private func discardParkedSession(
        _ context: (url: URL, state: ParkedSessionState)
    ) throws {
        do {
            try FileManager.default.removeItem(at: context.url)
        } catch {
            throw DocumentIOError.unreadable(
                "Failed to close the parked session: \(error.localizedDescription)"
            )
        }
    }

    /// Delete only parked work that can be proven to belong to the outgoing
    /// matter. A confirmed discard never guesses across encrypted boundaries.
    private func discardParkedSession(matching label: String?) throws {
        guard let context = try workspaceParkedSession(),
              context.state.clientLabel == label else { return }
        try discardParkedSession(context)
    }

    // MARK: - Bring back and restore (stage 4)

    /// Restore pasted AI output against the session mapping (or, when the app
    /// was reopened mid round-trip, the client profile's stored mapping).
    /// Returns nil when there is no mapping to restore against.
    public func restorePasted(_ text: String) throws -> RestoreResult? {
        // Just-in-time parked-session resume (no-op when a mapping is already
        // loaded or nothing is parked). Keeps Keychain access user-initiated.
        resumeParkedSession()
        var mapping = sessionMapping
        if mapping == nil, let clientLabel {
            mapping = try clientStore().load(
                label: clientLabel,
                protection: clientProtection(clientLabel)
            )
        }
        guard let mapping else { return nil }
        let result = Restorer.restore(text: text, mapping: mapping)

        // Append the restore to the session record (R18). Best effort.
        if let recordID = currentRecordID, let store = try? recordStore() {
            let event = SessionRestoreEvent(
                atISO8601: ISO8601DateFormatter().string(from: Date()),
                restoredCount: result.restoredCount,
                orphanCount: result.orphanTokens.count,
                suspectCount: result.suspectPlaceholders.count
            )
            try? store.appendRestoreEvent(
                to: recordID,
                event: event,
                protection: recordProtection()
            )
        }
        return result
    }

    // MARK: - Menu-bar companion (clipboard round-trip)

    /// Redact a clipboard snippet: deterministic detection (plus the user's
    /// custom vocabulary), tokenized against the SESSION mapping so the same
    /// values keep the same placeholders, and the mapping is extended (and
    /// saved under the client, when one is active) so the snippet restores
    /// later. The fast path for the menu-bar "redact this" action; it never
    /// loads the LLM.
    public func redactClipboardText(
        _ text: String,
        createdAtISO8601: String
    ) throws -> (text: String, tokenCount: Int) {
        // Seed from the in-memory session mapping, or the client's stored one.
        var seed = sessionMapping
        if seed == nil, let clientLabel {
            seed = try clientStore().load(
                label: clientLabel,
                protection: clientProtection(clientLabel)
            )
        }

        let deterministic = DeterministicEngine().detect(text)
            + CustomPatternEngine.detect(text, patterns: emptyModel.customPatternProvider())
        let spans = SpanMerger.merge(deterministic: deterministic, llm: [])

        let result = Tokenizer.tokenize(
            text: text,
            spans: spans,
            sourceFile: clientLabel ?? "clipboard",
            createdAtISO8601: createdAtISO8601,
            seedMapping: seed,
            style: outputStyleProvider()
        )
        sessionMapping = result.mapping

        if let clientLabel {
            try clientStore().save(
                result.mapping,
                label: clientLabel,
                protection: clientProtection(clientLabel)
            )
        }

        return (result.tokenizedText, spans.count)
    }

    // MARK: - Client profiles

    /// Select a client without carrying another client's live mapping or
    /// assigned preview tokens into the new matter. Accepted redaction choices
    /// remain intact, but the next handoff rebuilds them against the selected
    /// client's encrypted mapping.
    @discardableResult
    func selectClient(
        _ label: String?,
        discardingDocuments: Bool = false
    ) -> Bool {
        hasExplicitClientSelection = true
        guard clientLabel != label else { return true }
        guard !hasActiveMatterWork || discardingDocuments else { return false }

        let openModels = entries.map(\.model)
        if discardingDocuments {
            documentImportGeneration += 1
            entries.removeAll()
            selectedID = nil
        }

        clientLabel = label
        sessionMapping = nil
        currentRecordID = nil
        sessionNote = nil
        // Overrides reference this session's surfaces; they must not follow
        // the user across a matter boundary.
        pseudonymOverrides = [:]
        // The matter boundary moved: drop the outgoing matter's scope. When a
        // matter is being selected, selectMatter adopts its real scope id and
        // persisted toggle right after this call.
        adoptMatterScope(id: nil)

        for index in emptyModel.entities.indices {
            emptyModel.entities[index].token = nil
        }
        for model in openModels {
            for index in model.entities.indices {
                model.entities[index].token = nil
            }
        }
        return true
    }

    /// Validate a user-facing matter selection against encrypted aliases and
    /// archive state before applying the low-level client boundary change.
    @discardableResult
    public func selectMatter(
        _ candidate: String?,
        discardingDocuments: Bool = false
    ) throws -> Bool {
        guard let candidate else {
            if let parked = try workspaceParkedSession(),
               parked.state.clientLabel != nil {
                guard discardingDocuments else { return false }
                try discardParkedSession(parked)
            }
            return selectClient(nil, discardingDocuments: discardingDocuments)
        }
        let label = try validatedMatterLabel(candidate)
        let clientResolution = try resolvedClientLabels()
        let recordResolution = try recordStore().resolve(protection: recordProtection())
        let metadataResolution = try matterMetadata()
        guard clientResolution.unreadableCount == 0,
              recordResolution.unreadableCount == 0,
              metadataResolution.unreadableCount == 0 else {
            throw MatterManagementError.incompleteWorkspace
        }

        if let owner = metadataResolution.metadata.first(where: {
            $0.aliases.contains(label) && $0.label != label
        }) {
            throw MatterManagementError.reservedAlias(label, currentLabel: owner.label)
        }
        if metadataResolution.metadata.first(where: { $0.label == label })?.isArchived == true {
            throw MatterManagementError.archivedMatter(label)
        }
        if let parked = try workspaceParkedSession(),
           parked.state.clientLabel != label {
            guard discardingDocuments else { return false }
            try discardParkedSession(parked)
        }
        let selected = selectClient(label, discardingDocuments: discardingDocuments)
        if selected {
            // Adopt the matter's scope identity (its stable metadata id) and
            // its persisted matter-scope toggle. A matter without metadata
            // has no id yet; it gains one on the first scope-toggle use.
            adoptMatterScope(
                id: metadataResolution.metadata.first { $0.label == label }?.id
            )
        }
        return selected
    }

    /// Exact decrypted client labels for the explicit Matters workspace.
    /// This is never called at launch because it may require user presence.
    public func resolvedClientLabels() throws -> ClientLabelResolution {
        try clientStore().listResolvedLabels { identifier in
            clientProtection(identifier)
        }
    }

    /// Exact encrypted rename aliases and archive state for Matters.
    public func matterMetadata() throws -> MatterMetadataResolution {
        try matterStore().list(protection: matterProtection())
    }

    /// Rename one matter without rewriting historical records. The encrypted
    /// client mapping moves to the new exact label, while encrypted metadata
    /// retains the old label as an alias so prior activity stays grouped.
    public func renameMatter(from oldLabel: String, to newLabel: String) throws {
        let oldLabel = try validatedMatterLabel(oldLabel)
        let newLabel = try validatedMatterLabel(newLabel)
        guard oldLabel != newLabel else { return }

        let clientResolution = try resolvedClientLabels()
        let recordResolution = try recordStore().resolve(protection: recordProtection())
        let metadataResolution = try matterMetadata()
        guard clientResolution.unreadableCount == 0,
              recordResolution.unreadableCount == 0,
              metadataResolution.unreadableCount == 0 else {
            throw MatterManagementError.incompleteWorkspace
        }

        let sourceMetadata = metadataResolution.metadata.first {
            $0.label == oldLabel || $0.aliases.contains(oldLabel)
        }
        var ownedLabels = Set([oldLabel])
        if let sourceMetadata {
            ownedLabels.insert(sourceMetadata.label)
            ownedLabels.formUnion(sourceMetadata.aliases)
        }

        var occupiedLabels = Set(clientResolution.labels)
        occupiedLabels.formUnion(
            recordResolution.records.compactMap { record in
                record.clientLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
        for item in metadataResolution.metadata {
            occupiedLabels.insert(item.label)
            occupiedLabels.formUnion(item.aliases)
        }
        if occupiedLabels.contains(newLabel), !ownedLabels.contains(newLabel) {
            throw MatterManagementError.labelInUse(newLabel)
        }

        let parkedURL = try parkedMappingURL()
        var parkedRewrite: (url: URL, original: ParkedSessionState)?
        if FileManager.default.fileExists(atPath: parkedURL.path) {
            guard let loaded = loadParkedSession(from: parkedURL),
                  let parked = canonicalizedParkedSession(
                    loaded,
                    at: parkedURL,
                    allowArchived: true
                  ) else {
                throw MatterManagementError.incompleteWorkspace
            }
            if parked.clientLabel == oldLabel {
                var renamedParked = parked
                renamedParked.clientLabel = newLabel
                if renamedParked.mapping.sourceFile == oldLabel {
                    renamedParked.mapping.sourceFile = newLabel
                }
                try saveParkedSession(
                    renamedParked,
                    parkedURL,
                    parkedProtection()
                )
                parkedRewrite = (parkedURL, parked)
            }
        }

        let rollbackParkedRewrite: () -> Bool = {
            guard let parkedRewrite else { return true }
            do {
                try self.saveParkedSession(
                    parkedRewrite.original,
                    parkedRewrite.url,
                    self.parkedProtection()
                )
                return true
            } catch {
                return false
            }
        }

        let store = try clientStore()
        let mappingRenamed: Bool
        do {
            mappingRenamed = try store.rename(
                from: oldLabel,
                to: newLabel,
                oldProtection: clientProtection(oldLabel),
                newProtection: clientProtection(newLabel)
            )
        } catch let mappingError {
            guard rollbackParkedRewrite() else {
                throw MatterManagementError.renameRecoveryRequired
            }
            throw mappingError
        }
        do {
            try matterStore().rename(
                from: oldLabel,
                to: newLabel,
                protection: matterProtection()
            )
        } catch let metadataError {
            var rollbackSucceeded = true
            if mappingRenamed {
                do {
                    let restored = try store.rename(
                        from: newLabel,
                        to: oldLabel,
                        oldProtection: clientProtection(newLabel),
                        newProtection: clientProtection(oldLabel)
                    )
                    guard restored else {
                        rollbackSucceeded = false
                        throw MatterManagementError.renameRecoveryRequired
                    }
                } catch {
                    rollbackSucceeded = false
                }
            }
            if !rollbackParkedRewrite() {
                rollbackSucceeded = false
            }
            guard rollbackSucceeded else {
                throw MatterManagementError.renameRecoveryRequired
            }
            throw metadataError
        }

        if clientLabel == oldLabel {
            clientLabel = newLabel
            sessionMapping?.sourceFile = newLabel
        }
    }

    /// Archive or restore a matter. Archiving the active matter requires an
    /// explicit document-discard confirmation and clears the active client so
    /// later work does not silently continue inside an archived workspace.
    @discardableResult
    public func setMatterArchived(
        _ label: String,
        isArchived: Bool,
        discardingDocuments: Bool = false
    ) throws -> Bool {
        let label = try validatedMatterLabel(label)
        let hasParkedWork = isArchived ? try hasParkedMatterWork(label) : false
        let closesLiveWork = clientLabel == label && hasActiveMatterWork
        if isArchived,
           (closesLiveWork || hasParkedWork),
           !discardingDocuments {
            return false
        }

        try matterStore().setArchived(
            label: label,
            isArchived: isArchived,
            protection: matterProtection()
        )
        do {
            if isArchived, hasParkedWork {
                try discardParkedSession(matching: label)
            }
            if isArchived, clientLabel == label {
                return selectClient(nil, discardingDocuments: discardingDocuments)
            }
        } catch let archiveError {
            do {
                try matterStore().setArchived(
                    label: label,
                    isArchived: false,
                    protection: matterProtection()
                )
            } catch {
                throw MatterManagementError.archiveRecoveryRequired
            }
            throw archiveError
        }
        return true
    }

    private func validatedMatterLabel(_ candidate: String) throws -> String {
        guard let cleaned = MatterWorkspacePresentation.cleanedLabel(candidate) else {
            throw MatterManagementError.emptyLabel
        }
        return cleaned
    }

    /// Ask the shell to run the Copy for AI flow (menu command hook).
    public func requestCopyForAI() { copyForAIRequestToken += 1 }

    /// Ask the shell to present the document open panel (menu command hook).
    ///
    /// This is the keyboard path to the ONLY recovery from a failed import.
    /// The document pane already offers it prominently as "Choose Files", but
    /// until now there was no menu item and no shortcut for it at all, so a
    /// keyboard-only user genuinely had no way out of a failed import. That,
    /// not the Scan for PII gate, was the real dead end behind audit item F2.
    public func requestOpen() { openRequestToken += 1 }

    /// Ask the shell to present the Restore from AI sheet (menu command hook).
    /// Resumes a parked session first (just in time, not at launch): the
    /// parked mapping is Keychain-protected, and touching the Keychain must
    /// happen in response to a user action, never as a surprise at startup.
    public func requestPasteRestore() {
        resumeParkedSession()
        pasteRestoreRequestToken += 1
    }
}
