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
//  all nonisolated static; they reach the test seams through the nonisolated
//  effective* accessors in ReviewModel.swift, which are DEBUG-only TestSeam
//  slots there and unconditionally nil in release builds.
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
    /// to Vision OCR. A standalone image (png / jpg / jpeg, or image magic
    /// bytes under another extension) is OCR'd: its recognized text IS the
    /// original text for this document kind, reviewed like any other. Unknown
    /// extensions are treated as plain text.
    nonisolated static func importText(from url: URL) throws -> String {
        try importDocument(from: url).text
    }

    /// Import with the importer the extension calls for, keeping the metadata
    /// the shell reports alongside the text (the docx tracked-change count).
    nonisolated static func importDocument(from url: URL) throws -> ImportedDocument {
        let ext = url.pathExtension.lowercased()
        if ImageTextExtractor.shouldTreatAsImage(url, extension: ext) {
            return try ImageTextExtractor().importDocument(url)
        }
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
        /// True when the AI pass examined this document and stopped short,
        /// rather than never examining it. See LLMPassOutcome.partial.
        let aiRanPartially: Bool
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
        knownEntities: [Span] = [],
        cancel: ExtractionCancelToken? = nil,
        onProgress: ((Int, Int) -> Void)? = nil
    ) -> DetectionOutcome {
        if let delay = effectiveDetectDelay {
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
                aiRan: false, aiFailure: nil, aiRanPartially: false, cancelled: true
            )
        }
        // The full-document literal rescan sweeps in repeat mentions of every
        // confirmed PERSON and COMPANY surface and of the document's defined
        // short names, mirroring the LDAService detect pipeline. knownEntities
        // carries the confirmed person and company spans of the session's
        // OTHER documents (SessionModel wires them), mirroring the
        // session-wide sweep in LDAService.anonymizeSession: their surfaces
        // join the needle set, and every hit still enters the review list
        // like any other detection. Suppression below still wins: a
        // suppressed value's rescan spans carry the same (text, type) key and
        // are filtered with it.
        let merged = EntityRescan.expand(
            SpanMerger.merge(
                deterministic: deterministic,
                llm: llm.spans
            ),
            in: text,
            knownEntities: knownEntities
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
            aiRanPartially: llm.partial,
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
        /// True when the extractor examined this document and stopped short of
        /// finishing it, as opposed to never examining any of it.
        ///
        /// Both report `attempted == true` and a failure, and both leave
        /// `aiRan` false, so nothing downstream could tell them apart. They are
        /// not the same disclosure: a pass that never ran looked for no names
        /// at all, while a pass that covered part of the document found some
        /// and not others, and its review list therefore looks finished when
        /// it is not.
        let partial: Bool
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
        // The invariant this function exists to uphold: attempted == false means
        // the user did not ask for an AI pass. It must NEVER mean "the user
        // asked and we could not". Those two produce identical entity output,
        // so if they also report identically a lawyer cannot tell a
        // deliberately pattern-only redaction from one where the model silently
        // failed to load and names were never looked for.
        guard useLLM else {
            return LLMPassOutcome(
                spans: [], attempted: false, failure: nil,
                partial: false, cancelled: false
            )
        }
        guard let modelPath else {
            return LLMPassOutcome(
                spans: [], attempted: true,
                failure: L10n.string("No detection model is installed for the selected detection level, so people's names and company names were not looked for, and an address was matched only in the Chinese street form. Choose a different level in Settings, or add the model file."),
                partial: false, cancelled: false
            )
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            return LLMPassOutcome(
                spans: [], attempted: true,
                failure: String(
                    format: L10n.string("The AI model file could not be opened (%@), so names, companies, and addresses were not detected."),
                    (modelPath as NSString).lastPathComponent as NSString
                ),
                partial: false, cancelled: false
            )
        }
        do {
            let extractor: LLMExtractor
            if let factory = effectiveLLMExtractorFactory {
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
                    failure: String(
                        format: L10n.string(
                            result.incompleteSegmentCount == 1
                                ? "AI could not fully scan %lld segment; unscanned text may still contain names or companies."
                                : "AI could not fully scan %lld segments; unscanned text may still contain names or companies."
                        ),
                        Int64(result.incompleteSegmentCount)
                    ),
                    // The extractor read this document and did not finish it.
                    partial: true,
                    cancelled: false
                )
            }
            // The second way a pass can be incomplete: the text was read, but a
            // value the model reported anchors nowhere, so there is nothing to
            // redact. Keep the spans that did anchor and say what actually
            // failed. A truncation message here would misdiagnose it.
            guard result.fullyAnchored else {
                let n = result.unlocatableEntityCount
                return LLMPassOutcome(
                    spans: result.spans,
                    attempted: true,
                    failure: String(
                        format: L10n.string(
                            n == 1
                                ? "AI detected %lld value it could not locate exactly in this document; it is still present and was not removed. Check for missed names or companies."
                                : "AI detected %lld values it could not locate exactly in this document; they are still present and were not removed. Check for missed names or companies."
                        ),
                        Int64(n)
                    ),
                    // Read in full, but a reported value anchors nowhere, so
                    // some names were found and one was not removed.
                    partial: true,
                    cancelled: false
                )
            }
            return LLMPassOutcome(
                spans: result.spans, attempted: true, failure: nil,
                partial: false, cancelled: false
            )
        } catch is ExtractionCancelled {
            return LLMPassOutcome(
                spans: [], attempted: true, failure: nil,
                partial: false, cancelled: true
            )
        } catch {
            return LLMPassOutcome(
                spans: [],
                attempted: true,
                failure: L10n.string("AI detection failed to run; this pass was pattern matching only."),
                // The engine never produced a span list, so nothing was
                // examined: this is not partial coverage.
                partial: false, cancelled: false
            )
        }
    }

    // MARK: - Export helpers

    /// The off-main-actor body of export. Pure function of its inputs.
    ///
    /// - Parameters:
    ///   - passphrase: nil writes NO mapping sidecar, which is the default;
    ///     a passphrase writes one, protected by it. See the comment at the
    ///     write itself for why those two are one decision.
    ///   - seedMapping: the mapping this export must extend. Everything the
    ///     seed holds comes back in the returned mapping under the same
    ///     tokens, so the caller can replace whatever the seed came from with
    ///     the result and strand nothing: the previous export's key is still
    ///     in there. Without it, two exports of one document would mint the
    ///     same {COMPANY_1} for different values and the second would silently
    ///     make the first file unrestorable.
    nonisolated static func performExport(
        text: String,
        acceptedSpans: [Span],
        source: URL?,
        custom: [CustomPattern],
        useLLM: Bool,
        modelPath: String?,
        outputDir: URL,
        passphrase: String?,
        createdAtISO8601: String,
        style: SubstitutionStyle = .token,
        includeSealCandidates: Bool = true,
        seedMapping: Mapping? = nil
    ) throws -> (export: ExportResult, mapping: Mapping, tokenBySurface: [String: String]) {
        let baseName = source?.deletingPathExtension().lastPathComponent ?? "document"
        let sourceFile = source?.lastPathComponent ?? "document.txt"
        let sourceExt = source?.pathExtension.lowercased() ?? "txt"

        // No replacement may swallow a newline or a tab, on any format: in a
        // DOCX those characters exist in no w:t run, and in a .txt or .md edit
        // surface a replacement that eats a newline deletes a line. Split such
        // spans into parts before tokenizing, mirroring LDAService.anonymize.
        // Alias pairs below keep the unsplit spans because a break never
        // divides a name surface.
        let exportSpans = SpanSplitter.splitAtBreaks(acceptedSpans, in: text)

        // Declared var so non-body redaction can fold in new mapping entries below.
        var tokenized = try Tokenizer.requireSafeForRelease(
            Tokenizer.tokenize(
                text: text,
                spans: exportSpans,
                sourceFile: sourceFile,
                createdAtISO8601: createdAtISO8601,
                seedMapping: seedMapping,
                style: style
            )
        )
        // Record the full-name/short-name grouping in the mapping, mirroring
        // LDAService.anonymize. Tokens and values are untouched, so restore
        // stays byte-identical at every site.
        tokenized.mapping = EntityRescan.linkAliases(
            in: tokenized.mapping,
            pairs: EntityRescan.aliasPairs(in: text, confirmed: acceptedSpans)
        )

        // Tokenizer.requireSafeForRelease has already run the exact Restorer
        // asterisk verdict. Only now may this export mutate the destination.
        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )

        // An image source additionally yields a redacted PNG under the same
        // base name, so the collision probe covers that artifact too.
        let isImageSource = source.map {
            ImageTextExtractor.shouldTreatAsImage($0, extension: sourceExt)
        } ?? false
        let redactedExt = sourceExt == "docx" && source != nil ? "docx" : "txt"
        let redactedBaseName = collisionFreeBaseName(
            baseName + DefaultWorkspace.redactedSuffix,
            extension: redactedExt,
            in: outputDir,
            alsoProbing: isImageSource ? ["png"] : []
        )
        let redactedURL = outputDir.appendingPathComponent("\(redactedBaseName).\(redactedExt)")
        var embeddedMediaCount = 0
        var redactedImageURL: URL?
        var sealCandidateCount = 0
        var unboxedTokenCount = 0
        // DOCX only: replacements made in headers, footers, notes, and
        // comments. Those parts are redacted but are not in the review list,
        // so the window must add them to report honest coverage.
        var supplementaryCount = 0

        if sourceExt == "docx", let source {
            embeddedMediaCount = DocxRedactor.embeddedMediaCount(in: source)
            let replacements = Self.buildReplacements(
                spans: exportSpans,
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
            let outcome = try DocxRedactor.redact(
                original: source,
                replacements: replacements,
                to: redactedURL,
                nonBody: (mapping: tokenized.mapping, detect: detect)
            )
            for entry in outcome.newEntries {
                tokenized.mapping.entries[entry.token] = entry
            }
            supplementaryCount = outcome.coverage.replacementCount
        } else {
            try CompanionWriter.writeText(tokenized.tokenizedText, to: redactedURL)
        }

        // Image source: also render the redacted PNG, and carry its two
        // counts out for the window to report.
        if isImageSource, let source {
            let artifact = try renderImageArtifact(
                source: source,
                reviewedText: text,
                acceptedSpans: acceptedSpans,
                includeSealCandidates: includeSealCandidates,
                to: outputDir.appendingPathComponent("\(redactedBaseName).png")
            )
            redactedImageURL = artifact.url
            sealCandidateCount = artifact.sealCandidateCount
            unboxedTokenCount = artifact.unboxedTokenCount
        }

        // The sidecar is written IF AND ONLY IF the user typed a passphrase,
        // which is the whole of two decisions at once.
        //
        // It is not written by default because it sits in the folder the user
        // is about to send the redacted document from, and its contents are
        // the original values. Encrypted, so this is not an exposure today;
        // but a file that travels with the document by default is a file that
        // will eventually travel to somebody who should not have the key. The
        // key's default home is now a workspace on this Mac; see
        // DefaultWorkspace and SessionModel.keepMappingInWorkspace.
        //
        // And when it IS written it is passphrase protected, never Keychain
        // protected. The point of a sidecar is to travel (another Mac, a
        // colleague), and a Keychain sealed file cannot be opened anywhere but
        // here, so the old blank-means-Keychain default produced the one thing
        // a sidecar is useless as. A caller that wants the local, no
        // passphrase form asks for the workspace instead.
        var mappingURL: URL?
        if let passphrase {
            let url = outputDir.appendingPathComponent(
                "\(redactedBaseName).\(MappingStore.fileExtension)"
            )
            try MappingStore.save(
                tokenized.mapping,
                to: url,
                protection: .passphrase(passphrase)
            )
            mappingURL = url
        }

        let export = ExportResult(
            redactedURL: redactedURL,
            mappingURL: mappingURL,
            tokenCount: tokenized.mapping.entries.count,
            embeddedMediaCount: embeddedMediaCount,
            redactedImageURL: redactedImageURL,
            sealCandidateCount: sealCandidateCount,
            unboxedTokenCount: unboxedTokenCount,
            entityCount: exportSpans.count + supplementaryCount,
            supplementaryEntityCount: supplementaryCount
        )
        return (
            export: export,
            mapping: tokenized.mapping,
            tokenBySurface: tokenBySurface(mapping: tokenized.mapping)
        )
    }

    /// Render the redacted PNG for a standalone image source.
    ///
    /// The image is re-read here (export is a separate call from open, and the
    /// model stores no geometry); when its recognized text no longer matches
    /// the reviewed text, the ranges cannot be trusted to sit on the right
    /// lines, so the export fails closed instead of shipping a leaking
    /// "redacted" image. Whole observation boxes are covered; over-covering is
    /// acceptable, under-covering is a leak.
    ///
    /// Two counts come back and must reach the user, exactly as they do on the
    /// CLI route: how many red-region seal CANDIDATES entered the coverage
    /// (candidates, never certain detections), and how many replaced values
    /// the geometry could not box at all. The second one means the exported
    /// PNG may still show a value the text companion redacted, so it is a
    /// warning, never a dropped number.
    ///
    /// - Parameter includeSealCandidates: the document's own choice. Off means
    ///   OCR coverage only, for a page whose red letterhead over-covers.
    nonisolated static func renderImageArtifact(
        source: URL,
        reviewedText: String,
        acceptedSpans: [Span],
        includeSealCandidates: Bool,
        to imageURL: URL
    ) throws -> (url: URL, sealCandidateCount: Int, unboxedTokenCount: Int) {
        let extraction = try ImageTextExtractor().extract(source)
        guard extraction.text == reviewedText else {
            throw DocumentIOError.corrupt(
                "The image's recognized text no longer matches the reviewed "
                    + "text (the file may have changed on disk). Re-open "
                    + "\(source.lastPathComponent) and export again."
            )
        }
        let coverage = ImageRedactor.coverage(
            lines: extraction.lines,
            replacedRanges: acceptedSpans.map { $0.start..<$0.end }
        )
        let sealCandidates = includeSealCandidates
            ? try SealCandidateDetector.candidates(inImageAt: source)
            : []
        let render = try ImageRedactor.renderRedactedPNG(
            originalImageAt: source,
            covering: coverage.coveredLines,
            sealCandidates: sealCandidates,
            to: imageURL
        )
        return (
            url: imageURL,
            sealCandidateCount: render.sealCandidateCount,
            unboxedTokenCount: coverage.unlocatedRangeCount
        )
    }

    /// First base name (base, base_2, base_3, ...) whose edit-surface file AND
    /// mapping sidecar (and any extra probed artifacts, e.g. the redacted PNG
    /// of an image export) are all absent from the directory.
    nonisolated static func collisionFreeBaseName(
        _ base: String,
        extension ext: String,
        in directory: URL,
        alsoProbing extraExtensions: [String] = []
    ) -> String {
        let fm = FileManager.default
        func taken(_ name: String) -> Bool {
            let probes = [ext, "ldamap"] + extraExtensions
            return probes.contains { probe in
                fm.fileExists(atPath: directory.appendingPathComponent("\(name).\(probe)").path)
            }
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

    /// How many replacements a .docx export would make OUTSIDE the body, so
    /// the window can report the coverage it actually delivers rather than
    /// the length of the review list.
    ///
    /// 0 for a nil source and for every non-docx format. Uses the same
    /// nonBodyDetector the export uses, over the same parts, so the number
    /// shown before the export and the number written by it agree. Only the
    /// small supplementary parts are scanned; the body the user already
    /// reviewed is never re-detected here.
    nonisolated static func supplementaryCount(
        source: URL?,
        useLLM: Bool,
        modelPath: String?,
        custom: [CustomPattern]
    ) -> Int {
        guard let source, source.pathExtension.lowercased() == "docx" else { return 0 }
        let detect = nonBodyDetector(useLLM: useLLM, modelPath: modelPath, custom: custom)
        return DocxRedactor.supplementaryCoverage(in: source, detect: detect).replacementCount
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

    /// The token to show on an entity's sealed chip.
    ///
    /// A value whose surface crossed a newline or a tab was redacted as SEVERAL
    /// tokens, one per part (see SpanSplitter), so the crossing surface itself
    /// is in no mapping entry and the direct lookup misses. The chip then falls
    /// back to the first part's token. Reporting nil instead would tell the
    /// user the value is unprotected, which is both false and the more
    /// dangerous of the two wrong answers in a redaction tool.
    nonisolated static func chipToken(
        for surface: String,
        in tokenBySurface: [String: String]
    ) -> String? {
        if let direct = tokenBySurface[surface] { return direct }
        guard let firstPart = SpanSplitter.firstPart(of: surface) else { return nil }
        return tokenBySurface[firstPart]
    }

    // MARK: - Error rendering

    /// A user-facing one-line description of an import or IO error.
    // internal for ReviewModelDetection.swift
    nonisolated static func describe(_ error: Error) -> String {
        DocumentErrorPresentation.describe(error) ?? error.localizedDescription
    }
}
