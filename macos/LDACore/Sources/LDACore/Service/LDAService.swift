//
//  LDAService.swift
//  LDACore
//
//  The service facade: the single entry point used by every edge (CLI, MCP,
//  app UI). It composes the engine, IO, and security layers into the three
//  product operations: anonymize, restore, detect.
//
//  Phase boundary (V1, deterministic-only): the LLM seam is
//  SpanMerger.merge(deterministic:, llm: []) with an EMPTY llm list. Phase 2
//  later just fills that list; nothing else in this facade changes.
//
//  Purity: this facade never reads the clock. createdAtISO8601 is supplied by
//  the caller (CLI/MCP edge) so the facade stays deterministic and testable.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - Results

/// The outcome of an anonymize run.
public struct AnonymizeResult: Sendable {
    /// The edit surface: a docx-run-preserving redacted .docx for docx input, a
    /// companion .docx/.txt for pdf input, or a redacted .txt for text input.
    public var redactedFileURL: URL
    /// The encrypted mapping sidecar (<redactedBaseName>.ldamap).
    public var mappingFileURL: URL
    /// A boxes-over-PII review PDF, present only when the input was a PDF.
    public var visualPdfURL: URL?
    /// How many entities were tokenized.
    public var entityCount: Int
    /// The accepted spans (post-merge) that were tokenized.
    public var entities: [Span]
    /// How many image-origin regions were redacted (signatures, stamps). 0 unless
    /// the input was a PDF with an image-PII channel pass.
    public var imageRedactionCount: Int

    public init(
        redactedFileURL: URL,
        mappingFileURL: URL,
        visualPdfURL: URL?,
        entityCount: Int,
        entities: [Span],
        imageRedactionCount: Int = 0
    ) {
        self.redactedFileURL = redactedFileURL
        self.mappingFileURL = mappingFileURL
        self.visualPdfURL = visualPdfURL
        self.entityCount = entityCount
        self.entities = entities
        self.imageRedactionCount = imageRedactionCount
    }
}

/// The outcome of a restore run.
public struct RestoreReport: Sendable {
    /// Where the restored document was written.
    public var outputURL: URL
    /// How many tokens were restored to their values.
    public var restoredCount: Int
    /// Tokens present in the edited file but absent from (or broken in) the
    /// mapping, as reported by the orphan guard.
    public var orphanTokens: [String]

    public init(outputURL: URL, restoredCount: Int, orphanTokens: [String]) {
        self.outputURL = outputURL
        self.restoredCount = restoredCount
        self.orphanTokens = orphanTokens
    }
}

// MARK: - Facade

/// The headless service facade. Stateless; every operation is a pure-ish
/// composition over the engine, IO, and security layers.
public enum LDAService {
    /// Import (by extension; PDF with no text layer falls back to Vision OCR),
    /// run deterministic detection, merge with an empty llm list, tokenize,
    /// write the redacted edit surface (DocxRedactor.redact for .docx,
    /// CompanionWriter for text/pdf), write a visual redacted PDF when the input
    /// is a PDF, and save the encrypted mapping sidecar next to outputDir.
    ///
    /// - Parameters:
    ///   - input: the source document.
    ///   - outputDir: directory to write the edit surface, sidecar, and review PDF.
    ///   - protection: how to encrypt the mapping sidecar at rest.
    ///   - createdAtISO8601: caller-supplied creation timestamp (keeps this pure).
    ///   - llmModelPath: optional absolute path to the v2 GGUF model. When nil the
    ///     llm span list stays empty and behavior is identical to the
    ///     deterministic-only V1 path. When non-nil and the file exists, an
    ///     LLMExtractor backed by an LLMEngine loaded from this path fills the
    ///     list; any load or extraction failure degrades gracefully to empty.
    public static func anonymize(
        input: URL,
        outputDir: URL,
        protection: MappingProtection,
        createdAtISO8601: String,
        llmModelPath: String? = nil
    ) throws -> AnonymizeResult {
        let ext = input.pathExtension.lowercased()
        let baseName = input.deletingPathExtension().lastPathComponent

        // Ensure the output directory exists so a caller can point at a fresh
        // path without having to create it first.
        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )

