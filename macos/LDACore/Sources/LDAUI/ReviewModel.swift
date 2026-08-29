//
//  ReviewModel.swift
//  LDAUI
//
//  The testable view-model that orchestrates LDACore for the review window. It
//  imports a document, detects entities (deterministic, optionally merged with
//  LLM spans), and lets the user edit the text and accept or reject each entity
//  before tokenizing on export.
//
//  Heavy work (import, detection, the LLM pass, and tokenize + write on export)
//  is run off the main thread in a detached Task; results are published back on
//  the main actor. The model itself is @MainActor so every @Published mutation
//  is main-actor isolated.
//
//  Purity at the seam: export takes a caller-supplied ISO-8601 timestamp so the
//  tokenize step stays deterministic and unit-testable.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

// MARK: - ReviewEntity

/// One reviewable detection: a located Span, whether the user accepted it, and
/// the opaque token assigned to it after export.
public struct ReviewEntity: Identifiable, Equatable {
    /// Stable identity for SwiftUI lists and selection.
    public let id: UUID
    /// The located span (UTF-16 offsets) in the current document text.
    public var span: Span
    /// True when this entity should be tokenized on export.
    public var accepted: Bool
    /// The token assigned during the most recent export, if any.
    public var token: String?

    public init(id: UUID = UUID(), span: Span, accepted: Bool, token: String? = nil) {
        self.id = id
        self.span = span
        self.accepted = accepted
        self.token = token
    }
}

// MARK: - ReviewStatus

/// The lifecycle state of the review session.
public enum ReviewStatus: Equatable {
    case idle
    case importing
    /// The document is imported and shown, awaiting the user to start anonymizing.
    case imported
    case detecting
    case ready
    case failed(String)
}

// MARK: - ReviewGroup

/// All occurrences of one value within a type, collapsed into a single
/// reviewable unit. The sidebar renders one row per group, and the keyboard
/// review loop (next/previous/toggle) walks groups in display order.
public struct ReviewGroup: Identifiable, Equatable {
    public let id: String
    public let value: String
    public let type: EntityType
    public let source: DetectionSource
    public var ids: Set<ReviewEntity.ID>
    public var occurrences: Int
    /// True when at least one occurrence is accepted; the group's toggle state.
    public var anyAccepted: Bool
    /// The sealed token once assigned to an accepted occurrence, if any.
    public var token: String?
}

// MARK: - ExportResult

/// The outcome of an export: where the redacted edit surface and the encrypted
/// mapping sidecar were written, and how many tokens were minted.
public struct ExportResult: Equatable {
    public let redactedURL: URL
    public let mappingURL: URL
    public let tokenCount: Int
    /// Embedded media files (word/media/...) copied verbatim into the redacted
    /// DOCX without PII scanning. Non-zero means the UI must warn: wet-ink
    /// signature scans and stamps live there. Always 0 for non-DOCX sources.
    public let embeddedMediaCount: Int

    public init(redactedURL: URL, mappingURL: URL, tokenCount: Int, embeddedMediaCount: Int = 0) {
        self.redactedURL = redactedURL
        self.mappingURL = mappingURL
        self.tokenCount = tokenCount
        self.embeddedMediaCount = embeddedMediaCount
    }
}

// MARK: - ReviewModel

/// Orchestrates LDACore for the review UI. @MainActor so every published change
/// is delivered on the main actor; engine work runs off the main thread.
@MainActor
public final class ReviewModel: ObservableObject {

    /// The current edit surface text. The user may edit this before export.
    @Published public var documentText: String = ""

    /// The reviewable detections over documentText.
    @Published public var entities: [ReviewEntity] = []

    /// The session lifecycle state.
    @Published public var status: ReviewStatus = .idle

    /// Determinate progress of the anonymize pass, 0...1. Meaningful while
    /// status is .detecting.
    @Published public var progress: Double = 0

