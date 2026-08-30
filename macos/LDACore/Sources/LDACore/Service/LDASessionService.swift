//
//  LDASessionService.swift
//  LDACore
//
//  The session-level service surface for the staged round-trip: anonymize a
//  SET of documents against one shared mapping (R12), producing per-document
//  redacted Markdown intermediates for the AI handoff (R6), and restore pasted
//  AI output text against a saved mapping (the bring-back half of the trip).
//
//  Like the rest of the facade this layer never reads the clock; the caller
//  supplies createdAtISO8601.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - Results

/// One document's output from a session anonymize: its source, its redacted
/// Markdown intermediate, and what was tokenized in it.
public struct SessionDocumentOutput: Sendable {
    /// The imported source document.
    public var sourceURL: URL
    /// The redacted Markdown intermediate handed to the external AI.
    public var redactedMarkdown: String
    /// How many spans were tokenized in this document.
    public var entityCount: Int
    /// The accepted spans (post-merge) tokenized in this document.
    public var entities: [Span]

    public init(
        sourceURL: URL,
        redactedMarkdown: String,
        entityCount: Int,
        entities: [Span]
    ) {
        self.sourceURL = sourceURL
        self.redactedMarkdown = redactedMarkdown
        self.entityCount = entityCount
        self.entities = entities
    }
}

/// The outcome of a session anonymize: every document's intermediate plus the
/// ONE shared mapping that restores the whole set.
public struct SessionAnonymizeResult: Sendable {
    public var documents: [SessionDocumentOutput]
    public var mapping: Mapping

    public init(documents: [SessionDocumentOutput], mapping: Mapping) {
        self.documents = documents
        self.mapping = mapping
    }
}

// MARK: - Session operations

extension LDAService {

    /// Anonymize a set of documents as ONE session sharing ONE mapping.
    ///
    /// Each input is imported (docx, pdf with OCR fallback, or text), detected
    /// (deterministic, plus the LLM pass when a model path is given), and
    /// tokenized with the accumulated session mapping as its seed, so the same
    /// value carries the same placeholder in every document. The returned
    /// intermediates are redacted Markdown strings; persisting them, and the
    /// mapping, is the caller's choice (clipboard, .md files, or a sidecar).
    ///
    /// - Parameters:
    ///   - inputs: the session's documents, in order. Must not be empty.
    ///   - createdAtISO8601: caller-supplied ISO-8601 timestamp.
    ///   - llmModelPath: optional GGUF path; nil stays deterministic-only.
    ///   - seedMapping: optional starting mapping (a client profile's stored
    ///     mapping) whose identities the session keeps using.
    /// - Throws: DocumentIOError for unreadable inputs,
    ///   LDAServiceError.incompleteExtraction when the LLM could not fully
    ///   scan a document, LDAServiceError.unanchoredEntities when it scanned
    ///   everything but reported values that anchor nowhere and so cannot be
    ///   redacted (neither is ever presented as clean), or
    ///   LDAServiceError.noReadableSources for an empty input list.
    public static func anonymizeSession(
        inputs: [URL],
        createdAtISO8601: String,
        llmModelPath: String? = nil,
        seedMapping: Mapping? = nil
    ) throws -> SessionAnonymizeResult {
        guard !inputs.isEmpty else {
            throw LDAServiceError.noReadableSources
        }

        // One detector for the whole session so the model loads at most once.
        let detector = makeDetector(modelPath: llmModelPath)

        var sessionDocuments: [SessionDocument] = []
        var spansByIndex: [[Span]] = []
        for input in inputs {
            let imported = try importDocument(input, extension: input.pathExtension.lowercased())
            let spans = try detector.detectText(imported.text)
            sessionDocuments.append(
                SessionDocument(
                    name: input.lastPathComponent,
                    text: imported.text,
                    spans: spans
                )
            )
            spansByIndex.append(spans)
        }

        let label = sessionLabel(for: inputs)
        let result = SessionTokenizer.tokenize(
            documents: sessionDocuments,
            sourceLabel: label,
            createdAtISO8601: createdAtISO8601,
            seedMapping: seedMapping
        )

        let outputs = zip(inputs.indices, result.documents).map { index, document in
            SessionDocumentOutput(
                sourceURL: inputs[index],
                redactedMarkdown: document.tokenizedText,
                entityCount: spansByIndex[index].count,
                entities: spansByIndex[index]
            )
        }
        return SessionAnonymizeResult(documents: outputs, mapping: result.mapping)
    }

    /// Restore pasted AI output text against a saved mapping sidecar.
    ///
    /// This is the bring-back half of the round-trip: the user pastes what the
    /// external AI returned, and the tokens restore in place. Orphans and
    /// suspect (mangled) placeholders are reported, never guessed.
    public static func restoreText(
        _ text: String,
        mapping: URL,
        protection: MappingProtection
    ) throws -> RestoreResult {
        let loaded = try MappingStore.load(from: mapping, protection: protection)
        return Restorer.restore(text: text, mapping: loaded)
    }

    /// The session label recorded as the shared mapping's sourceFile: the
    /// first document's name plus the count of companions.
    private static func sessionLabel(for inputs: [URL]) -> String {
        guard let first = inputs.first else { return "session" }
        return inputs.count == 1
            ? first.lastPathComponent
            : "\(first.lastPathComponent) (+\(inputs.count - 1) more)"
    }
}