        // Detect entities once, then tokenize. The tokenized text and the mapping
        // drive both the edit surface and the mapping sidecar. The detect closure
        // is declared at function scope so a later image-PII pass (Task 6) can
        // reuse the already-loaded engine without loading the model a second time.
        let imported = try importDocument(input, extension: ext)
        let detect = makeDetector(modelPath: llmModelPath)
        let spans = detect(imported.text)
        let tokenized = Tokenizer.tokenize(
            text: imported.text,
            spans: spans,
            sourceFile: input.lastPathComponent,
            createdAtISO8601: createdAtISO8601
        )

        let redactedFileURL: URL
        var visualPdfURL: URL?

        switch ext {
        case "docx":
            redactedFileURL = outputDir.appendingPathComponent("\(baseName)_redacted.docx")
            let replacements = buildReplacements(
                spans: spans,
                mapping: tokenized.mapping
            )
            try DocxRedactor.redact(
                original: input,
                replacements: replacements,
                to: redactedFileURL
            )

        case "pdf":
            // PDF is never edited in place: write a fresh tokenized companion as
            // the edit surface, plus a boxes-over-PII review PDF.
            redactedFileURL = outputDir.appendingPathComponent("\(baseName)_redacted.txt")
            try CompanionWriter.writeText(tokenized.tokenizedText, to: redactedFileURL)

            let pairs = surfaceTokenPairs(mapping: tokenized.mapping)
            let boxes: [RedactionBox] = imported.isScanned
                ? PdfOCRImporter.ocrBoxes(in: input, matching: pairs)
                : PdfImporter.redactionBoxes(in: input, surfaceTexts: pairs)

            let reviewURL = outputDir.appendingPathComponent("\(baseName)_review.pdf")
            try PdfRedactor.renderRedactedPDF(original: input, boxes: boxes, to: reviewURL)
            visualPdfURL = reviewURL

        default:
            // Plain text and any other text-shaped input: the redacted .txt is the
            // edit surface.
            redactedFileURL = outputDir.appendingPathComponent("\(baseName)_redacted.txt")
            try CompanionWriter.writeText(tokenized.tokenizedText, to: redactedFileURL)
        }

        // Persist the encrypted mapping sidecar next to the edit surface, keyed by
        // the redacted file's base name.
        let redactedBaseName = redactedFileURL.deletingPathExtension().lastPathComponent
        let mappingFileURL = outputDir.appendingPathComponent("\(redactedBaseName).ldamap")
        try MappingStore.save(tokenized.mapping, to: mappingFileURL, protection: protection)

