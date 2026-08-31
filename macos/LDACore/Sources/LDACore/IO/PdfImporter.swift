//
//  PdfImporter.swift
//  LDACore
//
//  Born-digital PDF text extraction via PDFKit. A DocumentImporter for .pdf
//  files. Scanned PDFs (no usable text layer) are flagged with isScanned = true
//  so a separate OCR unit can recover the text; this importer still returns
//  whatever text exists.
//
//  Offset convention: ImportedDocument.text uses UTF-16 code-unit offsets, the
//  same NSRange-compatible convention as Span in CoreTypes.swift.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import PDFKit

/// Separator inserted between page texts when concatenating page strings. Two
/// newlines give the detection engine a clear page boundary while keeping the
/// extracted text close to a natural reading order.
private let pageSeparator = "\n\n"

/// A DocumentImporter for born-digital PDF files. It loads the PDF with PDFKit,
/// concatenates the per-page text layer, and reports page count and a scanned
/// flag. Scanned-PDF OCR recovery lives in a separate unit.
public struct PdfImporter: DocumentImporter {

    public init() {}

    /// Returns true when the file at url has a .pdf extension.
    public func canImport(_ url: URL) -> Bool {
        return url.pathExtension.lowercased() == "pdf"
    }

    /// Imports the PDF and extracts its text layer.
    ///
    /// Behavior:
    /// - Loads the document with PDFKit. A nil document is treated as corrupt.
    /// - Concatenates page.string across all pages, joined by pageSeparator.
    /// - isScanned is true when the total extracted text is empty or whitespace,
    ///   signalling that OCR is needed; the (empty) text is still returned.
    /// - scannedPageIndexes flags the individual pages with no usable text
    ///   layer, so a hybrid PDF (digital agreement plus scanned exhibit) gets
    ///   per-page OCR instead of silently skipping the scanned pages.
    /// - pageCount comes from the document.
    public func importDocument(_ url: URL) throws -> ImportedDocument {
        let layers = try PdfImporter.pageTextLayers(in: url)
        let text = layers.texts.joined(separator: pageSeparator)
        let isScanned = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return ImportedDocument(
            text: text,
            format: .pdf,
            isScanned: isScanned,
            pageCount: layers.texts.count,
            scannedPageIndexes: layers.scannedPages
        )
    }

