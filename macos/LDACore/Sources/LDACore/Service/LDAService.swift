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
    /// How many embedded media files (word/media/...) were copied verbatim into
    /// a redacted DOCX without being scanned for PII. Wet-ink signature scans
    /// and stamps live there; a non-zero count must be surfaced to the user as
    /// a warning. Always 0 for non-DOCX input.
    public var embeddedMediaCount: Int
    /// How many tokenized values could not be given a redaction box in the
    /// review PDF. Always 0 for non-PDF input.
    ///
    /// A non-zero count MUST be surfaced to the user as a warning, for the same
    /// reason as embeddedMediaCount: the value IS tokenized in the edit surface
    /// and the mapping, so the round trip is correct, but the review PDF still
    /// shows it. A lawyer who forwards that PDF believing it redacted is the
    /// failure this count exists to prevent. Flag, never guess: no box is
    /// invented for a value whose position could not be established.
    public var unboxedTokenCount: Int

    public init(
        redactedFileURL: URL,
        mappingFileURL: URL,
        visualPdfURL: URL?,
        entityCount: Int,
        entities: [Span],
        imageRedactionCount: Int = 0,
        embeddedMediaCount: Int = 0,
        unboxedTokenCount: Int = 0
    ) {
        self.redactedFileURL = redactedFileURL
        self.mappingFileURL = mappingFileURL
        self.visualPdfURL = visualPdfURL
        self.entityCount = entityCount
        self.entities = entities
        self.imageRedactionCount = imageRedactionCount
        self.embeddedMediaCount = embeddedMediaCount
        self.unboxedTokenCount = unboxedTokenCount
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
    /// Near-miss placeholder shapes flagged by the forensics scan (an external
    /// AI may have mangled a placeholder); never substituted, only reported.
    public var suspectPlaceholders: [String]

    public init(
        outputURL: URL,
        restoredCount: Int,
        orphanTokens: [String],
        suspectPlaceholders: [String] = []
    ) {
        self.outputURL = outputURL
        self.restoredCount = restoredCount
        self.orphanTokens = orphanTokens
        self.suspectPlaceholders = suspectPlaceholders
    }
}

// MARK: - Errors

/// Errors the service surfaces to its callers (CLI, MCP, app UI).
public enum LDAServiceError: Error, Equatable {
    /// The on-device LLM could not fully scan the document: at least one segment's
    /// completion was truncated at the generation token cap and could not be
    /// recovered by a larger-cap retry or by splitting. The document is therefore
    /// NOT guaranteed PII-free and must not be presented as cleanly anonymized
    /// (LJE-001). `incompleteSegmentCount` is how many segments were affected.
    case incompleteExtraction(incompleteSegmentCount: Int)
    /// restore was asked to write its output over the edited input file. The
    /// rewrite clears the destination before reading, so honoring this would
    /// destroy the user's redacted file; it must fail fast instead.
    case outputEqualsInput
    /// extractProfile was called but none of the provided source URLs could be
    /// imported as readable text. At least one readable source is required.
    case noReadableSources
    /// applyFill detected that the target document has changed since the plan
    /// was produced: a confirmed blank's offsets no longer match the current
    /// text, or a confirmed PDF field no longer exists. The user must re-plan
    /// before applying. `detail` gives a brief description of the first
    /// mismatch (e.g. "offset 10-25" for DOCX or a comma-separated list of
    /// missing field names for PDF).
    case staleTarget(detail: String)
}

// MARK: - Facade

/// The headless service facade. Stateless; every operation is a pure-ish
/// composition over the engine, IO, and security layers.
public enum LDAService {

    // MARK: - Test seam

#if DEBUG
    /// Debug-only override for building the LLM extractor. Production loads an
    /// LLMEngine from the model path. Tests install a factory returning a fake
    /// TextCompleter so the truncation and incompleteness handling can be
    /// exercised without the 2.7 GB GGUF model. The closure receives the
    /// resolved model path and returns an extractor, or nil to fall back to
    /// deterministic detection.
    ///
    /// The seam is compiled out of release builds and its storage is lock
    /// guarded; see TestSeam.
    internal static let extractorSeam = TestSeam<(String) -> LLMExtractor?>()

    internal static var makeExtractorForTesting: ((String) -> LLMExtractor?)? {
        get { extractorSeam.value }
        set { extractorSeam.value = newValue }
    }
#endif
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
        // drive both the edit surface and the mapping sidecar. The detector is
        // declared at function scope so a later image-PII pass (Task 6) can reuse
        // the already-loaded engine without loading the model a second time. The
        // primary text pass throws if a segment could not be fully scanned, so the
        // document is never written out as cleanly anonymized on a partial scan.
        let imported = try importDocument(input, extension: ext)
        let detector = makeDetector(modelPath: llmModelPath)
        let detected = try detector.detectText(imported.text)
        // DOCX replacement happens run by run inside paragraphs, and the
        // paragraph newline exists in no run, so a span crossing it cannot
        // round-trip. Split such spans into per-paragraph parts (each gets its
        // own token and restores within its own run structure).
        let spans = ext == "docx"
            ? SpanSplitter.splitAtLineBreaks(detected, in: imported.text)
            : detected
        var tokenized = Tokenizer.tokenize(
            text: imported.text,
            spans: spans,
            sourceFile: input.lastPathComponent,
            createdAtISO8601: createdAtISO8601
        )

