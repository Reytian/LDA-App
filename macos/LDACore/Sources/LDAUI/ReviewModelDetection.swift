//
//  ReviewModelDetection.swift
//  LDAUI
//
//  Extension on ReviewModel that owns all off-main-actor detection and export
//  helpers: document import (importText), the full detection pass (detect,
//  llmSpans, DetectionOutcome, LLMPassOutcome), the export worker
//  (performExport, collisionFreeBaseName, nonBodyDetector, buildReplacements,
//  tokenBySurface), and error rendering (describe).
//
//  Stored properties (@Published state, test seams) STAY in ReviewModel.swift
//  because stored properties cannot live in extensions. The methods here are
//  all nonisolated static; they access test-seam properties declared
//  nonisolated(unsafe) in ReviewModel.swift.
//
//  Access-level note: DetectionOutcome, LLMPassOutcome, and describe are
//  declared internal (not private) because private is file-scoped in Swift;
//  a private declaration in ReviewModel.swift would not be visible here.
//  They are not intended as public API.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

extension ReviewModel {

    // MARK: - Detection helpers (off the main actor)

    /// Import a document by extension. PDF with no usable text layer falls back
    /// to Vision OCR. Unknown extensions are treated as plain text.
    nonisolated static func importText(from url: URL) throws -> String {
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
    /// valid file, merge in LLM spans. An LLM failure degrades to
    /// deterministic-only spans but is REPORTED in the outcome so the UI can
    /// warn; a silent degrade would let the lawyer trust a pattern-only pass
    /// as an AI pass.
    /// The result of a detection pass plus what learning contributed.
    // internal for ReviewModelDetection.swift
    struct DetectionOutcome {
        let spans: [Span]
        let learnedApplied: Int
        let suppressed: Int
        /// True when the AI pass ran to full coverage.
        let aiRan: Bool
        /// User-facing explanation when AI was expected but failed or could
        /// not fully scan; nil when AI ran cleanly or was not attempted.
        let aiFailure: String?
        /// True when the user stopped the pass. The caller discards the
        /// outcome instead of presenting it as a completed detection.
        let cancelled: Bool
    }

    nonisolated static func detect(
        in text: String,
        useLLM: Bool,
        modelPath: String?,
        custom: [CustomPattern] = [],
        learnedRedact: [CustomPattern] = [],
        suppressKeys: Set<String> = [],
        cancel: ExtractionCancelToken? = nil,
        onProgress: ((Int, Int) -> Void)? = nil
    ) -> DetectionOutcome {
        if let delay = detectDelayForTesting {
            Thread.sleep(forTimeInterval: delay)
        }
        // Custom vocabulary and learned redactions join the deterministic list
        // with a higher priority, so a user-chosen or previously-accepted term
        // always wins overlap conflicts.
        let deterministic = DeterministicEngine().detect(text)
            + CustomPatternEngine.detect(text, patterns: custom)
            + CustomPatternEngine.detect(text, patterns: learnedRedact)
        let llm = llmSpans(
            in: text,
            useLLM: useLLM,
            modelPath: modelPath,
            cancel: cancel,
            onProgress: onProgress
        )
        if llm.cancelled {
            return DetectionOutcome(
                spans: [], learnedApplied: 0, suppressed: 0,
                aiRan: false, aiFailure: nil, cancelled: true
            )
        }
        let merged = SpanMerger.merge(
            deterministic: deterministic,
            llm: llm.spans
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

        return DetectionOutcome(
            spans: kept,
            learnedApplied: appliedValues.count,
            suppressed: suppressed,
            aiRan: llm.attempted && llm.failure == nil,
            aiFailure: llm.failure,
            cancelled: false
        )
    }

    /// The LLM contribution to a detection pass.
    // internal for ReviewModelDetection.swift
    struct LLMPassOutcome {
        /// Located fuzzy spans (possibly partial salvage on failure).
        let spans: [Span]
        /// True when the AI pass was supposed to run (enabled + model file).
        let attempted: Bool
        /// User-facing failure text, nil when the pass ran to full coverage.
        let failure: String?
        /// True when the user stopped the pass mid-run.
        let cancelled: Bool
    }

    /// Produce the LLM span list. Failures and incomplete coverage degrade to
    /// the salvaged spans but are reported, never swallowed. A user stop is
    /// reported as cancelled, never disguised as a failure.
    nonisolated static func llmSpans(
        in text: String,
        useLLM: Bool,
        modelPath: String?,
        cancel: ExtractionCancelToken? = nil,
        onProgress: ((Int, Int) -> Void)? = nil
    ) -> LLMPassOutcome {
        guard useLLM, let modelPath else {
            return LLMPassOutcome(spans: [], attempted: false, failure: nil, cancelled: false)
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            return LLMPassOutcome(spans: [], attempted: false, failure: nil, cancelled: false)
        }
        do {
            let extractor: LLMExtractor
            if let factory = llmExtractorFactoryForTesting {
                extractor = factory(modelPath, cancel)
            } else {
                let engine = try LLMEngine(config: .init(modelPath: modelPath))
                extractor = LLMExtractor(completer: engine, cancelToken: cancel)
            }
            let result = try extractor.extractDetailed(from: text, onProgress: onProgress)
            guard result.fullyCovered else {
                return LLMPassOutcome(
                    spans: result.spans,
                    attempted: true,
                    failure: "AI could not fully scan \(result.incompleteSegmentCount) "
                        + (result.incompleteSegmentCount == 1 ? "segment" : "segments")
                        + "; unscanned text may still contain names or companies.",
                    cancelled: false
                )
            }
            return LLMPassOutcome(spans: result.spans, attempted: true, failure: nil, cancelled: false)
        } catch is ExtractionCancelled {
            return LLMPassOutcome(spans: [], attempted: true, failure: nil, cancelled: true)
        } catch {
            return LLMPassOutcome(
                spans: [],
                attempted: true,
                failure: "AI detection failed to run; this pass was pattern matching only.",
                cancelled: false
            )
        }
    }

    // MARK: - Export helpers

    /// The off-main-actor body of export. Pure function of its inputs.
    nonisolated static func performExport(
        text: String,
        acceptedSpans: [Span],
        source: URL?,
        custom: [CustomPattern],
        useLLM: Bool,
        modelPath: String?,
        outputDir: URL,
        passphrase: String?,
        createdAtISO8601: String
    ) throws -> (export: ExportResult, tokenBySurface: [String: String]) {
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

        let redactedExt = sourceExt == "docx" && source != nil ? "docx" : "txt"
        let redactedBaseName = collisionFreeBaseName(
            "\(baseName)_redacted",
            extension: redactedExt,
            in: outputDir
        )
        let redactedURL = outputDir.appendingPathComponent("\(redactedBaseName).\(redactedExt)")
        var embeddedMediaCount = 0

        if sourceExt == "docx", let source {
            embeddedMediaCount = DocxRedactor.embeddedMediaCount(in: source)
            let replacements = Self.buildReplacements(
                spans: acceptedSpans,
                mapping: tokenized.mapping
            )
            // Redact the body AND every other text-bearing part (headers, footers,
            // footnotes, endnotes, comments), scrub docProps metadata, and
            // neutralize external mailto:/tel: hyperlink targets, mirroring
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
            try CompanionWriter.writeText(tokenized.tokenizedText, to: redactedURL)
        }

        let mappingURL = outputDir.appendingPathComponent("\(redactedBaseName).ldamap")
        let protection: MappingProtection = passphrase
            .map { .passphrase($0) }
            ?? .keychain(account: redactedBaseName)
        try MappingStore.save(tokenized.mapping, to: mappingURL, protection: protection)

        let export = ExportResult(
            redactedURL: redactedURL,
            mappingURL: mappingURL,
            tokenCount: tokenized.mapping.entries.count,
            embeddedMediaCount: embeddedMediaCount
        )
        return (export: export, tokenBySurface: tokenBySurface(mapping: tokenized.mapping))
    }

    /// First base name (base, base_2, base_3, ...) whose edit-surface file AND
    /// mapping sidecar are both absent from the directory.
    nonisolated static func collisionFreeBaseName(
        _ base: String,
        extension ext: String,
        in directory: URL
    ) -> String {
        let fm = FileManager.default
        func taken(_ name: String) -> Bool {
            fm.fileExists(atPath: directory.appendingPathComponent("\(name).\(ext)").path)
                || fm.fileExists(atPath: directory.appendingPathComponent("\(name).ldamap").path)
        }
        guard taken(base) else { return base }
        var counter = 2
        while taken("\(base)_\(counter)") { counter += 1 }
        return "\(base)_\(counter)"
    }

    /// A non-throwing detector over arbitrary part text for the DOCX non-body
    /// pass, built from this model's own settings. It is deterministic plus
    /// custom vocabulary, merged with best-effort LLM spans (any LLM failure
    /// degrades to empty), mirroring LDAService's detectForImages. It only ever
    /// scans the small non-body parts (headers, footers, notes), never the body,
    /// so it does not re-run the LLM over the document the user already reviewed.
    nonisolated static func nonBodyDetector(
        useLLM: Bool,
        modelPath: String?,
        custom: [CustomPattern]
    ) -> (String) -> [Span] {
        return { text in
            let deterministic = DeterministicEngine().detect(text)
                + CustomPatternEngine.detect(text, patterns: custom)
            return SpanMerger.merge(
                deterministic: deterministic,
                llm: llmSpans(in: text, useLLM: useLLM, modelPath: modelPath).spans
            )
        }
    }

    /// Map each accepted span to a Replacement by looking up its token via the
    /// tokenizer mapping (one token per distinct surface text).
    nonisolated static func buildReplacements(
        spans: [Span],
        mapping: Mapping
    ) -> [Replacement] {
        let tokenBySurface = tokenBySurface(mapping: mapping)
        return spans.compactMap { span in
            guard let token = tokenBySurface[span.text] else { return nil }
            return Replacement(span: span, token: token)
        }
    }

    /// Known surface form -> token, keeping the first token seen for a value.
    /// Client mappings can include aliases, so every form must be indexed when
    /// tokens are assigned back onto detected entities after a handoff.
    nonisolated static func tokenBySurface(mapping: Mapping) -> [String: String] {
        var result: [String: String] = [:]
        for token in mapping.entries.keys.sorted() {
            guard let entry = mapping.entries[token] else { continue }
            for surface in [entry.value, entry.surfaceText] + entry.aliases
            where !surface.isEmpty && result[surface] == nil {
                result[surface] = entry.token
            }
        }
        return result
    }

    // MARK: - Error rendering

    /// A user-facing one-line description of an import or IO error.
    // internal for ReviewModelDetection.swift
    nonisolated static func describe(_ error: Error) -> String {
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