        return AnonymizeResult(
            redactedFileURL: redactedFileURL,
            mappingFileURL: mappingFileURL,
            visualPdfURL: visualPdfURL,
            entityCount: spans.count,
            entities: spans,
            imageRedactionCount: 0
        )
    }

    /// Load the mapping, import the edited redacted file, restore tokens to
    /// values (DocxRedactor.restore for .docx, Restorer for text), and write the
    /// output.
    public static func restore(
        editedRedacted: URL,
        mapping: URL,
        protection: MappingProtection,
        output: URL
    ) throws -> RestoreReport {
        let loadedMapping = try MappingStore.load(from: mapping, protection: protection)
        let ext = editedRedacted.pathExtension.lowercased()

        if ext == "docx" {
            // Restore on the docx runs, then re-import the restored docx to surface
            // any orphan tokens the user left behind.
            let tokenToValue = Dictionary(
                uniqueKeysWithValues: loadedMapping.entries.values.map { ($0.token, $0.value) }
            )
            try DocxRedactor.restore(
                redactedDocx: editedRedacted,
                tokenToValue: tokenToValue,
                to: output
            )
            let restoredText = try DocxImporter().importDocument(output).text
            let report = Restorer.restore(text: restoredText, mapping: loadedMapping)
            return RestoreReport(
                outputURL: output,
                restoredCount: report.restoredCount,
                orphanTokens: report.orphanTokens
            )
        }

        // Text edit surface: restore the tokens and write the output as UTF-8.
        let imported = try importDocument(editedRedacted, extension: ext)
        let report = Restorer.restore(text: imported.text, mapping: loadedMapping)
        try TextDocumentIO.exportText(report.text, to: output)
        return RestoreReport(
            outputURL: output,
            restoredCount: report.restoredCount,
            orphanTokens: report.orphanTokens
        )
    }

    /// Detect entities only. Imports the document and runs deterministic
    /// detection merged with an empty llm list. Performs no writes.
    ///
    /// - Parameters:
    ///   - input: the source document.
    ///   - llmModelPath: optional absolute path to the v2 GGUF model. When nil the
    ///     llm span list stays empty and behavior is identical to the
    ///     deterministic-only V1 path. When non-nil and the file exists, an
    ///     LLMExtractor backed by an LLMEngine loaded from this path fills the
    ///     list; any load or extraction failure degrades gracefully to empty.
    public static func detect(
        input: URL,
        llmModelPath: String? = nil
    ) throws -> [Span] {
        let imported = try importDocument(input, extension: input.pathExtension.lowercased())
        return makeDetector(modelPath: llmModelPath)(imported.text)
    }

    // MARK: - Private helpers

    /// Build a detection closure that loads the LLM engine at most once and reuses
    /// it for every call (main text pass and image-PII pass). When modelPath is nil
    /// or the model fails to load, detection is deterministic-only and never throws.
    private static func makeDetector(modelPath: String?) -> (String) -> [Span] {
        let extractor: LLMExtractor? = {
            guard let modelPath, FileManager.default.fileExists(atPath: modelPath) else { return nil }
            guard let engine = try? LLMEngine(config: .init(modelPath: modelPath)) else { return nil }
            return LLMExtractor(completer: engine)
        }()
        return { text in
            let llm: [Span]
            if let extractor {
                llm = (try? extractor.extract(from: text)) ?? []
            } else {
                llm = []
            }
            return SpanMerger.merge(deterministic: DeterministicEngine().detect(text), llm: llm)
        }
    }

    /// Import a document by file extension. PDF with no usable text layer falls
    /// back to Vision OCR. Unknown extensions are treated as plain text so the
    /// text importer's own unreadable error surfaces for genuinely bad inputs.
    private static func importDocument(
        _ url: URL,
        extension ext: String
    ) throws -> ImportedDocument {
        switch ext {
        case "docx":
            return try DocxImporter().importDocument(url)
        case "pdf":
            let imported = try PdfImporter().importDocument(url)
            guard imported.isScanned else { return imported }
            return try PdfOCRImporter().importDocument(url)
        default:
            return try TextDocumentIO().importDocument(url)
        }
    }

    /// Map each accepted span to a Replacement by looking up its token via the
    /// tokenizer mapping (one token per distinct surface text).
    private static func buildReplacements(
        spans: [Span],
        mapping: Mapping
    ) -> [Replacement] {
        let tokenBySurface = Dictionary(
            mapping.entries.values.map { ($0.surfaceText, $0.token) },
            uniquingKeysWithFirst: ()
        )
        return spans.compactMap { span in
            guard let token = tokenBySurface[span.text] else { return nil }
            return Replacement(span: span, token: token)
        }
    }

    /// The (surfaceText, token) pairs used to locate visual redaction boxes.
    private static func surfaceTokenPairs(
        mapping: Mapping
    ) -> [(text: String, token: String)] {
        mapping.entries.values.map { (text: $0.surfaceText, token: $0.token) }
    }
}

// MARK: - Dictionary helper

private extension Dictionary {
    /// Builds a dictionary from key/value pairs, keeping the first value seen for
    /// any duplicate key instead of trapping like the standard initializer does.
    init(_ pairs: [(Key, Value)], uniquingKeysWithFirst: Void) {
        self.init()
        for (key, value) in pairs where self[key] == nil {
            self[key] = value
        }
    }
}
