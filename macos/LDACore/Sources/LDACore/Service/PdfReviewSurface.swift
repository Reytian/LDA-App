//
//  PdfReviewSurface.swift
//  LDACore
//
//  Locating the redaction boxes for a PDF's review surface across all three
//  channels that can carry PII on a page: the text layer, page-scoped OCR for
//  a page with no text layer, and OCR of embedded raster images.
//
//  Split out of LDAService.anonymize so the three channels and the coverage
//  they report read as one unit rather than a long branch inside a switch.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// The boxes to paint over a PDF, plus what the channels could not cover.
enum PdfReviewSurface {

    struct Outcome {
        /// Every box, from every channel, in channel order.
        var boxes: [RedactionBox]
        /// How many replaced OCCURRENCES the review PDF may still show. See
        /// PdfRedactionCoverage.unboxedOccurrenceCount for what is counted.
        var unboxedOccurrenceCount: Int
        /// How many image-origin regions were boxed.
        var imageRedactionCount: Int
        /// Image-origin entries the caller must fold into the mapping before it
        /// is saved, or the sidecar will not carry them.
        var newEntries: [MappingEntry]
    }

    /// Box every replaced value on every channel, and report what stayed
    /// visible instead of papering over it.
    ///
    /// - Parameters:
    ///   - input: the source PDF.
    ///   - imported: its import result, for the scanned-page geometry.
    ///   - mapping: the mapping from the text-layer tokenization (read only).
    ///   - sitesByToken: how many sites of each token the redacted text has.
    ///   - detect: detection over arbitrary text, for image-origin PII.
    static func locate(
        in input: URL,
        imported: ImportedDocument,
        mapping: Mapping,
        sitesByToken: [String: Int],
        detect: (String) -> [Span]
    ) -> Outcome {
        // Pairs come from text-layer entries only; image-origin regions are
        // boxed by the image-PII channel below, not via text search. And only
        // from the values this document replaced: a seeded session mapping
        // also holds other documents' values, and boxing one this document
        // left in clear would label it with a placeholder that its redacted
        // text never wrote, telling a reader what that placeholder stands
        // for. The image channel still mints against the whole mapping.
        let pairs = mapping.entries.values
            .filter { (sitesByToken[$0.token] ?? 0) > 0 }
            .map { (text: $0.surfaceText, token: $0.token) }
        let located = textChannel(in: input, imported: imported, pairs: pairs)
        let images = imageChannel(in: input, imported: imported, mapping: mapping, detect: detect)
        let boxes = located.flatMap(\.boxes) + images.boxes

        // Any replaced OCCURRENCE with no box is reported, counted against the
        // sites the text replaced (review 2026-11-11, F6). Asking only
        // whether SOME box carried the token called a value covered while a
        // second, wrapped occurrence of it kept the original pixels, and so
        // did counting only the occurrences the search happened to locate.
        return Outcome(
            boxes: boxes,
            unboxedOccurrenceCount: PdfRedactionCoverage.unboxedOccurrenceCount(
                sitesByToken: sitesByToken,
                occurrences: located
            ),
            imageRedactionCount: images.imageRedactionCount,
            newEntries: images.newEntries
        )
    }

    /// The text-layer channel, plus page-scoped OCR wherever a page carries no
    /// text layer for the search to work on. Every occurrence either channel
    /// located is returned with its boxes, so coverage is counted for scanned
    /// pages too (review 2026-11-11, F6).
    private static func textChannel(
        in input: URL,
        imported: ImportedDocument,
        pairs: [(text: String, token: String)]
    ) -> [PdfTextOccurrence] {
        guard !imported.isScanned else {
            // No text layer anywhere: every occurrence comes from page OCR.
            return PdfOCRImporter.ocrOccurrences(in: input, matching: pairs)
        }
        var occurrences = PdfImporter.redactionCoverage(in: input, surfaceTexts: pairs).occurrences
        // Hybrid PDFs: the scanned pages have no text layer for the selection
        // search, so their PII is located via page-scoped OCR.
        if !imported.scannedPageIndexes.isEmpty {
            occurrences += PdfOCRImporter.ocrOccurrences(
                in: input,
                matching: pairs,
                pages: imported.scannedPageIndexes
            )
        }
        return occurrences
    }

    /// Image-PII channel: a non-scanned PDF can still embed raster images
    /// (signatures, stamps) the text layer cannot see. OCR those regions,
    /// conservatively box them, and report the classified PII as new entries.
    /// Fully scanned pages are excluded: their whole text already entered the
    /// document text via per-page OCR and is boxed by the channel above.
    private static func imageChannel(
        in input: URL,
        imported: ImportedDocument,
        mapping: Mapping,
        detect: (String) -> [Span]
    ) -> ImageRedactionResolver.Result {
        let empty = ImageRedactionResolver.Result(
            boxes: [],
            newEntries: [],
            imageRedactionCount: 0
        )
        guard !imported.isScanned else { return empty }
        let scannedSet = Set(imported.scannedPageIndexes)
        let imagePages = PdfImageInventory.pagesWithImages(input)
            .filter { !scannedSet.contains($0) }
        guard !imagePages.isEmpty else { return empty }

        let observations = PdfOCRImporter().imageOriginObservations(
            in: input,
            pages: imagePages
        )
        return ImageRedactionResolver.resolve(
            mapping: mapping,
            observations: observations,
            detect: detect
        )
    }
}
