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
        /// The party names of a published precedent that stay visible
        /// (PrecedentPartyRule), or nil. Their spans are in `spans`; the
        /// caller lists them unticked so the user can still redact them.
        var precedent: PrecedentRelease? = nil
        /// The values the AI pass found in the document and could not anchor,
        /// so nothing in `spans` covers them. See LLMPassOutcome.unlocated.
        var aiUnlocated: [ExtractedEntity] = []
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

        // A published precedent's own parties stay visible. Values another
        // document of the session redacts are not released (see
        // PrecedentPartyRule.release).
        let precedent = PrecedentPartyRule.release(
            text: text,
            spans: kept,
            redactedElsewhere: knownEntities
        )

        return DetectionOutcome(
            spans: kept,
            learnedApplied: appliedValues.count,
            suppressed: suppressed,
            aiRan: llm.attempted && llm.failure == nil,
            aiFailure: llm.failure,
            aiRanPartially: llm.partial,
            cancelled: false,
            precedent: precedent,
            aiUnlocated: llm.unlocated
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
        /// The values the extractor reported that are in the document but
        /// anchor nowhere (ExtractionResult.unlocatedEntities), so they were
        /// not redacted. Without them the failure sentence can only count
        /// what was left in place, and a count is nothing the user can act on.
        /// Empty unless `partial` is true. Document contents: they are shown
        /// in Review and never written to a log.
        var unlocated: [ExtractedEntity] = []
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
            // The built-in LDA V4 tagger (a model folder) or a GGUF tier.
            let extractor: EntityExtracting
            if let factory = effectiveLLMExtractorFactory {
                extractor = factory(modelPath, cancel)
            } else {
                extractor = try EntityExtractorFactory.make(modelPath: modelPath, cancelToken: cancel)
            }
            let result = try extractor.extractDetailed(from: text, onProgress: onProgress)
            // Every segment failed and nothing came back from any of them: the
            // model examined nothing. That is a pass that did not run, not one
            // that stopped short, and the headline and the export gate must
            // say so rather than tell the user some names were found.
            if result.scannedNothing {
                return LLMPassOutcome(
                    spans: [],
                    attempted: true,
                    failure: L10n.string("AI detection failed to run; this pass was pattern matching only."),
                    partial: false,
                    cancelled: false
                )
            }
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
                    cancelled: false,
                    // A value from a segment that WAS read can still have
                    // failed to anchor. It is in the document either way.
                    unlocated: result.unlocatedEntities
                )
            }
            // The second way a pass can be incomplete: the text was read, but a
            // value the model reported anchors nowhere, or anchors and is also
            // written where a digit or a word runs into it, so there is a place
            // nothing redacts. Keep the spans that did anchor and say what
            // actually failed. A truncation message here would misdiagnose it.
            guard result.fullyAnchored else {
                let n = result.unlocatableEntityCount
                return LLMPassOutcome(
                    spans: result.spans,
                    attempted: true,
                    // Says what failed (the values could not be located, which
                    // is not a truncation), covers a value that was redacted
                    // elsewhere ("in some places"), and is worded to stay true
                    // after the user protects them from the list beside it.
                    failure: String(
                        format: L10n.string(
                            n == 1
                                ? "AI found %lld value it could not locate exactly in some places, so it was not redacted there. It stays in the document until you protect it."
                                : "AI found %lld values it could not locate exactly in some places, so they were not redacted there. They stay in the document until you protect them."
                        ),
                        Int64(n)
                    ),
                    // Read in full, but a reported value is left somewhere, so
                    // some names were found and one was not removed.
                    partial: true,
                    cancelled: false,
                    // Which ones, so Review can name them next to the count.
                    unlocated: result.unlocatedEntities
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

    /// The subset of `mapping` that this document actually spells, for a
    /// sidecar that must not carry any other document's values.
    ///
    /// Matches on `entry.token`, NOT on the dictionary key. Under the asterisk
    /// output style a mask can collide across entities, so a colliding entry
    /// is stored under a disambiguated key ("张*#2") while `token` keeps the
    /// shared replacement that is what the document really contains. Filtering
    /// on the key would drop every colliding entry and produce a sidecar that
    /// restores those sites to nothing, which is the quiet kind of wrong.
    ///
    /// A shared mask keeps ALL entries that share it. Restore cannot tell them
    /// apart either, and that case is already surfaced as an ambiguous
    /// replacement rather than guessed at.
    nonisolated static func mappingSpelledBy(
        _ mapping: Mapping,
        tokenizedText: String,
        nonBodyTokens: Set<String>
    ) -> Mapping {
        var narrowed = mapping
        narrowed.entries = mapping.entries.filter { _, entry in
            nonBodyTokens.contains(entry.token)
                || tokenizedText.contains(entry.token)
        }
        return narrowed
    }
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
    ///   - format: the format of the redacted file (RedactedOutputWriter).
    ///     The window passes the person's choice. Callers that predate the
    ///     choice get the original format, which is what Save Redacted wrote.
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
        format: RedactedOutputFormat = .original,
        includeSealCandidates: Bool = true,
        seedMapping: Mapping? = nil,
        keepVisible: Set<String> = [],
        protectedRunIns: [ExtractedEntity] = []
    ) throws -> (export: ExportResult, mapping: Mapping, tokenBySurface: [String: String]) {
        let baseName = source?.deletingPathExtension().lastPathComponent ?? "document"
        let sourceFile = source?.lastPathComponent ?? "document.txt"

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

        // One writer for every format and source type, the one a batch uses
        // too (RedactedOutputWriter). The collision probe covers every file
        // the chosen format writes under this base name, the redacted PNG or
        // PDF and the text beside it included, so an export never replaces a
        // file that was already in the folder.
        let layout = RedactedOutputWriter.Layout.chosen(format)
        let extensions = RedactedOutputWriter.artifactExtensions(for: source, layout: layout)
        let redactedBaseName = collisionFreeBaseName(
            baseName + DefaultWorkspace.redactedSuffix,
            extension: extensions[0],
            in: outputDir,
            alsoProbing: Array(extensions.dropFirst())
        )
        // The Word parts outside the body (headers, footers, footnotes,
        // endnotes, comments) are redacted too, with docProps scrubbed and
        // external mailto:/tel: targets neutralized, mirroring
        // LDAService.anonymize. Their detector is built from this model's own
        // settings and obeys the body's gates (nonBodyDetector, F9); it never
        // re-runs the LLM over the body. The text of images inside a PDF is
        // read by the same detector at best effort, as LDAService reads it.
        // Surfaces found only in those places mint new tokens that are
        // folded into the mapping below so they persist in the sidecar and
        // restore correctly.
        let detect = Self.nonBodyDetector(
            useLLM: useLLM,
            modelPath: modelPath,
            custom: custom,
            keepVisible: keepVisible,
            protectedRunIns: protectedRunIns
        )
        let written = try RedactedOutputWriter.write(
            RedactedOutputWriter.Document(
                source: source,
                imported: nil,
                tokenizedText: tokenized.tokenizedText,
                mapping: tokenized.mapping,
                spans: exportSpans,
                replacements: Self.buildReplacements(spans: exportSpans, tokenized: tokenized),
                style: style,
                imageLines: try Self.reviewedImageLines(source: source, reviewedText: text, layout: layout),
                includeSealCandidates: includeSealCandidates,
                detectWordParts: detect,
                detectImageText: { (try? detect($0)) ?? [] },
                // A boxed PDF reprints every page: the writer refuses it when
                // the file reads differently from what this review covered.
                reviewedText: text
            ),
            layout: layout,
            to: outputDir,
            baseName: redactedBaseName
        )
        /// Tokens emitted OUTSIDE the body text: docx headers, footers and
        /// fields, and images inside a PDF. They belong to this document but
        /// never appear in tokenizedText, so a sidecar filtered on the body
        /// alone would drop them and their values would restore as nothing.
        var nonBodyTokens: Set<String> = []
        for entry in written.newEntries {
            tokenized.mapping.entries[entry.token] = entry
            nonBodyTokens.insert(entry.token)
        }
        // DOCX only: replacements made in headers, footers, notes, and
        // comments. Those parts are redacted but are not in the review list,
        // so the window must add them to report honest coverage.
        let supplementaryCount = written.supplementary.replacementCount

        // The sidecar is written IF AND ONLY IF the user typed a passphrase,
        // which is the whole of two decisions at once.
        //
        // It is not written by default because it sits in the folder the user
        // is about to send the redacted document from, and its contents are
        // the original values. Encrypted, so this is not an exposure today;
        // but a file that travels with the document by default is a file that
        // will eventually travel to somebody who should not have the key. The
        // key's default home is now a workspace on this Mac; see
        // DefaultWorkspace and SessionModel.keepMapping(_:in:).
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
            // NARROWED TO THIS DOCUMENT, and this is a confidentiality fix
            // rather than a tidiness one.
            //
            // The tokenizer is seeded with the session mapping so one company
            // keeps one token across every document in the sitting. That
            // seeding is correct and stays. But it means tokenized.mapping
            // carries the entries of every OTHER document too, and this file
            // is the one the export sheet tells the user to keep and send. A
            // sidecar for the Wang matter was therefore shipping the Chen
            // matter's names to whoever received it.
            //
            // The workspace deliberately keeps the WIDE mapping: it never
            // leaves this Mac, and its breadth is what stops a re-export after
            // a relaunch minting a second token for a value the first
            // document already sealed. Narrow the thing that travels; leave
            // the thing that stays.
            try MappingStore.save(
                Self.mappingSpelledBy(
                    tokenized.mapping,
                    tokenizedText: tokenized.tokenizedText,
                    nonBodyTokens: nonBodyTokens
                ),
                to: url,
                protection: .passphrase(passphrase)
            )
            mappingURL = url
        }

        let export = ExportResult(
            // A boxed PDF or image is no restore surface: the redacted text
            // beside it is. So the text is redactedURL and the boxed copy is
            // redactedImageURL, as for an image before there were formats.
            redactedURL: written.redactedURL,
            mappingURL: mappingURL,
            tokenCount: tokenized.mapping.entries.count,
            embeddedMediaCount: written.embeddedMediaCount,
            redactedImageURL: written.boxedImageURL ?? written.boxedPDFURL,
            sealCandidateCount: written.sealCandidateCount,
            unboxedTokenCount: written.unboxedOccurrenceCount,
            entityCount: exportSpans.count + supplementaryCount,
            supplementaryEntityCount: supplementaryCount
        )
        return (
            export: export,
            mapping: tokenized.mapping,
            tokenBySurface: tokenBySurface(of: tokenized)
        )
    }

    /// The OCR lines a boxed image is painted from, for an export whose
    /// format boxes the image; nil for any other export.
    ///
    /// The image is read again here (export is a separate call from open, and
    /// the model stores no geometry); when its recognized text no longer
    /// matches the reviewed text, the ranges cannot be trusted to sit on the
    /// right lines, so the export fails closed instead of shipping a leaking
    /// "redacted" image. The writer covers whole observation boxes:
    /// over-covering is acceptable, under-covering is a leak.
    nonisolated static func reviewedImageLines(
        source: URL?,
        reviewedText: String,
        layout: RedactedOutputWriter.Layout
    ) throws -> [ImageTextLine]? {
        if case .format(.markdown, _) = layout { return nil }
        guard let source,
              ImageTextExtractor.shouldTreatAsImage(source, extension: source.pathExtension.lowercased()) else {
            return nil
        }
        let extraction = try ImageTextExtractor().extract(source)
        guard extraction.text == reviewedText else {
            throw DocumentIOError.corrupt(
                "The image's recognized text no longer matches the reviewed "
                    + "text (the file may have changed on disk). Re-open "
                    + "\(source.lastPathComponent) and export again."
            )
        }
        return extraction.lines
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
        OutputNames.firstFreeBaseName(base, in: directory) { name in
            ([ext, "ldamap"] + extraExtensions).map { "\(name).\($0)" }
        }
    }

    /// The detector over arbitrary part text for the DOCX non-body pass,
    /// built from this model's own settings: deterministic plus custom
    /// vocabulary, merged with the model's spans. It only ever scans the small
    /// non-body parts (headers, footers, notes, comments, and their markup
    /// text), never the body, so it does not re-run the model over the
    /// document the user already reviewed.
    ///
    /// The parts obey the body's gates (review 2026-11-11, F9). The pass used
    /// to be best effort, so a model error, a truncated answer or a value the
    /// locator could not anchor in a footnote left that footnote in clear and
    /// the export reported success. The user never reviews these parts, so a
    /// value written only run into other text there is redacted at those
    /// places, as Protect would; a model error, a part it could not scan, or
    /// a value it found but cannot remove refuses the export
    /// (NonBodyScanRefusal). A model that is not installed is the condition
    /// the body scan already reported, and is not refused again here.
    ///
    /// `keepVisible` holds the normalized party names a published precedent
    /// leaves in clear in the body. They stay in clear in the other parts too:
    /// a token in a header beside the name in clear in the body would
    /// disclose the mapping.
    ///
    /// `protectedRunIns` holds the values the user protected in the body
    /// where a letter or digit runs into them (ReviewModel
    /// .protectedUnlocatedValues). This pass refuses the same edges the body
    /// scan refused, so without them "Protected" in Review would not hold for
    /// a header or footer that writes the value the same way. They are
    /// redacted here at the same kind of place only
    /// (EntityLocator.runInOccurrences), never inside an ordinary word.
    /// Protecting a value ticks it in the body, so it is no longer among the
    /// precedent names `keepVisible` leaves in clear
    /// (ReviewModel.precedentValuesLeftVisible).
    nonisolated static func nonBodyDetector(
        useLLM: Bool,
        modelPath: String?,
        custom: [CustomPattern],
        keepVisible: Set<String> = [],
        protectedRunIns: [ExtractedEntity] = []
    ) -> (String) throws -> [Span] {
        return { text in
            // The same places a batch protects without asking
            // (RunInProtection), marked as the user's own decision.
            let runIns = RunInProtection.spans(
                for: protectedRunIns,
                in: text,
                source: .manual,
                priority: ProtectSelectionRules.manualPriority
            )
            let model = try gatedModelSpans(in: text, useLLM: useLLM, modelPath: modelPath)
            let deterministic = DeterministicEngine().detect(text)
                + CustomPatternEngine.detect(text, patterns: custom)
                + runIns
                + model.protected
            let merged = SpanMerger.merge(deterministic: deterministic, llm: model.spans)
            guard !keepVisible.isEmpty else { return merged }
            return merged.filter {
                !(($0.type == .person || $0.type == .company)
                    && keepVisible.contains(TextMatching.normalize($0.text)))
            }
        }
    }

    /// The model's spans over one non-body text, under the body's gates, and
    /// the run-in places of the values it could not anchor.
    nonisolated static func gatedModelSpans(
        in text: String,
        useLLM: Bool,
        modelPath: String?
    ) throws -> (spans: [Span], protected: [Span]) {
        guard useLLM, let modelPath, FileManager.default.fileExists(atPath: modelPath) else { return ([], []) }
        let result: ExtractionResult
        do {
            let extractor: EntityExtracting = try effectiveLLMExtractorFactory.map { $0(modelPath, nil) }
                ?? EntityExtractorFactory.make(modelPath: modelPath)
            result = try extractor.extractDetailed(from: text, onProgress: nil)
        } catch {
            throw NonBodyScanRefusal.notScanned
        }
        guard result.fullyCovered, !result.scannedNothing else { throw NonBodyScanRefusal.notScanned }
        guard !result.fullyAnchored else { return (result.spans, []) }
        let outcome = RunInProtection.protect(result.unlocatedEntities, in: text, reported: result.reportedRunIns)
        guard outcome.unprotectedValues.isEmpty else {
            throw NonBodyScanRefusal.valuesLeft(outcome.unprotectedValues.count)
        }
        return (result.spans, outcome.spans)
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
        custom: [CustomPattern],
        keepVisible: Set<String> = []
    ) -> Int {
        guard let source, source.pathExtension.lowercased() == "docx" else { return 0 }
        let detect = nonBodyDetector(
            useLLM: useLLM, modelPath: modelPath, custom: custom, keepVisible: keepVisible
        )
        // A preview: a part the export would refuse counts as nothing here,
        // and the export itself says why it refused.
        return DocxRedactor.supplementaryCoverage(in: source, detect: { (try? detect($0)) ?? [] }).replacementCount
    }

    /// Map each accepted span to a Replacement carrying the token the
    /// tokenizer emitted for it (tokenBySurface(of:)).
    nonisolated static func buildReplacements(
        spans: [Span],
        tokenized: TokenizeResult
    ) -> [Replacement] {
        let tokenBySurface = tokenBySurface(of: tokenized)
        return spans.compactMap { span in
            guard let token = tokenBySurface[span.text] else { return nil }
            return Replacement(span: span, token: token)
        }
    }

    /// Surface form -> token for a document just tokenized: the replacement
    /// the tokenizer bound each surface to in THIS text first, then the
    /// mapping's first token for anything it did not bind (an alias).
    ///
    /// A seed can hold a value under a token the tokenizer will not reuse
    /// here (the document spells that token literally), so the mapping then
    /// holds the value twice. Looked up in the mapping, the older token came
    /// first and the Word file and the sealed chips carried a token the text
    /// did not (review 2026-11-11, F11, second independent review, where the
    /// seed of that time made this the ordinary case).
    nonisolated static func tokenBySurface(of tokenized: TokenizeResult) -> [String: String] {
        tokenized.replacementBySurface.merging(tokenBySurface(mapping: tokenized.mapping)) { emitted, _ in emitted }
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
