//
//  LDAFillService.swift
//  LDACore
//
//  Fill-from-profile facade operations, split into a sibling extension to keep
//  LDAService.swift under the 800-line budget. The three operations live here:
//  extractProfile, planFill, applyFill.
//
//  Purity: no clock reads. createdAtISO8601 is supplied by the caller.
//
//  Test seam: makeCompleterForTesting is an internal static var. When set, the
//  supplied factory is called instead of constructing a real LLMEngine; the
//  returned TextCompleter drives ProfileExtractor. Mirrors makeExtractorForTesting
//  in LDAService.swift.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - ExtractProfileResult

/// The outcome of extractProfile: the profile plus per-source import failures.
/// Spec section 9: a failing source is named; the others still contribute.
public struct ExtractProfileResult: Sendable {
    public var profile: ClientPortfolio
    /// (file name, reason) for every source that could not be imported.
    public var failedSources: [(name: String, reason: String)]

    public init(profile: ClientPortfolio, failedSources: [(name: String, reason: String)]) {
        self.profile = profile
        self.failedSources = failedSources
    }
}

// MARK: - LDAService fill operations
//
// noReadableSources and staleTarget are declared in LDAService.swift's
// LDAServiceError enum (cases cannot be added in a Swift extension).

extension LDAService {

    // MARK: - Test seam for ProfileExtractor

    /// Test-only override for building the TextCompleter used by extractProfile.
    /// Production leaves this nil and loads a real LLMEngine from modelPath.
    /// Tests set it to inject a fake TextCompleter so extractProfile can be
    /// exercised without the 2.7 GB GGUF model. Mirrors makeExtractorForTesting.
    internal static var makeCompleterForTesting: (() -> TextCompleter)?

    // MARK: - extractProfile

    /// Build a ClientPortfolio from source documents using the on-device model.
    /// modelPath is REQUIRED: profile extraction is a model feature by design.
    /// When the test seam (makeCompleterForTesting) is set, modelPath is still
    /// required in the call signature but the seam factory is used instead of
    /// loading an engine, so tests need not supply a real GGUF path.
    ///
    /// Throws the underlying LLMEngine construction error when no seam is set
    /// and the engine cannot be loaded. A silent empty profile is worse than an
    /// honest error: callers must know that extraction did not run.
    ///
    /// A failing source (unreadable or yielding no text) is collected in
    /// failedSources; the readable ones still contribute. Throws
    /// LDAServiceError.noReadableSources when ZERO sources produce readable text.
    ///
    /// - Parameters:
    ///   - sources: the source document URLs to import and extract from.
    ///   - label: a short human label for the resulting ClientPortfolio.
    ///   - kind: the portfolio kind (company, individual, or general). Controls
    ///     which keys the model is prompted to extract and is stored on the
    ///     resulting ClientPortfolio. Defaults to .company for backward
    ///     compatibility with existing callers.
    ///   - modelPath: absolute path to the GGUF model. REQUIRED. Ignored only
    ///     when makeCompleterForTesting is set (test seam).
    ///   - createdAtISO8601: caller-supplied creation timestamp (purity rule).
    ///   - onProgress: optional callback (segmentsDone, segmentsTotal). Forwarded
    ///     to ProfileExtractor.extract unchanged.
    public static func extractProfile(
        sources: [URL],
        label: String,
        kind: PortfolioKind = .company,
        modelPath: String,
        createdAtISO8601: String,
        onProgress: ((Int, Int) -> Void)? = nil
    ) throws -> ExtractProfileResult {

        // Import each source individually, collecting failures.
        var readable: [(name: String, text: String)] = []
        var failedSources: [(name: String, reason: String)] = []

        for url in sources {
            let ext = url.pathExtension.lowercased()
            do {
                let imported = try importDocument(url, extension: ext)
                let text = imported.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    // Fires for any empty import (no text layer, blank file, etc.),
                    // not only OCR results.
                    failedSources.append((name: url.lastPathComponent, reason: "no text content found"))
                } else {
                    readable.append((name: url.lastPathComponent, text: imported.text))
                }
            } catch {
                failedSources.append((name: url.lastPathComponent, reason: error.localizedDescription))
            }
        }

        guard !readable.isEmpty else {
            throw LDAServiceError.noReadableSources
        }

        // Build the completer: test seam first, then real LLMEngine.
        // When the seam is absent, construction errors are surfaced to the caller
        // rather than silently producing an empty profile.
        let completer: TextCompleter
        if let factory = makeCompleterForTesting {
            completer = factory()
        } else {
            // LLMEngine(config:) throws on load failure. Propagate to caller
            // rather than swallowing the error.
            completer = try LLMEngine(config: .init(modelPath: modelPath))
        }

