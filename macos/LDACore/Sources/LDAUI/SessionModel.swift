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
    @Published public var clientLabel: String?

    /// The shared session mapping after the most recent hand-to-AI build.
    /// Restore-from-paste runs against this.
    @Published public private(set) var sessionMapping: Mapping?

    /// Bumped when the Copy for AI menu command fires.
    @Published public var copyForAIRequestToken = 0

    /// Bumped when the Restore from AI menu command fires.
    @Published public var pasteRestoreRequestToken = 0

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

    /// Shown while the tray is empty so the shell always has a model to bind.
    public let emptyModel: ReviewModel

    /// The client mapping store. Injectable for tests.
    private let clientStore: () throws -> ClientMappingStore

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

    /// UserDefaults key remembering the parked session's client label.
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

    // MARK: - Tray management (R19)

    /// Add documents to the session. A .zip expands into its supported
    /// documents. Each document gets its own configured ReviewModel and is
    /// imported immediately; the last added document becomes selected.
    public func addDocuments(_ urls: [URL]) async {
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
            let model = makeModel()
            configureNewModel?(model)
            let entry = DocumentEntry(id: UUID(), url: url, model: model)
            entries.append(entry)
            selectedID = entry.id
            await model.open(url)
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
        sessionMapping = result.mapping

        // Save the union back under the client so the next session keeps
        // these identities (R10).
        if let clientLabel {
            try clientStore().save(
                result.mapping,
                label: clientLabel,
                protection: clientProtection(clientLabel)
            )
        }

        // Show the assigned tokens on the accepted entities (sealed chips).
        let tokenBySurface = ReviewModel.tokenBySurface(mapping: result.mapping)
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
                .map { "# Document: \($0.name)\n\n\($0.tokenizedText)" }
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
        if let url = try? parkedMappingURL() {
            try? MappingStore.save(result.mapping, to: url, protection: parkedProtection())
            UserDefaults.standard.set(clientLabel, forKey: Self.parkedClientLabelKey)
        }

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
              let mapping = try? MappingStore.load(from: url, protection: parkedProtection()) else {
            return
        }
        sessionMapping = mapping
        if clientLabel == nil {
            clientLabel = UserDefaults.standard.string(forKey: Self.parkedClientLabelKey)
        }
        sessionNote = "Resumed your last session. When the AI answer is ready, "
            + "use the De-anonymize tab to bring the real values back."
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

    /// The labels of every stored client profile.
    public func clientLabels() -> [String] {
        (try? clientStore().list()) ?? []
    }

    /// Ask the shell to run the Copy for AI flow (menu command hook).
    public func requestCopyForAI() { copyForAIRequestToken += 1 }

    /// Ask the shell to present the Restore from AI sheet (menu command hook).
    /// Resumes a parked session first (just in time, not at launch): the
    /// parked mapping is Keychain-protected, and touching the Keychain must
    /// happen in response to a user action, never as a surprise at startup.
    public func requestPasteRestore() {
        resumeParkedSession()
        pasteRestoreRequestToken += 1
    }
}
