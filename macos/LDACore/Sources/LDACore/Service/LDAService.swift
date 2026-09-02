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
    /// A boxes-over-PII redacted PNG, present only when the input was a
    /// standalone image (png / jpg / jpeg). The boxes are destructive, so
    /// this artifact is NOT restorable; the paired redacted text companion
    /// is the round-trip surface.
    public var redactedImageURL: URL?
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
    /// How many red-region seal CANDIDATE boxes were merged into the redacted
    /// image's coverage. Candidates only, never certain seal detections; the
    /// UI can surface "N seal candidates boxed". Always 0 for non-image input
    /// and when includeSealCandidates is false.
    public var sealCandidateCount: Int
    /// How many detected BODY spans the caller's exclusions (spanFilter and
    /// excludedTypes) dropped before tokenization. Those values stay visible
    /// in the redacted output by the caller's choice. Always 0 when no
    /// exclusion was supplied.
    public var excludedEntityCount: Int

    public init(
        redactedFileURL: URL,
        mappingFileURL: URL,
        visualPdfURL: URL?,
        entityCount: Int,
        entities: [Span],
        imageRedactionCount: Int = 0,
        embeddedMediaCount: Int = 0,
        unboxedTokenCount: Int = 0,
        sealCandidateCount: Int = 0,
        redactedImageURL: URL? = nil,
        excludedEntityCount: Int = 0
    ) {
        self.redactedFileURL = redactedFileURL
        self.mappingFileURL = mappingFileURL
        self.visualPdfURL = visualPdfURL
        self.redactedImageURL = redactedImageURL
        self.entityCount = entityCount
        self.entities = entities
        self.imageRedactionCount = imageRedactionCount
        self.embeddedMediaCount = embeddedMediaCount
        self.unboxedTokenCount = unboxedTokenCount
        self.sealCandidateCount = sealCandidateCount
        self.excludedEntityCount = excludedEntityCount
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
    /// Asterisk style only: masked forms shared by several entities. Their
    /// sites were left verbatim because substituting one would be a guess.
    public var ambiguousReplacements: [String]

    public init(
        outputURL: URL,
        restoredCount: Int,
        orphanTokens: [String],
        suspectPlaceholders: [String] = [],
        ambiguousReplacements: [String] = []
    ) {
        self.outputURL = outputURL
        self.restoredCount = restoredCount
        self.orphanTokens = orphanTokens
        self.suspectPlaceholders = suspectPlaceholders
        self.ambiguousReplacements = ambiguousReplacements
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
    /// The document was fully scanned, but values the model reported are present
    /// in the source and could not be anchored there, even after repairing CJK
    /// script-boundary space drift. They were detected and will survive into the
    /// output, so the document is NOT guaranteed PII-free and must not be
    /// presented as cleanly anonymized (LJE-001). This is a distinct failure
    /// from truncation: the text was read, the removal is what failed. Values
    /// the model invented do not reach here, since nothing in the document can
    /// leak them. `unlocatableEntityCount` is how many distinct values were
    /// affected.
    case unanchoredEntities(unlocatableEntityCount: Int)
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
    ///   - style: how replacements are rendered in the redacted output. The
    ///     default .token keeps the historical "{TYPE_N}" behavior unchanged.
    ///     Supplementary channels (DOCX non-body parts, the PDF image-PII
    ///     channel) still mint brace tokens in every style; their entries live
    ///     in the same mapping and restore correctly, they just do not carry
    ///     the pseudonym AI-robustness benefit.
    ///   - includeSealCandidates: standalone image input only. When true (the
    ///     default), red-region seal CANDIDATE boxes are merged into the
    ///     redacted image's coverage; candidates only, never certain seal
    ///     detections. Ignored for every other input format.
    ///   - spanFilter: the caller's review step over BODY spans: return false
    ///     to leave a detected value visible. Consulted for every detected
    ///     body span in detection order, before the type test, so a caller may
    ///     also use it to observe the detection set. Nil keeps every span.
    ///   - excludedTypes: entity types left visible on EVERY channel (body,
    ///     docx headers, footers, notes, comments, and the image-PII pass).
    public static func anonymize(
        input: URL,
        outputDir: URL,
        protection: MappingProtection,
        createdAtISO8601: String,
        llmModelPath: String? = nil,
        style: SubstitutionStyle = .token,
        includeSealCandidates: Bool = true,
        spanFilter: ((Span) -> Bool)? = nil,
        excludedTypes: Set<EntityType> = []
    ) throws -> AnonymizeResult {
        let ext = input.pathExtension.lowercased()
        let baseName = input.deletingPathExtension().lastPathComponent

        // Detect entities once, then tokenize. The tokenized text and the mapping
        // drive both the edit surface and the mapping sidecar. The detector is
        // declared at function scope so a later image-PII pass (Task 6) can reuse
        // the already-loaded engine without loading the model a second time. The
        // primary text pass throws if a segment could not be fully scanned, so the
        // document is never written out as cleanly anonymized on a partial scan.
        //
        // A standalone image is extracted ONCE up front: its joined OCR text
        // feeds the same detection pipeline as every other format, and the
        // per-line geometry is reused by the image redactor below without a
        // second OCR pass.
        let imageExtraction: ImageExtraction? = shouldTreatAsImage(input, extension: ext)
            ? try ImageTextExtractor().extract(input)
            : nil
        let imported: ImportedDocument
        if let imageExtraction {
            imported = ImportedDocument(
                text: imageExtraction.text,
                format: .image,
                isScanned: true,
                pageCount: 1
            )
        } else {
            imported = try importDocument(input, extension: ext)
        }
        let detector = makeDetector(modelPath: llmModelPath)
        // The caller's review step: drop excluded spans BEFORE splitting,
        // tokenization, and alias linking, so an excluded value never mints a
        // token or enters the mapping. Types are excluded on every channel;
        // the per-span filter is body-only (see SpanExclusion).
        let exclusion = SpanExclusion(excludedTypes: excludedTypes, bodyFilter: spanFilter)
        let candidates = try detector.detectText(imported.text)
        let detected = exclusion.filterBody(candidates)
        let excludedEntityCount = candidates.count - detected.count
        let detectSupplementary: (String) -> [Span] = { text in
            exclusion.filterSupplementary(detector.detectForImages(text))
        }
        // DOCX replacement happens run by run inside paragraphs, and the
        // paragraph newline, line break, and tab characters exist in no run,
        // so a span crossing one cannot round-trip. Split such spans into
        // per-run parts (each gets its own token and restores within its own
        // run structure).
        let spans = ext == "docx" && imageExtraction == nil
            ? SpanSplitter.splitAtBreaks(detected, in: imported.text)
            : detected
        var tokenized = try Tokenizer.requireSafeForRelease(
            Tokenizer.tokenize(
                text: imported.text,
                spans: spans,
                sourceFile: input.lastPathComponent,
                createdAtISO8601: createdAtISO8601,
                style: style
            )
        )
        // Record the full-name/short-name grouping (全称/简称归并) in the
        // mapping: each defined short name's entry points at its canonical
        // entry's token. Tokens and values are untouched, so restore stays
        // byte-identical at every site. Pairs are derived from the pre-split
        // spans because a docx line-break split never divides a name surface.
        tokenized.mapping = EntityRescan.linkAliases(
            in: tokenized.mapping,
            pairs: EntityRescan.aliasPairs(in: imported.text, confirmed: detected)
        )

        // The release preflight above must finish before the destination is
        // touched. This keeps a refused asterisk export artifact-free.
        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )

        // Standalone image input produces TWO artifacts and returns early:
        //  (a) the redacted TEXT companion, the same edit surface shape as the
        //      PDF path, byte-identically restorable through the mapping; and
        //  (b) the redacted IMAGE, a PNG with opaque boxes over every
        //      observation that carries a replaced range. The boxes are
        //      destructive, so (b) is never a restore surface. Whole
        //      observation boxes are covered: over-covering is acceptable,
        //      under-covering is a leak. A replaced range the geometry cannot
        //      locate is counted in unboxedTokenCount, never dropped.
        if let extraction = imageExtraction {
            let companionURL = outputDir.appendingPathComponent("\(baseName)_redacted.txt")
            try CompanionWriter.writeText(tokenized.tokenizedText, to: companionURL)

            let coverage = ImageRedactor.coverage(
                lines: extraction.lines,
                replacedRanges: spans.map { $0.start..<$0.end }
            )
            // Seal candidate channel: red-region clusters in the source
            // raster are boxed as CANDIDATES alongside the OCR coverage.
            // Over-covering is acceptable; nothing here claims certain seal
            // detection. The flag is threaded for later UI wiring.
            let sealCandidates = includeSealCandidates
                ? try SealCandidateDetector.candidates(
                    in: ImageTextExtractor.loadImage(at: input)
                )
                : []
            let imageURL = outputDir.appendingPathComponent("\(baseName)_redacted.png")
            let render = try ImageRedactor.renderRedactedPNG(
                originalImageAt: input,
                covering: coverage.coveredLines,
                sealCandidates: sealCandidates,
                to: imageURL
            )

            let companionBaseName = companionURL.deletingPathExtension().lastPathComponent
            let sidecarURL = outputDir.appendingPathComponent("\(companionBaseName).ldamap")
            try MappingStore.save(tokenized.mapping, to: sidecarURL, protection: protection)

            return AnonymizeResult(
                redactedFileURL: companionURL,
                mappingFileURL: sidecarURL,
                visualPdfURL: nil,
                entityCount: spans.count,
                entities: spans,
                imageRedactionCount: render.paintedBoxCount,
                embeddedMediaCount: 0,
                unboxedTokenCount: coverage.unlocatedRangeCount,
                sealCandidateCount: render.sealCandidateCount,
                redactedImageURL: imageURL,
                excludedEntityCount: excludedEntityCount
            )
        }

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
                nonBody: (mapping: tokenized.mapping, detect: detectSupplementary)
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
                        detect: detectSupplementary
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
            unboxedTokenCount: unboxedTokenCount,
            excludedEntityCount: excludedEntityCount
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
        let ext = editedRedacted.pathExtension.lowercased()
        // A redacted image is not an edit surface: the opaque boxes destroy
        // the covered pixels, so restoring one is impossible by design.
        // Refuse clearly, before any mapping IO or Keychain prompt, instead
        // of decoding raster bytes as text and producing nonsense.
        if shouldTreatAsImage(editedRedacted, extension: ext) {
            throw DocumentIOError.unsupportedFormat(
                "\(editedRedacted.lastPathComponent) is an image, and a redacted "
                    + "image cannot be restored: its boxes permanently cover the "
                    + "pixels. Restore the redacted text companion (.txt) that "
                    + "was produced alongside it."
            )
        }
        let loadedMapping = try MappingStore.load(from: mapping, protection: protection)

        if ext == "docx" {
            // Report against one PRE-restore view of every visible text part.
            // A post-restore scan cannot count successful substitutions, and a
            // body-only scan omits headers, footers, notes, and comments.
            let preRestoreText = try DocxParts.restoreReportText(from: editedRedacted)
            let report = Restorer.restore(text: preRestoreText, mapping: loadedMapping)

            if loadedMapping.style == .token {
                let tokenToValue = Dictionary(
                    uniqueKeysWithValues: loadedMapping.entries.values.map { ($0.token, $0.value) }
                )
                try DocxRedactor.restore(
                    redactedDocx: editedRedacted,
                    tokenToValue: tokenToValue,
                    to: output
                )
                return RestoreReport(
                    outputURL: output,
                    restoredCount: report.restoredCount,
                    orphanTokens: report.orphanTokens,
                    suspectPlaceholders: report.suspectPlaceholders,
                    ambiguousReplacements: report.ambiguousReplacements
                )
            }

            // The literal rewrite follows the same restore plan as the report,
            // so an ambiguous asterisk mask is left verbatim exactly where the
            // package-wide report flags it.
            try DocxRedactor.restoreLiteral(
                redactedDocx: editedRedacted,
                plan: Restorer.literalRestorePlan(
                    for: loadedMapping,
                    refusingReplacements: Set(report.ambiguousReplacements)
                ),
                to: output
            )
            return RestoreReport(
                outputURL: output,
                restoredCount: report.restoredCount,
                orphanTokens: report.orphanTokens,
                suspectPlaceholders: report.suspectPlaceholders,
                ambiguousReplacements: report.ambiguousReplacements
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
            suspectPlaceholders: report.suspectPlaceholders,
            ambiguousReplacements: report.ambiguousReplacements
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

        /// Primary detection over the main document text. Throws when the
        /// result cannot be presented as cleanly anonymized (LJE-001), so a
        /// document that is not guaranteed PII-free is never written out as
        /// clean. Two distinct failures qualify and each gets its own error, so
        /// the caller's message names the one that happened.
        ///
        /// Truncation is checked first: when a segment was never scanned the
        /// unanchored count is drawn from an incomplete sample and reporting it
        /// would be misleading.
        ///
        /// After the merge, the confirmed spans seed the full-document literal
        /// rescan (EntityRescan.expand): repeat mentions of every confirmed
        /// PERSON and COMPANY surface, and of the document's defined short
        /// names bound to them, are swept in with pure string search. This is
        /// engine-level so the CLI, MCP, and app UI all benefit identically.
        func detectText(_ text: String) throws -> [Span] {
            let llm: [Span]
            if let extractor {
                let result = try extractor.extractDetailed(from: text)
                guard result.fullyCovered else {
                    throw LDAServiceError.incompleteExtraction(
                        incompleteSegmentCount: result.incompleteSegmentCount
                    )
                }
                guard result.fullyAnchored else {
                    throw LDAServiceError.unanchoredEntities(
                        unlocatableEntityCount: result.unlocatableEntityCount
                    )
                }
                llm = result.spans
            } else {
                llm = []
            }
            let merged = SpanMerger.merge(deterministic: DeterministicEngine().detect(text), llm: llm)
            return EntityRescan.expand(merged, in: text)
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

    /// True when the file should route through the standalone image pipeline:
    /// an image extension (png / jpg / jpeg) always does; any OTHER extension
    /// outside docx and pdf is settled by magic bytes, so a PNG that reaches
    /// disk under a .txt name (the vault stores staged files by normalized
    /// format) is OCR'd instead of being decoded as Latin-1 mojibake. The
    /// rule itself lives on ImageTextExtractor so the GUI edge shares it.
    internal static func shouldTreatAsImage(_ url: URL, extension ext: String) -> Bool {
        ImageTextExtractor.shouldTreatAsImage(url, extension: ext)
    }

    /// Import a document by file extension. A PDF with no usable text layer at
    /// all falls back to whole-document Vision OCR; a hybrid PDF keeps its
    /// text layer and splices page-scoped OCR text into the scanned pages, so
    /// a scanned exhibit inside a digital contract still reaches detection.
    /// A standalone image (by extension or magic bytes) is OCR'd through
    /// ImageTextExtractor. Unknown extensions are treated as plain text so
    /// the text importer's own unreadable error surfaces for bad inputs.
    ///
    /// Internal (not private) so that LDAFillService.swift can call it directly
    /// for profile source import, avoiding duplicate logic.
    internal static func importDocument(
        _ url: URL,
        extension ext: String
    ) throws -> ImportedDocument {
        if shouldTreatAsImage(url, extension: ext) {
            return try ImageTextExtractor().importDocument(url)
        }
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
