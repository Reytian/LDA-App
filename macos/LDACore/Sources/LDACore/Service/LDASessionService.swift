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
    /// How many detected occurrences the caller's excludedTypes left visible
    /// in this document. Always 0 when no exclusion was supplied.
    public var excludedEntityCount: Int

    public init(
        sourceURL: URL,
        redactedMarkdown: String,
        entityCount: Int,
        entities: [Span],
        excludedEntityCount: Int = 0
    ) {
        self.sourceURL = sourceURL
        self.redactedMarkdown = redactedMarkdown
        self.entityCount = entityCount
        self.entities = entities
        self.excludedEntityCount = excludedEntityCount
    }
}

/// The outcome of a session anonymize: every document's intermediate plus the
/// ONE shared mapping that restores the whole set.
public struct SessionAnonymizeResult: Sendable {
    public var documents: [SessionDocumentOutput]
    public var mapping: Mapping
    /// Seams the session seam pass could not repair, as semantic values.
    ///
    /// Empty in every normal run. A non-empty list means a redacted site in
    /// one of these documents would restore to a DIFFERENT entity than the
    /// one protected there, so the caller must show it: the redacted files
    /// and the sidecar are still written, and nothing downstream can tell
    /// the mis-restore from a correct one.
    public var seamIssues: [SessionSeamIssue]
    /// Established English lines used by command-line and MCP integrations.
    public var unresolvedSeams: [String] {
        seamIssues.map(\.englishDescription)
    }

    public init(
        documents: [SessionDocumentOutput],
        mapping: Mapping,
        seamIssues: [SessionSeamIssue] = []
    ) {
        self.documents = documents
        self.mapping = mapping
        self.seamIssues = seamIssues
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
    ///   - llmModelPath: optional GGUF path; nil stays deterministic-only. A
    ///     path whose model cannot run is refused (modelUnavailable), never
    ///     quietly downgraded to deterministic-only.
    ///   - seedMapping: optional starting mapping (a client profile's stored
    ///     mapping) whose identities the session keeps using. A seed built in
    ///     a different style contributes restore entries only; the session
    ///     mints fresh replacements in its own style for those surfaces.
    ///   - style: how replacements are rendered across the whole session.
    ///   - excludedTypes: entity types left visible in every document (the
    ///     caller's review step). Per-entity exclusion is single-document by
    ///     construction and lives on anonymize, not here.
    /// - Returns: the per-document intermediates, the shared mapping, and
    ///   unresolvedSeams: any site the seam pass could not stop from
    ///   restoring to the wrong entity. That list is a correctness warning,
    ///   not a diagnostic, and callers must put it in front of the user.
    /// - Throws: DocumentIOError for unreadable inputs,
    ///   LDAServiceError.modelUnavailable when a requested model cannot run,
    ///   LDAServiceError.incompleteExtraction when the LLM could not fully
    ///   scan a document, LDAServiceError.unanchoredEntities when it scanned
    ///   everything but reported values that anchor nowhere and so cannot be
    ///   redacted (neither is ever presented as clean), or
    ///   LDAServiceError.noReadableSources for an empty input list.
    public static func anonymizeSession(
        inputs: [URL],
        createdAtISO8601: String,
        llmModelPath: String? = nil,
        seedMapping: Mapping? = nil,
        style: SubstitutionStyle = .token,
        excludedTypes: Set<EntityType> = []
    ) throws -> SessionAnonymizeResult {
        guard !inputs.isEmpty else {
            throw LDAServiceError.noReadableSources
        }

        // One detector for the whole session so the model loads at most once.
        let detector = try makeDetector(modelPath: llmModelPath)

        // Excluded types are dropped per document BEFORE the session-wide
        // sweep below, whose needles derive from these filtered spans, so an
        // excluded type cannot re-enter through the cross-document rescan.
        let exclusion = SpanExclusion(excludedTypes: excludedTypes, bodyFilter: nil)
        var sessionDocuments: [SessionDocument] = []
        var excludedCounts: [Int] = []
        for input in inputs {
            let imported = try importDocument(input, extension: input.pathExtension.lowercased())
            let review = exclusion.resolve(bodySpans: try detector.detectText(imported.text))
            let spans = review.keptBodySpans
            excludedCounts.append(review.excludedOccurrenceCount)
            sessionDocuments.append(
                SessionDocument(
                    name: input.lastPathComponent,
                    text: imported.text,
                    spans: spans
                )
            )
        }

        // Session-wide recall sweep: a PERSON or COMPANY confirmed anywhere in
        // the session (including defined short names swept per document) is
        // rescanned in EVERY document, so the shared mapping never lets a
        // party detected in one document leak from another. Blocking stays
        // per document; only the needle surfaces cross documents.
        let sessionEntities = sessionDocuments.flatMap { document in
            document.spans.filter { $0.type == .person || $0.type == .company }
        }
        sessionDocuments = sessionDocuments.map { document in
            SessionDocument(
                name: document.name,
                text: document.text,
                spans: EntityRescan.expand(
                    document.spans,
                    in: document.text,
                    knownEntities: sessionEntities
                )
            )
        }

        // No replacement may swallow a newline or a tab, on any format, and a
        // session intermediate is Markdown: a replacement that eats a newline
        // deletes a line from the edit surface handed to the AI, and hides the
        // value on the far side of the break inside a placeholder named after
        // the value on the near side. Split such spans into parts, each with
        // its own token, mirroring LDAService.anonymize. The UNSPLIT documents
        // stay in hand for the alias pass below, because a break never divides
        // a name surface.
        let splitDocuments = SpanSplitter.splitAtBreaks(sessionDocuments)
        let spansByIndex = splitDocuments.map { $0.spans }

        let label = sessionLabel(for: inputs)
        let result = SessionTokenizer.tokenize(
            documents: splitDocuments,
            sourceLabel: label,
            createdAtISO8601: createdAtISO8601,
            seedMapping: seedMapping,
            style: style
        )
        try OutboundReleasePreflight.requireSafe(
            texts: result.documents.map(\.tokenizedText),
            mapping: result.mapping
        )

        // Record the full-name/short-name grouping found in each document in
        // the ONE shared mapping. Tokens and values are untouched, so restore
        // stays byte-identical at every site. Pairs are derived from the
        // pre-split spans because a break never divides a name surface, and
        // the alias pass must see whole names.
        var mapping = result.mapping
        for document in sessionDocuments {
            mapping = EntityRescan.linkAliases(
                in: mapping,
                pairs: EntityRescan.aliasPairs(in: document.text, confirmed: document.spans)
            )
        }

        let outputs = zip(inputs.indices, result.documents).map { index, document in
            SessionDocumentOutput(
                sourceURL: inputs[index],
                redactedMarkdown: document.tokenizedText,
                entityCount: spansByIndex[index].count,
                entities: spansByIndex[index],
                excludedEntityCount: excludedCounts[index]
            )
        }
        // Carry the seam pass's verdict out with the result. A seam it could
        // not repair means one of these documents restores a redacted site to
        // the wrong entity, and the output files look perfectly ordinary, so
        // dropping this here would make the failure silent.
        return SessionAnonymizeResult(
            documents: outputs,
            mapping: mapping,
            seamIssues: result.seamIssues
        )
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