        let redactedFileURL: URL
        var visualPdfURL: URL?
        var imageRedactionCount = 0
        var embeddedMediaCount = 0
        var unboxedTokenCount = 0

        switch ext {
        case "docx":
            redactedFileURL = outputDir.appendingPathComponent("\(baseName)_redacted.docx")
            // Embedded media (word/media/) copies through unscanned; report the
            // count so the caller can warn about signature images and stamps.
            embeddedMediaCount = DocxParts.embeddedMediaPaths(in: input).count
            let replacements = buildReplacements(
                spans: spans,
                mapping: tokenized.mapping
            )
            // Redact the body AND every other text-bearing part (headers, footers,
            // footnotes, endnotes, comments), scrub docProps author/title metadata,
            // and neutralize external mailto:/tel: hyperlink targets. Surfaces found
            // only in a non-body part mint new tokens that are folded into the
            // mapping below so they persist in the sidecar and restore correctly.
            // detectForImages is the non-throwing detector (deterministic plus
            // best-effort LLM); the throwing primary pass already gated the body.
            let nonBodyEntries = try DocxRedactor.redact(
                original: input,
                replacements: replacements,
                to: redactedFileURL,
                nonBody: (mapping: tokenized.mapping, detect: detector.detectForImages)
            )
            for entry in nonBodyEntries {
                tokenized.mapping.entries[entry.token] = entry
            }

        case "pdf":
            // PDF is never edited in place: write a fresh tokenized companion as
            // the edit surface, plus a boxes-over-PII review PDF.
            redactedFileURL = outputDir.appendingPathComponent("\(baseName)_redacted.txt")
            try CompanionWriter.writeText(tokenized.tokenizedText, to: redactedFileURL)

            // Pairs come from text-layer entries only; image-origin regions are boxed
            // separately by the image-PII channel below, not via text search.
            let pairs = surfaceTokenPairs(mapping: tokenized.mapping)
            var boxes: [RedactionBox]
            if imported.isScanned {
                boxes = PdfOCRImporter.ocrBoxes(in: input, matching: pairs)
            } else {
                boxes = PdfImporter.redactionBoxes(in: input, surfaceTexts: pairs)
                // Hybrid PDFs: the scanned pages have no text layer for the
                // selection search, so their PII is boxed via page-scoped OCR.
                if !imported.scannedPageIndexes.isEmpty {
                    boxes += PdfOCRImporter.ocrBoxes(
                        in: input,
                        matching: pairs,
                        pages: imported.scannedPageIndexes
                    )
                }
            }

            // Image-PII channel: a non-scanned PDF can still embed raster images
            // (signatures, stamps) the text layer cannot see. OCR those regions,
            // conservatively box them, and record classified PII in the mapping.
            // Fully scanned pages are excluded: their whole text already entered
            // the document text via per-page OCR and is boxed above.
            if !imported.isScanned {
                let scannedSet = Set(imported.scannedPageIndexes)
                let imagePages = PdfImageInventory.pagesWithImages(input)
                    .filter { !scannedSet.contains($0) }
                if !imagePages.isEmpty {
                    let observations = PdfOCRImporter().imageOriginObservations(in: input, pages: imagePages)
                    let resolved = ImageRedactionResolver.resolve(
                        mapping: tokenized.mapping,
                        observations: observations,
                        detect: detector.detectForImages
                    )
                    boxes += resolved.boxes
                    // Merge image-origin entries into the mapping before it is saved
                    // below. This mutation requires `tokenized` to be declared `var`.
                    for entry in resolved.newEntries {
                        tokenized.mapping.entries[entry.token] = entry
                    }
                    imageRedactionCount = resolved.imageRedactionCount
                }
            }

            // Any text-layer value that ended up with NO box is reported, not
            // papered over. The text search (including the whitespace-normalized
            // fallback) and the OCR channel have both run by this point, so a
            // token still missing from `boxes` is genuinely unlocated in the
            // page geometry and the review PDF will still show it.
            let boxedTokens = Set(boxes.map(\.token))
            unboxedTokenCount = pairs.reduce(into: Set<String>()) { unboxed, pair in
                if !boxedTokens.contains(pair.token) { unboxed.insert(pair.token) }
            }.count

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
            imageRedactionCount: imageRedactionCount,
            embeddedMediaCount: embeddedMediaCount,
            unboxedTokenCount: unboxedTokenCount
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
        // Writing the output over the edited input would delete the input
        // before it is read (the writers clear the destination first), losing
        // the user's redacted file. Refuse up front, before any IO.
        guard editedRedacted.standardizedFileURL.path != output.standardizedFileURL.path else {
            throw LDAServiceError.outputEqualsInput
        }
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
                orphanTokens: report.orphanTokens,
                suspectPlaceholders: report.suspectPlaceholders
            )
        }

        // Text edit surface: restore the tokens and write the output as UTF-8.
        let imported = try importDocument(editedRedacted, extension: ext)
        let report = Restorer.restore(text: imported.text, mapping: loadedMapping)
        try TextDocumentIO.exportText(report.text, to: output)
        return RestoreReport(
            outputURL: output,
            restoredCount: report.restoredCount,
            orphanTokens: report.orphanTokens,
            suspectPlaceholders: report.suspectPlaceholders
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
        return try makeDetector(modelPath: llmModelPath).detectText(imported.text)
    }

    // MARK: - Private helpers

    /// A detector that loads the LLM engine at most once and offers two entry
    /// points over it: the primary text pass (which surfaces incomplete scans) and
    /// the secondary image-PII pass (which stays non-throwing for the resolver).
    /// Internal (not private) so LDASessionService.swift can reuse it.
    internal struct Detector {
        let extractor: LLMExtractor?

        /// Primary detection over the main document text. Throws
        /// LDAServiceError.incompleteExtraction when the LLM could not fully scan
        /// the document, so a partial scan is never written out as clean (LJE-001).
        func detectText(_ text: String) throws -> [Span] {
            let llm: [Span]
            if let extractor {
                let result = try extractor.extractDetailed(from: text)
                guard result.fullyCovered else {
                    throw LDAServiceError.incompleteExtraction(
                        incompleteSegmentCount: result.incompleteSegmentCount
                    )
                }
                llm = result.spans
            } else {
                llm = []
            }
            return SpanMerger.merge(deterministic: DeterministicEngine().detect(text), llm: llm)
        }

        /// Secondary detection over short OCR'd image-origin text for the image-PII
        /// channel. This re-uses the loaded engine but stays non-throwing: it is a
        /// best-effort supplement to the boxed regions, and the salvage path keeps
        /// any recovered entities. Truncation here does not gate the "clean" claim,
        /// which is owned by the primary text pass above.
        func detectForImages(_ text: String) -> [Span] {
            let llm: [Span]
            if let extractor {
                llm = (try? extractor.extract(from: text)) ?? []
            } else {
                llm = []
            }
            return SpanMerger.merge(deterministic: DeterministicEngine().detect(text), llm: llm)
        }
    }

    /// Build a detector that loads the LLM engine at most once and reuses it for
    /// every call (main text pass and image-PII pass). When modelPath is nil or
    /// the model fails to load, detection is deterministic-only. The primary text
    /// pass surfaces an incomplete scan; see Detector. Internal (not private) so
    /// LDASessionService.swift can reuse it.
    internal static func makeDetector(modelPath: String?) -> Detector {
        let extractor: LLMExtractor? = {
#if DEBUG
            // An installed seam OWNS extractor construction, including the
            // decision to return nil (which means "run deterministic-only").
            // It therefore wins whether or not the model path resolves, which
            // is what lets a test drive the LLM paths with a bogus path. This
            // whole branch is absent from release builds.
            if let factory = makeExtractorForTesting {
                return factory(modelPath ?? "")
            }
#endif
            guard let modelPath, FileManager.default.fileExists(atPath: modelPath) else {
                return nil
            }
            guard let engine = try? LLMEngine(config: .init(modelPath: modelPath)) else { return nil }
            return LLMExtractor(completer: engine)
        }()
        return Detector(extractor: extractor)
    }

    /// Import a document by file extension. A PDF with no usable text layer at
    /// all falls back to whole-document Vision OCR; a hybrid PDF keeps its
    /// text layer and splices page-scoped OCR text into the scanned pages, so
    /// a scanned exhibit inside a digital contract still reaches detection.
    /// Unknown extensions are treated as plain text so the text importer's own
    /// unreadable error surfaces for genuinely bad inputs.
    ///
    /// Internal (not private) so that LDAFillService.swift can call it directly
    /// for profile source import, avoiding duplicate logic.
    internal static func importDocument(
        _ url: URL,
        extension ext: String
    ) throws -> ImportedDocument {
        switch ext {
        case "docx":
            return try DocxImporter().importDocument(url)
        case "pdf":
            var imported = try PdfImporter().importDocument(url)
            if imported.isScanned {
                return try PdfOCRImporter().importDocument(url)
            }
            guard !imported.scannedPageIndexes.isEmpty else { return imported }

            // Hybrid: re-read the per-page layers and replace the empty slots
            // with OCR text, preserving page order and the page separator.
            var layers = try PdfImporter.pageTextLayers(in: url)
            let ocrTexts = try PdfOCRImporter.pageTexts(
                in: url,
                pages: imported.scannedPageIndexes
            )
            for (pageIndex, ocrText) in ocrTexts {
                layers.texts[pageIndex] = ocrText
            }
            imported.text = layers.texts.joined(separator: "\n\n")
            return imported
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