    /// A short human-readable estimate of remaining time during the anonymize
    /// pass (for example "about 12s remaining"), or nil when not applicable.
    @Published public var etaText: String?

    /// When true and modelPath is a valid file, detection also runs the LLM
    /// extractor and merges its spans with the deterministic ones. AI detection is
    /// on by default; it degrades to deterministic-only if no model is present.
    @Published public var useLLM: Bool = true

    /// Optional absolute path to the v2 GGUF model. nil means deterministic-only.
    public var modelPath: String?

    /// Supplies the user's custom vocabulary at anonymize time. The app wires this
    /// to the CustomPatternStore; the default is an empty list.
    public var customPatternProvider: () -> [CustomPattern] = { [] }

    /// On-device learning. When set, the model applies learned redactions and
    /// suppressions during anonymize and records the user's decisions on export.
    public var learningStore: LearningStore?

    /// A short summary of what learning contributed to the last run, for example
    /// "Applied 2 learned terms, hid 1 you rejected before." nil when nothing.
    @Published public var learningNote: String?

    /// Whether the AI extractor actually ran TO COMPLETION for the last
    /// anonymize pass. False when AI was off, the model was missing, the
    /// engine failed, or the scan did not fully cover the document; in every
    /// one of those cases the window must warn that names, companies, and
    /// addresses may have been missed.
    @Published public var aiActive: Bool = false

    /// A user-facing explanation when the AI pass was expected but failed or
    /// could not fully scan the document. nil when AI ran cleanly or was off.
    @Published public var aiWarning: String?

    /// The selected group row in the sidebar. Selection is shared between the
    /// sidebar list and the keyboard review commands (next/previous/toggle) so
    /// the menu shortcuts and the list always agree.
    @Published public var selectedGroupID: String?

    /// Bumped when the Export menu command fires, so the window can present the
    /// export flow (which owns the panels and passphrase sheet).
    @Published public var exportRequestToken: Int = 0

    /// Bumped when the Restore menu command fires.
    @Published public var restoreRequestToken: Int = 0

    /// Bumped when the Scan for PII menu command fires, so the window can
    /// start the pass (the shell owns the async run).
    @Published public var anonymizeRequestToken: Int = 0

    /// The open document's file name, for the window title.
    public var documentName: String? { sourceURL?.lastPathComponent }

    /// How many entities will be redacted (accepted) on export.
    public var redactedCount: Int { entities.filter { $0.accepted }.count }

    /// How many detected entities the user rejected and that will therefore
    /// remain visible in the exported document.
    public var visibleCount: Int { entities.filter { !$0.accepted }.count }

    /// Ask the window to begin the restore flow. Used by the File menu command.
    public func requestRestore() { restoreRequestToken += 1 }

    /// True when a Scan for PII pass can start (a document is loaded and no
    /// pass is running). Shared by the banner button and the menu command.
    /// `.failed` is deliberately NOT scannable. Do not "fix" this by allowing a
    /// retry when documentText is non-empty; that was tried and was wrong twice
    /// over:
    ///
    ///  - It is unreachable. `.failed` is set in exactly one place, open(_:)'s
    ///    catch, which is an IMPORT failure that leaves documentText empty.
    ///    anonymize() never fails: detection ends at .ready, and an LLM problem
    ///    surfaces through aiWarning rather than a failed status, on purpose, so
    ///    a degraded pass warns instead of looking clean.
    ///  - If it ever did become reachable by reusing a model across documents,
    ///    it would be unsafe: open(_:) sets the NEW sourceURL before importing,
    ///    so scanning retained text would attribute one document's PII to
    ///    another's name. The catch now clears documentText for the same reason.
    ///
    /// Recovery from an import failure is re-opening the file, which the
    /// document pane already offers prominently (DocumentPane's drop zone) and
    /// which File > Open (Cmd+O) reaches from the keyboard.
    public var canAnonymize: Bool {
        switch status {
        case .imported, .ready:
            return true
        case .idle, .importing, .detecting, .failed:
            return false
        }
    }

