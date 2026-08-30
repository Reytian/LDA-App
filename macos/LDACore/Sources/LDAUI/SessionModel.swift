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

    /// The menu-bar companion's last-action note ("Restored 4 values.").
    @Published public var companionNote: String?

    /// A quiet session-level note for the window banner (for example the
    /// resumed-parked-session hint).
    @Published public var sessionNote: String?

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
            for entry in entries {
                configure(entry.model)
            }
        }
    }

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
        for entry in entries {
            configure(entry.model)
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
    public func addDocuments(_ urls: [URL]) async {
        let importGeneration = documentImportGeneration
        var resolved: [URL] = []
        for url in urls {
            if ZipImporter.isZip(url) {
                if let expanded = try? ZipImporter.expand(url) {
                    resolved.append(contentsOf: expanded)
                }
            } else {
                resolved.append(url)
            }
        }

        for url in resolved {
            guard importGeneration == documentImportGeneration else { return }
            let model = makeModel()
            configureNewModel?(model)
            let entry = DocumentEntry(id: UUID(), url: url, model: model)
            entries.append(entry)
            selectedID = entry.id
            await openDocument(model, url)
            guard importGeneration == documentImportGeneration else { return }
        }
    }

    /// Remove a document from the tray.
    public func removeDocument(id: UUID) {
        entries.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = entries.first?.id
        }
    }

    /// Detect entities in every document that has not run yet, sequentially so
    /// only one model pass is in flight at a time.
    public func anonymizeAll() async {
        for entry in entries {
            switch entry.model.status {
            case .imported:
                await entry.model.anonymize()
            default:
                continue
            }
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
        let result = SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: label,
            createdAtISO8601: createdAtISO8601,
            seedMapping: seed
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
        let record = SessionRecord(
            createdAtISO8601: createdAtISO8601,
            clientLabel: clientLabel,
            documents: ready.map { entry in
                SessionRecordDocument(
                    name: entry.name,
                    entityCount: entry.model.redactedCount,
                    entityTypes: distinctTypes(of: entry.model)
                )
            },
            protectedValueCount: result.mapping.entries.count
        )
        if let store = try? recordStore() {
            try? store.save(record, protection: recordProtection())
            currentRecordID = record.id
        }

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
            skippedCount: entries.count - ready.count
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
            seedMapping: seed
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
        return selectClient(label, discardingDocuments: discardingDocuments)
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