    /// Extracts the per-page text layer and reports which pages have no usable
    /// text. The caller splices OCR text into those slots for hybrid PDFs.
    public static func pageTextLayers(
        in url: URL
    ) throws -> (texts: [String], scannedPages: [Int]) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DocumentIOError.unreadable("File not found at \(url.path)")
        }
        try ImportLimits.enforceDocumentSize(at: url)

        guard let document = PDFDocument(url: url) else {
            throw DocumentIOError.corrupt("PDFKit could not open the document at \(url.path)")
        }

        let pageCount = document.pageCount
        var texts: [String] = []
        texts.reserveCapacity(pageCount)
        var scannedPages: [Int] = []

        for index in 0..<pageCount {
            // Repair PDFKit non-breaking-space extraction artifacts (a source
            // nbsp can surface as a spurious "A with circumflex"). Done here so
            // detection, the redacted edit surface, and the restored output all
            // see the same clean text. normalizeWhitespace below collapses the
            // same artifact so the box locator still matches this repaired text.
            let pageText = PdfTextNormalizer.normalize(document.page(at: index)?.string ?? "")
            texts.append(pageText)
            if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scannedPages.append(index)
            }
        }

        return (texts: texts, scannedPages: scannedPages)
    }

    // MARK: - Redaction box location

    /// Locates visual bounding boxes for a set of surface texts so the redactor
    /// can paint opaque rectangles over the detected PII.
    ///
    /// For each (text, token) pair this scans every page with PDFPage based
    /// selection search (PDFDocument.findString) and converts each selection's
    /// bounds on its page into a RedactionBox in PDF/CoreGraphics page
    /// coordinates. Empty surface texts are skipped. A surface text that appears
    /// multiple times produces one box per occurrence.
    public static func redactionBoxes(
        in url: URL,
        surfaceTexts: [(text: String, token: String)]
    ) -> [RedactionBox] {
        guard let document = PDFDocument(url: url) else {
            return []
        }

        // Map each page object to its zero-based index for fast lookup when a
        // selection reports the page it falls on.
        var pageIndexByPage: [PDFPage: Int] = [:]
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) {
                pageIndexByPage[page] = index
            }
        }

        var boxes: [RedactionBox] = []

        for entry in surfaceTexts {
            let needle = entry.text
            if needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            var boxesForEntry: [RedactionBox] = []
            let selections = document.findString(needle, withOptions: .caseInsensitive)
            for selection in selections {
                for page in selection.pages {
                    guard let pageIndex = pageIndexByPage[page] else { continue }
                    let rect = selection.bounds(for: page)
                    if rect.isNull || rect.isEmpty {
                        continue
                    }
                    boxesForEntry.append(
                        RedactionBox(pageIndex: pageIndex, rect: rect, token: entry.token)
                    )
                }
            }

            // Fallback for visually split PII. PDFDocument.findString matches the
            // needle only as a contiguous run in the text layer, so a name broken
            // across two lines of a table cell, or across a column break, is
            // detected in the extracted text (where the layout is already
            // flattened) but produces NO selection here. The consequence is a
            // review PDF that still SHOWS a value the app reports as redacted,
            // which is the worst kind of miss in this app.
            //
            // The fallback searches each page with whitespace normalized on both
            // sides, then converts the matched character range into one box PER
            // LINE, so a two-line name gets two boxes that actually cover it
            // rather than one rect spanning the gap between them.
            if boxesForEntry.isEmpty {
                boxesForEntry = normalizedSearchBoxes(
                    needle: needle,
                    token: entry.token,
                    in: document
                )
            }

            boxes.append(contentsOf: boxesForEntry)
        }

        return boxes
    }

    // MARK: - Whitespace-normalized fallback search

    /// Find `needle` on every page with whitespace normalized, and return one
    /// box per line of each match.
    ///
    /// Internal rather than private so the cross-line behavior is directly
    /// testable; the production entry point is redactionBoxes(in:surfaceTexts:).
    static func normalizedSearchBoxes(
        needle: String,
        token: String,
        in document: PDFDocument
    ) -> [RedactionBox] {
        let normalizedNeedle = normalizeWhitespace(needle).text
        guard !normalizedNeedle.isEmpty else { return [] }

        var boxes: [RedactionBox] = []
        for pageIndex in 0 ..< document.pageCount {
            guard let page = document.page(at: pageIndex), let pageText = page.string else {
                continue
            }
            let normalized = normalizeWhitespace(pageText)
            guard !normalized.text.isEmpty else { continue }

            // Search and index in ONE space: UTF-16 code units. NSString's
            // case-insensitive search returns UTF-16 offsets directly, and
            // originalIndexes carries one entry per UTF-16 unit of the
            // normalized text, so the two line up by construction. The earlier
            // version mixed spaces: it indexed the map with Character
            // (grapheme) distances, so any decomposed accent in the page text
            // (Jose + combining acute, which PDF ToUnicode maps do produce)
            // shifted every later match and painted boxes over the WRONG
            // glyphs while unboxedTokenCount stayed zero. Lowercasing the
            // haystack was part of the same trap: lowercasing can change
            // UTF-16 length (Turkish dotted I), so the search uses the
            // caseInsensitive option instead of transforming either string.
            let haystack = normalized.text as NSString
            var searchStart = 0
            while searchStart < haystack.length {
                let found = haystack.range(
                    of: normalizedNeedle,
                    options: [.caseInsensitive],
                    range: NSRange(location: searchStart, length: haystack.length - searchStart)
                )
                guard found.location != NSNotFound, found.length > 0 else { break }
                let originalIndexes = Array(
                    normalized.originalIndexes[found.location ..< found.location + found.length]
                )
                boxes.append(
                    contentsOf: lineBoxes(
                        for: originalIndexes,
                        on: page,
                        pageIndex: pageIndex,
                        token: token
                    )
                )
                searchStart = found.location + found.length
            }
        }
        return boxes
    }

    /// A whitespace-normalized copy of text plus, for each UTF-16 code unit of
    /// the normalized text, the UTF-16 index it came from in the original.
    ///
    /// Normalization collapses every run of whitespace to a single space and
    /// trims the ends. INVARIANT: originalIndexes.count == text.utf16.count,
    /// one entry per unit, so a UTF-16 search range over `text` indexes the map
    /// directly. Keeping the map per-unit (not per-character) is what makes
    /// decomposed accents and surrogate pairs safe: a combining mark is its own
    /// unit with its own entry, and a supplementary-plane character contributes
    /// two units and two entries.
    static func normalizeWhitespace(_ text: String) -> (text: String, originalIndexes: [Int]) {
        let source = text as NSString
        var output = ""
        var indexes: [Int] = []
        var previousWasSpace = true // leading whitespace is dropped

        var index = 0
        while index < source.length {
            let unit = source.character(at: index)

            // Assemble a surrogate pair into its scalar so supplementary-plane
            // characters survive normalization; both of the pair's units get an
            // index entry to preserve the per-unit invariant. A lone surrogate
            // (malformed text layer) is dropped, which keeps the map aligned.
            let scalar: Unicode.Scalar
            var unitWidth = 1
            if UTF16.isLeadSurrogate(unit), index + 1 < source.length,
               UTF16.isTrailSurrogate(source.character(at: index + 1)) {
                // Combine the pair arithmetically (U+10000 plus the two 10-bit
                // halves); both halves are range-checked above, so the scalar
                // initializer cannot fail.
                let high = UInt32(unit - 0xD800)
                let low = UInt32(source.character(at: index + 1) - 0xDC00)
                scalar = Unicode.Scalar(0x10000 + (high << 10) + low)!
                unitWidth = 2
            } else if let simple = Unicode.Scalar(unit), !UTF16.isLeadSurrogate(unit),
                      !UTF16.isTrailSurrogate(unit) {
                scalar = simple
            } else {
                index += 1
                continue
            }

            // Collapse the PDFKit non-breaking-space artifact ("A with
            // circumflex" followed by a space-like unit) to one space, the same
            // repair PdfTextNormalizer applied on import. Without this the
            // needle searched here comes from repaired text while the page
            // haystack still carries the marker, so the needle never matches:
            // the value would be detected and reported yet never boxed, leaving
            // it VISIBLE in a PDF the app calls redacted. The marker is a
            // letter, so no whitespace rule would collapse it. Both units map
            // to the marker index, which keeps the per-unit invariant and lets
            // the box cover the artifact glyph itself.
            if scalar.value == 0x00C2, index + 1 < source.length,
               let next = Unicode.Scalar(source.character(at: index + 1)),
               next.value == 0x00A0 || next.value == 0x0020 {
                if !previousWasSpace {
                    output.append(" ")
                    indexes.append(index)
                    previousWasSpace = true
                }
                index += 2
                continue
            }

            if Character(scalar).isWhitespace {
                if !previousWasSpace {
                    output.append(" ")
                    indexes.append(index)
                    previousWasSpace = true
                }
                index += unitWidth
                continue
            }

            output.unicodeScalars.append(scalar)
            indexes.append(index)
            if unitWidth == 2 {
                indexes.append(index + 1)
            }
            previousWasSpace = false
            index += unitWidth
        }

        // Drop a trailing collapsed space so a match at the end is not padded.
        if output.hasSuffix(" ") {
            output.removeLast()
            indexes.removeLast()
        }
        return (output, indexes)
    }

    /// Convert a run of original character indexes into one rect per visual line.
    ///
    /// A new line starts when the next character's rect does not overlap the
    /// current run vertically. Emitting per-line rects is the point: a single
    /// union rect over a two-line match would paint a band across whatever sits
    /// between the two lines, and a bounding rect of the two lines' extremes can
    /// still leave the actual glyphs partly uncovered.
    private static func lineBoxes(
        for originalIndexes: [Int],
        on page: PDFPage,
        pageIndex: Int,
        token: String
    ) -> [RedactionBox] {
        let characterCount = page.numberOfCharacters
        var boxes: [RedactionBox] = []
        var current: CGRect?

        for index in originalIndexes {
            guard index >= 0, index < characterCount else { continue }
            let rect = page.characterBounds(at: index)
            if rect.isNull || rect.isEmpty { continue }

            guard let running = current else {
                current = rect
                continue
            }
            if verticallyOverlaps(running, rect) {
                current = running.union(rect)
            } else {
                boxes.append(RedactionBox(pageIndex: pageIndex, rect: running, token: token))
                current = rect
            }
        }
        if let running = current {
            boxes.append(RedactionBox(pageIndex: pageIndex, rect: running, token: token))
        }
        return boxes
    }

    /// True when two glyph rects share enough vertical extent to be the same
    /// line of text. Compared against the shorter rect's height so a tall glyph
    /// does not swallow the line below it.
    private static func verticallyOverlaps(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        guard overlap > 0 else { return false }
        return overlap >= min(lhs.height, rhs.height) * 0.5
    }
}
