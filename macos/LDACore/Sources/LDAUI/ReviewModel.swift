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

    /// When true and modelPath is a valid file, detection also runs the LLM
    /// extractor and merges its spans with the deterministic ones.
    @Published public var useLLM: Bool = false

    /// Optional absolute path to the v2 GGUF model. nil means deterministic-only.
    public var modelPath: String?

    /// The source URL of the currently open document, used to pick the right
    /// edit-surface writer on export (docx vs text/pdf companion).
    private var sourceURL: URL?

    public init(modelPath: String?) {
        self.modelPath = modelPath
    }

    // MARK: - Open

    /// Import the document with the right importer (txt, docx, or pdf with OCR
    /// fallback) and then detect entities. Import and detection run off the main
    /// thread; the text, entities, and status are published on the main actor.
    public func open(_ url: URL) async {
        status = .importing
        sourceURL = url

        let shouldUseLLM = useLLM
        let path = modelPath

        do {
            let text = try await Task.detached(priority: .userInitiated) {
                try Self.importText(from: url)
            }.value

            documentText = text
            status = .detecting

            let spans = await Task.detached(priority: .userInitiated) {
                Self.detect(in: text, useLLM: shouldUseLLM, modelPath: path)
            }.value

            entities = spans.map { ReviewEntity(span: $0, accepted: true) }
            status = .ready
        } catch {
            entities = []
            status = .failed(Self.describe(error))
        }
    }

    // MARK: - Accept toggle

    /// Set the accepted flag of one entity. A no-op if the id is unknown.
    public func setAccepted(_ id: ReviewEntity.ID, _ accepted: Bool) {
        guard let index = entities.firstIndex(where: { $0.id == id }) else { return }
        entities[index].accepted = accepted
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

        let baseName = source?.deletingPathExtension().lastPathComponent ?? "document"
        let sourceFile = source?.lastPathComponent ?? "document.txt"
        let sourceExt = source?.pathExtension.lowercased() ?? "txt"

        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )

        let tokenized = Tokenizer.tokenize(
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
            try DocxRedactor.redact(
                original: source,
                replacements: replacements,
                to: redactedURL
            )
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
    private nonisolated static func detect(
        in text: String,
        useLLM: Bool,
        modelPath: String?
    ) -> [Span] {
        SpanMerger.merge(
            deterministic: DeterministicEngine().detect(text),
            llm: llmSpans(in: text, useLLM: useLLM, modelPath: modelPath)
        )
    }

    /// Produce the LLM span list, or empty on any failure or when disabled.
    private nonisolated static func llmSpans(
        in text: String,
        useLLM: Bool,
        modelPath: String?
    ) -> [Span] {
        guard useLLM, let modelPath else { return [] }
        guard FileManager.default.fileExists(atPath: modelPath) else { return [] }
        do {
            let engine = try LLMEngine(config: .init(modelPath: modelPath))
            return try LLMExtractor(completer: engine).extract(from: text)
        } catch {
            return []
        }
    }

    // MARK: - Export helpers

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