    /// Ask the window to run Scan for PII. Used by the menu command.
    public func requestAnonymize() {
        guard canAnonymize else { return }
        anonymizeRequestToken += 1
    }

    /// True once a document has been anonymized and is ready to export.
    public var canExport: Bool {
        if case .ready = status { return true }
        return false
    }

    /// Ask the window to begin the export flow. Used by the File menu command.
    public func requestExport() {
        guard canExport else { return }
        exportRequestToken += 1
    }

    /// The source URL of the currently open document, used to pick the right
    /// edit-surface writer on export (docx vs text/pdf companion).
    private var sourceURL: URL?

    /// When the current anonymize pass started, used to estimate time remaining.
    private var anonymizeStart: Date?

    /// Stop flag for the in-flight anonymize pass; nil when none is running.
    private var activeCancelToken: ExtractionCancelToken?

    /// Monotonic generation for the open document. Every open() bumps it; any
    /// in-flight import or detection captured an older value and must discard
    /// its results instead of landing them on the newer document (showing doc
    /// A's detections over doc B's text is the worst failure mode for a legal
    /// review tool).
    private var sessionGeneration = 0

    // MARK: - Test seams

    /// Test-only artificial delay inside the detection pass, used to stage the
    /// stale-result race deterministically. Production never sets it.
    nonisolated(unsafe) internal static var detectDelayForTesting: TimeInterval?

    /// Test-only LLM extractor factory so AI-path outcomes (failure,
    /// incomplete coverage) can be exercised without a real GGUF model.
    /// Receives the configured model path. Production leaves this nil.
    nonisolated(unsafe) internal static var llmExtractorFactoryForTesting: ((String, ExtractionCancelToken?) -> LLMExtractor)?

    public init(modelPath: String?) {
        self.modelPath = modelPath
    }

    // MARK: - Open

    /// Import the document with the right importer (txt, docx, or pdf with OCR
    /// fallback) and show it. Detection does NOT run here; the user starts it with
    /// anonymize(). Import runs off the main thread; results publish on the main
    /// actor.
    public func open(_ url: URL) async {
        // Invalidate any in-flight import or detection for the previous
        // document; their results must not land on this one.
        sessionGeneration += 1
        let generation = sessionGeneration

        status = .importing
        sourceURL = url
        entities = []
        selectedGroupID = nil
        progress = 0
        etaText = nil
        aiWarning = nil

        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try Self.importText(from: url)
            }.value