        let extractor = ProfileExtractor(completer: completer)
        let result = try extractor.extract(sources: readable, kind: kind, onProgress: onProgress)

        let profile = ClientPortfolio(
            label: label,
            fields: result.fields,
            sourceDocuments: readable.map { $0.name },
            createdAtISO8601: createdAtISO8601,
            incomplete: result.incompleteSegmentCount > 0,
            kind: kind,
            modifiedAtISO8601: createdAtISO8601
        )
        return ExtractProfileResult(profile: profile, failedSources: failedSources)
    }

    // MARK: - planFill

    /// Detect blanks in target and propose fills from profile. modelPath nil
    /// means deterministic-only synonym matching.
    ///
    /// Extension guard: only "docx" and "pdf" are supported fill targets.
    /// Any other extension (txt, md, ...) throws DocumentIOError.unsupportedFormat.
    /// This guard lives BEFORE import so the error is clean. Plain text is valid
    /// as a profile SOURCE in extractProfile; it is intentionally NOT a valid
    /// fill target because fill targets must be structured documents.
    ///
    /// PDF with no widgets returns an empty-blanks plan (NOT an error).
    ///
    /// Two-pass strategy for model matching:
    /// Pass 1 (synonym, no model): FillPlanner.plan with nil completer.
    /// Pass 2 (model): only when at least one blank remains .unmatched AND
    /// modelPath is non-nil. FillPlanner.idempotence leaves .proposed/.confirmed/
    /// .rejected blanks untouched, so pass 2 safely re-plans the full blank list.
    /// The engine is constructed lazily, after pass 1, so clean documents that
    /// need no model do not pay the load cost.
    public static func planFill(
        target: URL,
        profile: ClientPortfolio,
        modelPath: String?
    ) throws -> FillPlan {
        let ext = target.pathExtension.lowercased()

        // Guard: only docx and pdf are supported fill targets.
        // Handle extensionless targets gracefully (ext is "" when no extension).
        guard ext == "docx" || ext == "pdf" else {
            let gotSuffix = ext.isEmpty ? "" : " (got .\(ext))"
            throw DocumentIOError.unsupportedFormat(
                "Fill targets must be .docx or .pdf\(gotSuffix). " +
                "Plain text is a valid profile source but not a fill target."
            )
        }

        switch ext {
        case "docx":
            let imported = try DocxImporter().importDocument(target)
            let blanks = BlankDetector.detect(in: imported.text)

            // Pass 1: synonym matching (no model).
            var planned = FillPlanner.plan(blanks: blanks, profile: profile, completer: nil)

            // Pass 2: model fallback only when unmatched blanks remain and a
            // model path was supplied. Lazy construction: skip the 2.7 GB load
            // when the synonym pass resolved everything.
            // When modelPath is explicitly supplied and the engine fails to load,
            // the error is thrown to the caller: a bad path should be loud, not a
            // silent synonym-only fallback. Omitting modelPath (nil) means
            // deterministic-only and does not reach this branch.
            if planned.contains(where: { $0.status == .unmatched }),
               let modelPath {
                let completer: TextCompleter
                if let factory = makeCompleterForTesting {
                    completer = factory()
                } else {
                    completer = try LLMEngine(config: .init(modelPath: modelPath))
                }
                planned = FillPlanner.plan(blanks: planned, profile: profile, completer: completer)
            }

            return FillPlan(targetFormat: .docx, blanks: planned, manualWidgetNames: [])

        case "pdf":
            let inventory = try AcroFormFiller.enumerate(at: target)
            // A PDF with no widgets is a valid (empty) plan, not an error.
            // label = field name only; context = tooltip text when present.
            // Putting the tooltip into context (not the label) keeps the label
            // clean for synonym matching: e.g. a field named "Company Name"
            // with tooltip "Enter your company name" normalizes correctly when
            // the label is the raw name alone.
            let blanks: [Blank] = inventory.textFieldNames.map { name in
                // AcroFormFiller.fieldLabels stores "name tooltip" when a tooltip
                // exists, or just "name" when it does not. Extract the tooltip
                // remainder by stripping the leading name prefix.
                let combined = inventory.fieldLabels[name] ?? name
                let tooltipContext: String
                if combined.hasPrefix(name), combined.count > name.count {
                    tooltipContext = String(combined.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
                } else {
                    tooltipContext = ""
                }
                return Blank(
                    location: .acroFormField(name: name),
                    label: name,
                    context: tooltipContext,
                    proposedFieldID: nil,
                    proposedValue: nil,
                    status: .unmatched
                )
            }

            // Pass 1: synonym matching (no model).
            var planned = FillPlanner.plan(blanks: blanks, profile: profile, completer: nil)

            // Pass 2: model fallback only when unmatched blanks remain and a
            // model path was supplied. When modelPath is explicitly supplied and
            // the engine fails to load, the error is thrown to the caller: a bad
            // path should be loud, not a silent synonym-only fallback.
            if planned.contains(where: { $0.status == .unmatched }),
               let modelPath {
                let completer: TextCompleter
                if let factory = makeCompleterForTesting {
                    completer = factory()
                } else {
                    completer = try LLMEngine(config: .init(modelPath: modelPath))
                }
                planned = FillPlanner.plan(blanks: planned, profile: profile, completer: completer)
            }

            return FillPlan(
                targetFormat: .pdf,
                blanks: planned,
                manualWidgetNames: inventory.manualWidgetNames
            )

        default:
            // Unreachable: the guard at the top of the function handles all
            // non-docx/non-pdf extensions.
            throw DocumentIOError.unsupportedFormat("Unreachable: ext=\(ext)")
        }
    }

    // MARK: - applyFill

    /// Apply the CONFIRMED blanks of plan to target, write the filled document to
    /// outputDir, and return a value-free FillReport. Only blanks with
    /// status == .confirmed AND a non-nil, non-empty proposedValue are applied.
    ///
    /// Output name: "<stem> (filled).<ext>" in outputDir.
    /// Throws LDAServiceError.outputEqualsInput when the output path equals the
    /// target path (prevents accidental overwrite).
    ///
    /// Cross-check: plan.targetFormat must match target's actual file extension;
    /// a mismatch throws DocumentIOError.unsupportedFormat with a clear message.
    ///
    /// DOCX: re-imports target and verifies each confirmed textSpan blank is still
    /// present at the recorded offsets; throws LDAServiceError.staleTarget on mismatch.
    ///
    /// PDF: maps confirmed acroFormField blanks to a values dictionary and calls
    /// AcroFormFiller.fill; maps AcroFormFiller.FillError.staleTarget to
    /// LDAServiceError.staleTarget.
    ///
    /// - Note: The `profile` parameter is reserved for cross-checking proposedFieldID
    ///   integrity in a future pass. It is not consumed in V1.
    public static func applyFill(
        plan: FillPlan,
        target: URL,
        profile: ClientPortfolio,
        outputDir: URL
    ) throws -> FillReport {
        let ext = target.pathExtension.lowercased()

        // Cross-check: plan.targetFormat must match the target's actual extension.
        let expectedExt: String
        switch plan.targetFormat {
        case .docx: expectedExt = "docx"
        case .pdf:  expectedExt = "pdf"
        case .plainText: expectedExt = "txt"
        }
        guard ext == expectedExt else {
            throw DocumentIOError.unsupportedFormat(
                "Plan was produced for .\(expectedExt) but target has extension " +
                (ext.isEmpty ? "(none)" : ".\(ext)") + "."
            )
        }

        // Guard: only docx and pdf are writable fill targets.
        guard ext == "docx" || ext == "pdf" else {
            throw DocumentIOError.unsupportedFormat(
                "Apply fill: unsupported format " + (ext.isEmpty ? "(no extension)" : ".\(ext)")
            )
        }

        let stem = target.deletingPathExtension().lastPathComponent
        let outputName = "\(stem) (filled).\(ext)"

        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )

        let outputURL = outputDir.appendingPathComponent(outputName)

        // Refuse to overwrite the source.
        guard outputURL.standardizedFileURL.path != target.standardizedFileURL.path else {
            throw LDAServiceError.outputEqualsInput
        }

        // Partition blanks into confirmed-with-value vs skipped.
        // Dedupe confirmed blanks by location BEFORE building fills:
        // first occurrence wins; subsequent occurrences become SkippedBlanks
        // with reason "duplicate location". A duplicate today would cause
        // NSRangeException out of DocxRedactor (DOCX) or silent last-wins (PDF).
        var skipped: [SkippedBlank] = []
        var confirmedBlanks: [Blank] = []
        var seenLocations: Set<BlankLocation> = []

        for blank in plan.blanks {
            switch blank.status {
            case .confirmed:
                if let value = blank.proposedValue, !value.isEmpty {
                    if seenLocations.insert(blank.location).inserted {
                        confirmedBlanks.append(blank)
                    } else {
                        skipped.append(SkippedBlank(
                            label: blank.label,
                            locationDescription: locationDesc(blank.location),
                            reason: "duplicate location"
                        ))
                    }
                } else {
                    skipped.append(SkippedBlank(
                        label: blank.label,
                        locationDescription: locationDesc(blank.location),
                        reason: "confirmed without a value"
                    ))
                }
            case .rejected:
                skipped.append(SkippedBlank(
                    label: blank.label,
                    locationDescription: locationDesc(blank.location),
                    reason: "rejected by reviewer"
                ))
            case .unmatched:
                skipped.append(SkippedBlank(
                    label: blank.label,
                    locationDescription: locationDesc(blank.location),
                    reason: "no matching field"
                ))
            case .proposed:
                skipped.append(SkippedBlank(
                    label: blank.label,
                    locationDescription: locationDesc(blank.location),
                    reason: "not confirmed"
                ))
            }
        }

        // Manual widgets are always skipped.
        for widgetName in plan.manualWidgetNames {
            skipped.append(SkippedBlank(
                label: widgetName,
                locationDescription: "field \(widgetName)",
                reason: "manual widget type"
            ))
        }

        let filledCount: Int

        switch ext {
        case "docx":
            filledCount = try applyDocxFill(
                confirmedBlanks: confirmedBlanks,
                target: target,
                outputURL: outputURL
            )

        case "pdf":
            filledCount = try applyPdfFill(
                confirmedBlanks: confirmedBlanks,
                target: target,
                outputURL: outputURL
            )

        default:
            throw DocumentIOError.unsupportedFormat("Apply fill: unsupported format .\(ext)")
        }

        return FillReport(
            outputURL: outputURL,
            filledCount: filledCount,
            skipped: skipped
        )
    }

    // MARK: - Private: DOCX apply

    private static func applyDocxFill(
        confirmedBlanks: [Blank],
        target: URL,
        outputURL: URL
    ) throws -> Int {
        guard !confirmedBlanks.isEmpty else {
            // Nothing to fill: remove any pre-existing output, then copy.
            // Matches the overwrite behavior of the fill paths so a re-run
            // with zero confirmed blanks does not throw on a stale output file.
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.copyItem(at: target, to: outputURL)
            return 0
        }

        // Re-import to get the current text for staleness verification.
        let reimported = try DocxImporter().importDocument(target)
        let currentText = reimported.text
        let currentBlanks = BlankDetector.detect(in: currentText)

        // Build an array of currently-detected textSpan locations for staleness lookup.
        let currentLocations: [BlankLocation] = currentBlanks.map { $0.location }

        // Verify each confirmed blank is still present in the current text.
        var fills: [DocxFill] = []
        for blank in confirmedBlanks {
            guard case .textSpan(let start, let end) = blank.location else { continue }
            guard let value = blank.proposedValue, !value.isEmpty else { continue }

            // Staleness check: the span must be within bounds AND still detected.
            let nsText = currentText as NSString
            let nsLength = nsText.length
            let withinBounds = start >= 0 && end <= nsLength && start < end
            let stillDetected = currentLocations.contains(blank.location)

            guard withinBounds && stillDetected else {
                throw LDAServiceError.staleTarget(detail: "offset \(start)-\(end)")
            }

            let span = Span(
                start: start,
                end: end,
                type: .unknown,
                text: nsText.substring(with: NSRange(location: start, length: end - start)),
                source: .manual,
                confidence: 1,
                priority: 0
            )
            fills.append(DocxFill(span: span, value: value))
        }

        guard !fills.isEmpty else {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.copyItem(at: target, to: outputURL)
            return 0
        }

        try DocxFiller.fill(original: target, fills: fills, to: outputURL)
        return fills.count
    }

    // MARK: - Private: PDF apply

    private static func applyPdfFill(
        confirmedBlanks: [Blank],
        target: URL,
        outputURL: URL
    ) throws -> Int {
        // Build field-name to value dictionary from confirmed acroFormField blanks.
        // Deduplicated upstream in applyFill (first-wins); no further dedupe needed.
        var values: [String: String] = [:]
        for blank in confirmedBlanks {
            guard case .acroFormField(let name) = blank.location,
                  let value = blank.proposedValue, !value.isEmpty else { continue }
            values[name] = value
        }

        guard !values.isEmpty else {
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.copyItem(at: target, to: outputURL)
            return 0
        }

        do {
            try AcroFormFiller.fill(original: target, values: values, to: outputURL)
        } catch AcroFormFiller.FillError.staleTarget(let missing) {
            throw LDAServiceError.staleTarget(detail: missing.joined(separator: ", "))
        } catch AcroFormFiller.FillError.outputEqualsInput {
            throw LDAServiceError.outputEqualsInput
        } catch AcroFormFiller.FillError.unreadable {
            throw DocumentIOError.unreadable("AcroForm fill: could not open PDF")
        } catch AcroFormFiller.FillError.writeFailed {
            throw DocumentIOError.corrupt("AcroForm fill: PDFKit refused to write output")
        }

        return values.count
    }

    // MARK: - Private: location description

    private static func locationDesc(_ location: BlankLocation) -> String {
        switch location {
        case .acroFormField(let name):
            return "field \(name)"
        case .textSpan(let start, let end):
            return "offset \(start)-\(end)"
        }
    }
}
