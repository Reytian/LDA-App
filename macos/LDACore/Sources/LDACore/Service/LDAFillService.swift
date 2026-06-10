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
    public var profile: CompanyProfile
    /// (file name, reason) for every source that could not be imported.
    public var failedSources: [(name: String, reason: String)]

    public init(profile: CompanyProfile, failedSources: [(name: String, reason: String)]) {
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

    /// Build a CompanyProfile from source documents using the on-device model.
    /// modelPath is REQUIRED (profile extraction is a model feature by nature).
    ///
    /// A failing source (unreadable or yielding no text) is collected in
    /// failedSources; the readable ones still contribute. Throws only when ZERO
    /// sources produce readable text (LDAServiceError.noReadableSources).
    ///
    /// - Parameters:
    ///   - sources: the source document URLs to import and extract from.
    ///   - label: a short human label for the resulting CompanyProfile.
    ///   - modelPath: absolute path to the GGUF model. Ignored when
    ///     makeCompleterForTesting is set (test seam).
    ///   - createdAtISO8601: caller-supplied creation timestamp (purity rule).
    ///   - onProgress: optional callback (segmentsDone, segmentsTotal). Forwarded
    ///     to ProfileExtractor.extract unchanged.
    public static func extractProfile(
        sources: [URL],
        label: String,
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
                let imported = try importDocumentForFill(url, extension: ext)
                let text = imported.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    failedSources.append((name: url.lastPathComponent, reason: "OCR yielded no text"))
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
        let completer: TextCompleter
        if let factory = makeCompleterForTesting {
            completer = factory()
        } else {
            guard let engine = try? LLMEngine(config: .init(modelPath: modelPath)) else {
                // Model load failure: treat like an engine with no completions.
                // ProfileExtractor will produce empty fields; incomplete = true.
                let extractor = ProfileExtractor(completer: DeadCompleter())
                let result = try extractor.extract(sources: readable, onProgress: onProgress)
                let profile = CompanyProfile(
                    label: label,
                    fields: result.fields,
                    sourceDocuments: readable.map { $0.name },
                    createdAtISO8601: createdAtISO8601,
                    incomplete: result.incompleteSegmentCount > 0
                )
                return ExtractProfileResult(profile: profile, failedSources: failedSources)
            }
            completer = engine
        }

        let extractor = ProfileExtractor(completer: completer)
        let result = try extractor.extract(sources: readable, onProgress: onProgress)

        let profile = CompanyProfile(
            label: label,
            fields: result.fields,
            sourceDocuments: readable.map { $0.name },
            createdAtISO8601: createdAtISO8601,
            incomplete: result.incompleteSegmentCount > 0
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
    public static func planFill(
        target: URL,
        profile: CompanyProfile,
        modelPath: String?
    ) throws -> FillPlan {
        let ext = target.pathExtension.lowercased()

        // Guard: only docx and pdf are supported fill targets.
        guard ext == "docx" || ext == "pdf" else {
            throw DocumentIOError.unsupportedFormat(
                "Fill targets must be .docx or .pdf; got .\(ext). " +
                "Plain text is a valid profile source but not a fill target."
            )
        }

        // Build an optional completer for the model fallback pass.
        let completer: TextCompleter? = {
            guard let modelPath else { return nil }
            if let factory = makeCompleterForTesting { return factory() }
            guard FileManager.default.fileExists(atPath: modelPath) else { return nil }
            return try? LLMEngine(config: .init(modelPath: modelPath))
        }()

        switch ext {
        case "docx":
            let imported = try DocxImporter().importDocument(target)
            let blanks = BlankDetector.detect(in: imported.text)
            let planned = FillPlanner.plan(blanks: blanks, profile: profile, completer: completer)
            return FillPlan(targetFormat: .docx, blanks: planned, manualWidgetNames: [])

        case "pdf":
            let inventory = try AcroFormFiller.enumerate(at: target)
            // A PDF with no widgets is a valid (empty) plan, not an error.
            // Empty context is a deliberate V1 choice: nearby page text is not
            // cheaply available from the AcroForm enumeration path.
            let blanks: [Blank] = inventory.textFieldNames.map { name in
                Blank(
                    location: .acroFormField(name: name),
                    label: inventory.fieldLabels[name] ?? name,
                    context: "", // V1: context intentionally omitted for acroFormField blanks.
                    proposedFieldID: nil,
                    proposedValue: nil,
                    status: .unmatched
                )
            }
            let planned = FillPlanner.plan(blanks: blanks, profile: profile, completer: completer)
            return FillPlan(
                targetFormat: .pdf,
                blanks: planned,
                manualWidgetNames: inventory.manualWidgetNames
            )

        default:
            // This branch is unreachable because we guard above, but Swift
            // requires exhaustive switches.
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
    /// DOCX: re-imports target and verifies each confirmed textSpan blank is still
    /// present at the recorded offsets; throws LDAServiceError.staleTarget on mismatch.
    ///
    /// PDF: maps confirmed acroFormField blanks to a values dictionary and calls
    /// AcroFormFiller.fill; maps AcroFormFiller.FillError.staleTarget to
    /// LDAServiceError.staleTarget.
    public static func applyFill(
        plan: FillPlan,
        target: URL,
        profile: CompanyProfile,
        outputDir: URL
    ) throws -> FillReport {
        let ext = target.pathExtension.lowercased()
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
        var skipped: [SkippedBlank] = []
        var confirmedBlanks: [Blank] = []

        for blank in plan.blanks {
            switch blank.status {
            case .confirmed:
                if let value = blank.proposedValue, !value.isEmpty {
                    confirmedBlanks.append(blank)
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
            // Nothing to fill: copy the original.
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
                throw LDAServiceError.staleTarget
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
        var values: [String: String] = [:]
        for blank in confirmedBlanks {
            guard case .acroFormField(let name) = blank.location,
                  let value = blank.proposedValue, !value.isEmpty else { continue }
            values[name] = value
        }

        guard !values.isEmpty else {
            try FileManager.default.copyItem(at: target, to: outputURL)
            return 0
        }

        do {
            try AcroFormFiller.fill(original: target, values: values, to: outputURL)
        } catch AcroFormFiller.FillError.staleTarget {
            throw LDAServiceError.staleTarget
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

    // MARK: - Private: import for fill operations

    /// Import a document for fill operations. Only docx, pdf, and text-like
    /// formats are attempted. Unlike the anonymize import, this is used for
    /// profile source documents (which can be any readable text, including .txt)
    /// as well as for fill target import (where the extension guard fires first).
    private static func importDocumentForFill(
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
            // Plain text and any other text-shaped format: delegate to TextDocumentIO.
            return try TextDocumentIO().importDocument(url)
        }
    }
}

// MARK: - DeadCompleter (internal)

/// A TextCompleter that always returns an empty JSON array. Used as a fallback
/// when an LLMEngine cannot be loaded so ProfileExtractor produces an empty
/// (incomplete) result rather than throwing.
private struct DeadCompleter: TextCompleter {
    func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
        return "[]"
    }
}