            guard generation == sessionGeneration else { return }
            documentText = text
            status = .imported
        } catch {
            guard generation == sessionGeneration else { return }
            entities = []
            // Drop any text from a PREVIOUS document. sourceURL was already
            // updated to the new file above, so retaining the old text would
            // leave the model describing document A's contents under document
            // B's name, and every downstream label (window title, tray row,
            // export file name, mapping sourceFile) would take the new name.
            // Production never reuses a model across documents, but the
            // invariant is now enforced here rather than assumed.
            documentText = ""
            status = .failed(Self.describe(error))
        }
    }

    // MARK: - Anonymize

    /// Detect entities over the current text: deterministic always, plus the LLM
    /// pass when enabled. Reports determinate progress and an ETA while running.
    /// Safe to call again to re-run (for example after toggling AI entities).
    public func anonymize() async {
        guard !documentText.isEmpty else { return }
        let generation = sessionGeneration
        let text = documentText
        let shouldUseLLM = useLLM
        let path = modelPath
        let custom = customPatternProvider()
        let learnedRedact = learningStore?.redactPatterns ?? []
        let suppress = learningStore?.suppressKeys ?? []
        let expectsLLM = shouldUseLLM && path.map { FileManager.default.fileExists(atPath: $0) } == true

        // Remember where we came from so a user stop can put the UI back
        // exactly as it was, entities untouched.
        let statusBeforeDetecting = status
        let cancelToken = ExtractionCancelToken()
        activeCancelToken = cancelToken

        status = .detecting
        progress = 0
        etaText = expectsLLM ? "Loading model" : nil
        learningNote = nil
        aiWarning = nil
        anonymizeStart = Date()

        let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            DispatchQueue.main.async {
                self?.applyProgress(done: done, total: total, generation: generation)
            }
        }

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.detect(
                in: text,
                useLLM: shouldUseLLM,
                modelPath: path,
                custom: custom,
                learnedRedact: learnedRedact,
                suppressKeys: suppress,
                cancel: cancelToken,
                onProgress: report
            )
        }.value

        // A newer document was opened while this pass ran: discard everything.
        guard generation == sessionGeneration else { return }
        activeCancelToken = nil

        // The user stopped the pass: restore the prior state and present no
        // partial detection as if it were a completed one.
        if outcome.cancelled {
            progress = 0
            etaText = nil
            status = statusBeforeDetecting
            return
        }

        entities = outcome.spans.map { ReviewEntity(span: $0, accepted: true) }
        learningNote = Self.learningNote(applied: outcome.learnedApplied, suppressed: outcome.suppressed)
        // AI is only "active" when the pass ran to full coverage; a load
        // failure or partial scan must warn, never silently pose as a clean
        // AI pass.
        aiActive = outcome.aiRan
        aiWarning = outcome.aiFailure
        progress = 1
        etaText = nil
        status = .ready
    }

    /// Stop the in-flight anonymize pass. The engine aborts generation within
    /// a fraction of a second; anonymize() then restores the prior status
    /// without presenting partial results. Safe to call when nothing runs.
    public func cancelAnonymize() {
        guard activeCancelToken != nil else { return }
        etaText = "Stopping"
        activeCancelToken?.cancel()
    }

    // MARK: - Restore (de-anonymize)

    /// Restore an edited redacted document back to its original values using its
    /// encrypted mapping sidecar. Standalone: does not touch the review session.
    public func restore(
        editedRedacted: URL,
        mapping: URL,
        passphrase: String?,
        output: URL
    ) throws -> RestoreReport {
        let protection: MappingProtection = passphrase.map { .passphrase($0) }
            ?? .keychain(account: mapping.deletingPathExtension().lastPathComponent)
        return try LDAService.restore(
            editedRedacted: editedRedacted,
            mapping: mapping,
            protection: protection,
            output: output
        )
    }

    /// A short, human note about what learning contributed, or nil when nothing.
    private static func learningNote(applied: Int, suppressed: Int) -> String? {
        var parts: [String] = []
        if applied > 0 {
            parts.append("applied \(applied) learned " + (applied == 1 ? "term" : "terms"))
        }
        if suppressed > 0 {
            parts.append("hid \(suppressed) you rejected before")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst()
    }

    /// Update progress and the time estimate from a (done, total) report.
    /// Reports from a superseded session (an older document) are dropped.
    private func applyProgress(done: Int, total: Int, generation: Int) {
        guard generation == sessionGeneration else { return }
        guard case .detecting = status, total > 0 else { return }
        // A stop is in flight: keep the "Stopping" label instead of letting a
        // late progress tick overwrite it with a stale ETA.
        if activeCancelToken?.isCancelled == true { return }
        progress = Double(done) / Double(total)
        guard done > 0, done < total, let start = anonymizeStart else {
            etaText = done == 0 ? etaText : nil
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        let remaining = elapsed / Double(done) * Double(total - done)
        etaText = Self.formatETA(remaining)
    }

    /// Format a remaining-seconds estimate as a short human string.
    private static func formatETA(_ seconds: Double) -> String {
        let total = max(1, Int(seconds.rounded()))
        if total < 60 { return "about \(total)s remaining" }
        let minutes = total / 60
        let secs = total % 60
        return secs == 0
            ? "about \(minutes)m remaining"
            : "about \(minutes)m \(secs)s remaining"
    }

    // MARK: - Accept toggle

    /// Set the accepted flag of one entity. A no-op if the id is unknown.
    public func setAccepted(_ id: ReviewEntity.ID, _ accepted: Bool) {
        guard let index = entities.firstIndex(where: { $0.id == id }) else { return }
        entities[index].accepted = accepted
    }

    /// Set the accepted flag for several entities at once, so a grouped row (all
    /// occurrences of the same value) can be accepted or rejected together.
    public func setAccepted(ids: Set<ReviewEntity.ID>, _ accepted: Bool) {
        guard !ids.isEmpty else { return }
        for index in entities.indices where ids.contains(entities[index].id) {
            entities[index].accepted = accepted
        }
    }

    /// Set the accepted flag for EVERY entity of a type, so a section header
    /// can dispatch a whole category ("keep all dates visible") in one action.
    public func setAccepted(type: EntityType, _ accepted: Bool) {
        for index in entities.indices where entities[index].span.type == type {
            entities[index].accepted = accepted
        }
    }

    // MARK: - Add a missed item (R5)

    /// Protect a value the detector missed: find every occurrence of `text` in
    /// the current document and add each as an accepted manual entity. Ranges
    /// that overlap an existing entity are skipped so nothing double-tokenizes.
    ///
    /// - Returns: how many occurrences were added (0 means the text was not
    ///   found, or every occurrence was already covered).
    @discardableResult
    public func addManualEntity(text: String, type: EntityType) -> Int {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !documentText.isEmpty else { return 0 }

        let nsText = documentText as NSString
        var added = 0
        var searchStart = 0
        while searchStart < nsText.length {
            let range = nsText.range(
                of: needle,
                options: [],
                range: NSRange(location: searchStart, length: nsText.length - searchStart)
            )
            guard range.location != NSNotFound else { break }

            let overlapsExisting = entities.contains { entity in
                range.location < entity.span.end
                    && range.location + range.length > entity.span.start
            }
            if !overlapsExisting {
                let span = Span(
                    start: range.location,
                    end: range.location + range.length,
                    type: type,
                    text: needle,
                    // Priority above the deterministic maximum so a user
                    // decision survives any later overlap resolution.
                    source: .manual,
                    confidence: 1.0,
                    priority: 110
                )
                entities.append(ReviewEntity(span: span, accepted: true))
                added += 1
            }
            searchStart = range.location + max(range.length, 1)
        }
        return added
    }

    // MARK: - Groups and the keyboard review loop

    /// The fixed type ordering for sidebar sections and keyboard navigation,
    /// so the walk order always matches what the sidebar shows.
    public static let groupTypeOrder: [EntityType] = [
        .person, .company, .address, .email, .phone,
        .bankAccount, .nationalID, .uscc, .amount, .date, .unknown
    ]

    /// Every review group in display order: sections follow groupTypeOrder and
    /// groups within a section follow first appearance in the document.
    public var entityGroups: [ReviewGroup] {
        ReviewModel.groupTypeOrder.flatMap { groups(of: $0) }
    }

    /// The groups of one type, in first-appearance order. Grouping is by value,
    /// case and whitespace insensitive, so every occurrence of "Investors"
    /// collapses into one row with a single accept control.
    public func groups(of type: EntityType) -> [ReviewGroup] {
        var order: [String] = []
        var byKey: [String: ReviewGroup] = [:]

        for entity in entities where entity.span.type == type {
            let key = entity.span.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if var existing = byKey[key] {
                existing.ids.insert(entity.id)
                existing.occurrences += 1
                existing.anyAccepted = existing.anyAccepted || entity.accepted
                if existing.token == nil, entity.accepted { existing.token = entity.token }
                byKey[key] = existing
            } else {
                order.append(key)
                byKey[key] = ReviewGroup(
                    id: "\(type.rawValue)|\(key)",
                    value: entity.span.text,
                    type: type,
                    source: entity.span.source,
                    ids: [entity.id],
                    occurrences: 1,
                    anyAccepted: entity.accepted,
                    token: entity.accepted ? entity.token : nil
                )
            }
        }
        return order.compactMap { byKey[$0] }
    }

    /// Move the selection to the next group in display order, wrapping at the
    /// end. With no selection, selects the first group.
    public func selectNextGroup() {
        let groups = entityGroups
        guard !groups.isEmpty else { return }
        guard let current = selectedGroupID,
              let index = groups.firstIndex(where: { $0.id == current }) else {
            selectedGroupID = groups[0].id
            return
        }
        selectedGroupID = groups[(index + 1) % groups.count].id
    }

    /// Move the selection to the previous group, wrapping at the start. With no
    /// selection, selects the last group.
    public func selectPreviousGroup() {
        let groups = entityGroups
        guard !groups.isEmpty else { return }
        guard let current = selectedGroupID,
              let index = groups.firstIndex(where: { $0.id == current }) else {
            selectedGroupID = groups[groups.count - 1].id
            return
        }
        selectedGroupID = groups[(index + groups.count - 1) % groups.count].id
    }

    /// Flip the accept state of the selected group: a group that reads as
    /// accepted (any occurrence accepted) becomes fully rejected, otherwise
    /// fully accepted. Every occurrence moves together.
    public func toggleSelectedGroup() {
        guard let id = selectedGroupID,
              let group = entityGroups.first(where: { $0.id == id }) else { return }
        setAccepted(ids: group.ids, !group.anyAccepted)
    }

    // MARK: - Export

    /// Tokenize the accepted spans over the current (possibly edited) text, write
    /// the redacted edit surface, and save the encrypted mapping sidecar. The
    /// caller supplies createdAtISO8601 so tokenize stays deterministic.
    ///
    /// The edit surface depends on the source format: a run-preserving redacted
    /// .docx for .docx input, otherwise a redacted .txt companion. The sidecar is
    /// always written next to the edit surface as <baseName>.ldamap. When a
    /// previous export already occupies the name, a numeric suffix is added
    /// instead of overwriting: the prior .ldamap may be the only key to restore
    /// an already-shared document, so silent overwrite is never acceptable.
    ///
    /// The heavy work (tokenize, DOCX rewrite, the non-body LLM pass) runs off
    /// the main actor so the window stays responsive during export.
    public func export(
        to outputDir: URL,
        passphrase: String?,
        createdAtISO8601: String
    ) async throws -> ExportResult {
        let acceptedSpans = entities.filter { $0.accepted }.map { $0.span }
        let text = documentText
        let source = sourceURL
        // Read the custom vocabulary on the main actor so the non-body detector
        // (built below) uses the same inputs the body detection used.
        let custom = customPatternProvider()
        let shouldUseLLM = useLLM
        let path = modelPath

        let result = try await Task.detached(priority: .userInitiated) {
            try Self.performExport(
                text: text,
                acceptedSpans: acceptedSpans,
                source: source,
                custom: custom,
                useLLM: shouldUseLLM,
                modelPath: path,
                outputDir: outputDir,
                passphrase: passphrase,
                createdAtISO8601: createdAtISO8601
            )
        }.value

        // Record the assigned tokens back onto the matching entities so the UI
        // can render sealed chips after export.
        for index in entities.indices {
            entities[index].token = entities[index].accepted
                ? result.tokenBySurface[entities[index].span.text]
                : nil
        }

        // Learn from this export: the accept and reject decisions the user just
        // committed reinforce future auto-redaction and suppression.
        if let learningStore {
            let accepted = entities.filter { $0.accepted }
                .map { (value: $0.span.text, type: $0.span.type) }
            let rejected = entities.filter { !$0.accepted }
                .map { (value: $0.span.text, type: $0.span.type) }
            learningStore.record(accepted: accepted, rejected: rejected)
        }

        return result.export
    }

}
