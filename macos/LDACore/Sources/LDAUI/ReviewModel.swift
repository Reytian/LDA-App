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

// MARK: - ExportResult

/// The outcome of an export: where the redacted edit surface and the encrypted
/// mapping sidecar were written, and how many tokens were minted.
public struct ExportResult: Equatable {
    public let redactedURL: URL
    public let mappingURL: URL
    public let tokenCount: Int

    public init(redactedURL: URL, mappingURL: URL, tokenCount: Int) {
        self.redactedURL = redactedURL
        self.mappingURL = mappingURL
        self.tokenCount = tokenCount
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

    /// Whether the AI extractor actually ran for the last anonymize pass. When
    /// false, detection was pattern-matching only, so the window can warn that
    /// names, companies, and addresses may have been missed.
    @Published public var aiActive: Bool = false

    /// Bumped when the Export menu command fires, so the window can present the
    /// export flow (which owns the panels and passphrase sheet).
    @Published public var exportRequestToken: Int = 0

    /// Bumped when the Restore menu command fires.
    @Published public var restoreRequestToken: Int = 0

    /// The open document's file name, for the window title.
    public var documentName: String? { sourceURL?.lastPathComponent }

    /// How many entities will be redacted (accepted) on export.
    public var redactedCount: Int { entities.filter { $0.accepted }.count }

    /// How many detected entities the user rejected and that will therefore
    /// remain visible in the exported document.
    public var visibleCount: Int { entities.filter { !$0.accepted }.count }

    /// Ask the window to begin the restore flow. Used by the File menu command.
    public func requestRestore() { restoreRequestToken += 1 }

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

    public init(modelPath: String?) {
        self.modelPath = modelPath
    }

    // MARK: - Open

    /// Import the document with the right importer (txt, docx, or pdf with OCR
    /// fallback) and show it. Detection does NOT run here; the user starts it with
    /// anonymize(). Import runs off the main thread; results publish on the main
    /// actor.
    public func open(_ url: URL) async {
        status = .importing
        sourceURL = url
        entities = []
        progress = 0
        etaText = nil

        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try Self.importText(from: url)
            }.value

            documentText = text
            status = .imported
        } catch {
            entities = []
            status = .failed(Self.describe(error))
        }
    }

    // MARK: - Anonymize

    /// Detect entities over the current text: deterministic always, plus the LLM
    /// pass when enabled. Reports determinate progress and an ETA while running.
    /// Safe to call again to re-run (for example after toggling AI entities).
    public func anonymize() async {
        guard !documentText.isEmpty else { return }
        let text = documentText
        let shouldUseLLM = useLLM
        let path = modelPath
        let custom = customPatternProvider()
        let learnedRedact = learningStore?.redactPatterns ?? []
        let suppress = learningStore?.suppressKeys ?? []
        let runsLLM = shouldUseLLM && path.map { FileManager.default.fileExists(atPath: $0) } == true

        status = .detecting
        progress = 0
        etaText = runsLLM ? "Loading model" : nil
        learningNote = nil
        anonymizeStart = Date()

        let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            DispatchQueue.main.async { self?.applyProgress(done: done, total: total) }
        }

        let outcome = await Task.detached(priority: .userInitiated) {
            Self.detect(
                in: text,
                useLLM: shouldUseLLM,
                modelPath: path,
                custom: custom,
                learnedRedact: learnedRedact,
                suppressKeys: suppress,
                onProgress: report
            )
        }.value

        entities = outcome.spans.map { ReviewEntity(span: $0, accepted: true) }
        learningNote = Self.learningNote(applied: outcome.learnedApplied, suppressed: outcome.suppressed)
        aiActive = runsLLM
        progress = 1
        etaText = nil
        status = .ready
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
    private func applyProgress(done: Int, total: Int) {
        guard case .detecting = status, total > 0 else { return }
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

    // MARK: - Export

    /// Tokenize the accepted spans over the current (possibly edited) text, write
    /// the redacted edit surface, and save the encrypted mapping sidecar. The
    /// caller supplies createdAtISO8601 so tokenize stays deterministic.
    ///
    /// The edit surface depends on the source format: a run-preserving redacted
    /// .docx for .docx input, otherwise a redacted .txt companion. The sidecar is
    /// always written next to the edit surface as <baseName>.ldamap.
    public func export(
        to outputDir: URL,
        passphrase: String?,
        createdAtISO8601: String
    ) throws -> ExportResult {
        let acceptedSpans = entities.filter { $0.accepted }.map { $0.span }
        let text = documentText
        let source = sourceURL
        // Read the custom vocabulary on the main actor so the non-body detector
        // (built below) uses the same inputs the body detection used.
        let custom = customPatternProvider()

        let baseName = source?.deletingPathExtension().lastPathComponent ?? "document"
        let sourceFile = source?.lastPathComponent ?? "document.txt"
        let sourceExt = source?.pathExtension.lowercased() ?? "txt"

        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )

        // Declared var so non-body redaction can fold in new mapping entries below.
        var tokenized = Tokenizer.tokenize(
            text: text,
            spans: acceptedSpans,
            sourceFile: sourceFile,
            createdAtISO8601: createdAtISO8601
        )

        let redactedURL: URL
        if sourceExt == "docx", let source {
            redactedURL = outputDir.appendingPathComponent("\(baseName)_redacted.docx")
            let replacements = Self.buildReplacements(
                spans: acceptedSpans,
                mapping: tokenized.mapping
            )
            // Redact the body AND every other text-bearing part (headers, footers,
            // footnotes, endnotes, comments), scrub docProps author/title metadata,
            // and neutralize external mailto:/tel: hyperlink targets, mirroring
            // LDAService.anonymize. The non-body detector is the same deterministic
            // plus best-effort LLM detection the body used, built from this model's
            // own settings; it never re-runs the LLM over the body. Surfaces found
            // only in a non-body part mint new tokens that are folded into the
            // mapping below so they persist in the sidecar and restore correctly.
            let detect = Self.nonBodyDetector(useLLM: useLLM, modelPath: modelPath, custom: custom)
            let nonBodyEntries = try DocxRedactor.redact(
                original: source,
                replacements: replacements,
                to: redactedURL,
                nonBody: (mapping: tokenized.mapping, detect: detect)
            )
            for entry in nonBodyEntries {
                tokenized.mapping.entries[entry.token] = entry
            }
        } else {
            redactedURL = outputDir.appendingPathComponent("\(baseName)_redacted.txt")
            try CompanionWriter.writeText(tokenized.tokenizedText, to: redactedURL)
        }

        let redactedBaseName = redactedURL.deletingPathExtension().lastPathComponent
        let mappingURL = outputDir.appendingPathComponent("\(redactedBaseName).ldamap")
        let protection: MappingProtection = passphrase
            .map { .passphrase($0) }
            ?? .keychain(account: redactedBaseName)
        try MappingStore.save(tokenized.mapping, to: mappingURL, protection: protection)

        // Record the assigned tokens back onto the matching entities so the UI
        // can render sealed chips after export.
        let tokenBySurface = Self.tokenBySurface(mapping: tokenized.mapping)
        for index in entities.indices {
            entities[index].token = entities[index].accepted
                ? tokenBySurface[entities[index].span.text]
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

        return ExportResult(
            redactedURL: redactedURL,
            mappingURL: mappingURL,
            tokenCount: tokenized.mapping.entries.count
        )
    }

    // MARK: - Detection helpers (off the main actor)

    /// Import a document by extension. PDF with no usable text layer falls back
    /// to Vision OCR. Unknown extensions are treated as plain text.
    private nonisolated static func importText(from url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "docx":
            return try DocxImporter().importDocument(url).text
        case "pdf":
            let imported = try PdfImporter().importDocument(url)
            guard imported.isScanned else { return imported.text }
            return try PdfOCRImporter().importDocument(url).text
        default:
            return try TextDocumentIO().importDocument(url).text
        }
    }

    /// Run deterministic detection and, when requested and the model path is a
    /// valid file, merge in LLM spans. Any LLM failure degrades to
    /// deterministic-only so detection never fails because of the LLM seam.
    /// The result of a detection pass plus what learning contributed.
    private struct DetectionOutcome {
        let spans: [Span]
        let learnedApplied: Int
        let suppressed: Int
    }

    private nonisolated static func detect(
        in text: String,
        useLLM: Bool,
        modelPath: String?,
        custom: [CustomPattern] = [],
        learnedRedact: [CustomPattern] = [],
        suppressKeys: Set<String> = [],
        onProgress: ((Int, Int) -> Void)? = nil
    ) -> DetectionOutcome {
        // Custom vocabulary and learned redactions join the deterministic list
        // with a higher priority, so a user-chosen or previously-accepted term
        // always wins overlap conflicts.
        let deterministic = DeterministicEngine().detect(text)
            + CustomPatternEngine.detect(text, patterns: custom)
            + CustomPatternEngine.detect(text, patterns: learnedRedact)
        let merged = SpanMerger.merge(
            deterministic: deterministic,
            llm: llmSpans(in: text, useLLM: useLLM, modelPath: modelPath, onProgress: onProgress)
        )

        // Suppress values the user has repeatedly rejected.
        let kept = suppressKeys.isEmpty
            ? merged
            : merged.filter { !suppressKeys.contains(LearningStore.key(value: $0.text, type: $0.type)) }
        let suppressed = merged.count - kept.count

        // Count distinct learned values that actually landed in this document.
        let learnedValues = Set(learnedRedact.map {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let appliedValues = Set(
            kept.map { $0.text.lowercased() }.filter { learnedValues.contains($0) }
        )

        return DetectionOutcome(spans: kept, learnedApplied: appliedValues.count, suppressed: suppressed)
    }

    /// Produce the LLM span list, or empty on any failure or when disabled.
    private nonisolated static func llmSpans(
        in text: String,
        useLLM: Bool,
        modelPath: String?,
        onProgress: ((Int, Int) -> Void)? = nil
    ) -> [Span] {
        guard useLLM, let modelPath else { return [] }
        guard FileManager.default.fileExists(atPath: modelPath) else { return [] }
        do {
            let engine = try LLMEngine(config: .init(modelPath: modelPath))
            return try LLMExtractor(completer: engine).extract(from: text, onProgress: onProgress)
        } catch {
            return []
        }
    }

    // MARK: - Export helpers

    /// A non-throwing detector over arbitrary part text for the DOCX non-body
    /// pass, built from this model's own settings. It is deterministic plus
    /// custom vocabulary, merged with best-effort LLM spans (any LLM failure
    /// degrades to empty), mirroring LDAService's detectForImages. It only ever
    /// scans the small non-body parts (headers, footers, notes), never the body,
    /// so it does not re-run the LLM over the document the user already reviewed.
    private nonisolated static func nonBodyDetector(
        useLLM: Bool,
        modelPath: String?,
        custom: [CustomPattern]
    ) -> (String) -> [Span] {
        return { text in
            let deterministic = DeterministicEngine().detect(text)
                + CustomPatternEngine.detect(text, patterns: custom)
            return SpanMerger.merge(
                deterministic: deterministic,
                llm: llmSpans(in: text, useLLM: useLLM, modelPath: modelPath)
            )
        }
    }

    /// Map each accepted span to a Replacement by looking up its token via the
    /// tokenizer mapping (one token per distinct surface text).
    private static func buildReplacements(
        spans: [Span],
        mapping: Mapping
    ) -> [Replacement] {
        let tokenBySurface = tokenBySurface(mapping: mapping)
        return spans.compactMap { span in
            guard let token = tokenBySurface[span.text] else { return nil }
            return Replacement(span: span, token: token)
        }
    }

    /// surfaceText -> token, keeping the first token seen for a given surface.
    private static func tokenBySurface(mapping: Mapping) -> [String: String] {
        var result: [String: String] = [:]
        for entry in mapping.entries.values where result[entry.surfaceText] == nil {
            result[entry.surfaceText] = entry.token
        }
        return result
    }

    // MARK: - Error rendering

    /// A user-facing one-line description of an import or IO error.
    private nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let ioError as DocumentIOError:
            switch ioError {
            case .unreadable(let detail):
                return "The file could not be read. \(detail)"
            case .unsupportedFormat(let detail):
                return "Unsupported format. \(detail)"
            case .corrupt(let detail):
                return "The file is corrupt. \(detail)"
            case .ocrUnavailable:
                return "OCR is unavailable on this system."
            case .decryptionFailed:
                return "The document could not be decrypted."
            case .keychainError(let status):
                return "A Keychain error occurred (status \(status))."
            }
        default:
            return error.localizedDescription
        }
    }
}
