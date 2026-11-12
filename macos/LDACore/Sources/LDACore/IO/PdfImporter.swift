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
            // Soft line breaks are joined so a name wrapped at the margin reaches
            // detection, the placeholders and the AI in one piece (PdfLineReflow).
            let pageText = PdfLineReflow.joinSoftBreaks(
                PdfTextNormalizer.normalize(document.page(at: index)?.string ?? "")
            )
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
        return redactionCoverage(in: url, surfaceTexts: surfaceTexts).boxes
    }

    /// Locate the boxes AND report coverage per occurrence.
    ///
    /// Both searches run for every value and their results are merged. The
    /// earlier shape ran the whitespace-normalized search only as a FALLBACK
    /// for a value with no exact match ANYWHERE in the document, so a name
    /// printed normally on one page and wrapped across two lines on another got
    /// a box on the normal page only, and a coverage count that asked merely
    /// whether SOME box carried the token then called the value covered while
    /// the wrapped page kept the original pixels.
    public static func redactionCoverage(
        in url: URL,
        surfaceTexts: [(text: String, token: String)]
    ) -> PdfRedactionCoverage {
        guard let document = PDFDocument(url: url) else {
            return PdfRedactionCoverage()
        }

        // Map each page object to its zero-based index for fast lookup when a
        // selection reports the page it falls on.
        var pageIndexByPage: [PDFPage: Int] = [:]
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) {
                pageIndexByPage[page] = index
            }
        }
        // Normalize each page ONCE. The normalized search now runs for every
        // value rather than only for the values the exact search missed, so
        // re-normalizing per value would cost pages times values.
        let pages = normalizedPages(of: document)

        var located: [PdfTextOccurrence] = []
        for entry in surfaceTexts {
            if entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            located += occurrences(
                of: entry,
                in: document,
                pageIndexByPage: pageIndexByPage,
                normalizedPages: pages
            )
        }
        return PdfRedactionCoverage(occurrences: PdfRedactionCoverage.assigningSites(
            located, surfaceTexts: surfaceTexts
        ))
    }

    /// Both search paths for one value, merged into one occurrence set.
    ///
    /// PDFDocument.findString matches the needle only as a contiguous run in
    /// the text layer, so a name broken across two lines of a table cell, or
    /// across a column break, is detected in the extracted text (where the
    /// layout is already flattened) but produces NO selection. The
    /// whitespace-normalized page search sees both shapes, and emits one box
    /// PER LINE so a two-line name gets two boxes that actually cover it
    /// rather than one rect spanning the gap between them.
    private static func occurrences(
        of entry: (text: String, token: String),
        in document: PDFDocument,
        pageIndexByPage: [PDFPage: Int],
        normalizedPages pages: [NormalizedPage]
    ) -> [PdfTextOccurrence] {
        let exact = exactOccurrences(
            needle: entry.text,
            token: entry.token,
            in: document,
            pageIndexByPage: pageIndexByPage
        )
        // A contiguous occurrence is seen by BOTH searches. Its boxes are the
        // union of the two: PDFKit's selection bounds can sit several glyphs
        // to one side of the text they select (a CJK line in the review's
        // probe was boxed four characters to the left, leaving "有限公司"
        // visible), while the normalized search reads each glyph's own bounds.
        // Over-covering is safe; under-covering is the leak (review
        // 2026-11-11, F6).
        var merged = exact
        for candidate in normalizedOccurrences(needle: entry.text, token: entry.token, pages: pages) {
            if let index = merged.firstIndex(where: { isSameOccurrence($0, candidate) }) {
                // A glyph box the selection already covers adds nothing; one
                // it misses is the part the selection left visible.
                let missed = candidate.boxes.filter { box in
                    !merged[index].boxes.contains { $0.rect.insetBy(dx: -1, dy: -1).contains(box.rect) }
                }
                merged[index].boxes += missed
            } else {
                merged.append(candidate)
            }
        }
        return merged
    }

    /// True when two occurrences describe the same place on the same page.
    ///
    /// Compared by rect intersection rather than by text offset because the
    /// exact search reports geometry (a PDFSelection's bounds) and never a
    /// character range, so geometry is the only space the two paths share.
    /// Rects that merely TOUCH do not intersect, so two occurrences printed
    /// side by side on one line stay separate. An occurrence with no boxes
    /// matches nothing and therefore survives the filter, which is the safe
    /// direction: it gets reported as uncovered.
    private static func isSameOccurrence(
        _ lhs: PdfTextOccurrence,
        _ rhs: PdfTextOccurrence
    ) -> Bool {
        guard lhs.pageIndex == rhs.pageIndex else { return false }
        if let left = lhs.textRange, let right = rhs.textRange { return left == right }
        return lhs.boxes.contains { left in
            rhs.boxes.contains { $0.rect.intersects(left.rect) }
        }
    }

    /// One occurrence per contiguous selection page, from PDFKit's own search.
    ///
    /// A selection whose bounds are null or empty yields no occurrence at all,
    /// which leaves the normalized search free to locate that instance instead
    /// of the value silently losing its box.
    private static func exactOccurrences(
        needle: String,
        token: String,
        in document: PDFDocument,
        pageIndexByPage: [PDFPage: Int]
    ) -> [PdfTextOccurrence] {
        var found: [PdfTextOccurrence] = []
        for selection in document.findString(needle, withOptions: .caseInsensitive) {
            for page in selection.pages {
                guard let pageIndex = pageIndexByPage[page] else { continue }
                let rect = selection.bounds(for: page)
                if rect.isNull || rect.isEmpty { continue }
                found.append(
                    PdfTextOccurrence(
                        pageIndex: pageIndex,
                        token: token,
                        boxes: [RedactionBox(pageIndex: pageIndex, rect: rect, token: token)],
                        textRange: selection.numberOfTextRanges(on: page) == 1
                            ? selection.range(at: 0, on: page) : nil,
                        matchedText: selection.string
                    )
                )
            }
        }
        return found
    }

    // MARK: - Whitespace-normalized search

    /// Find `needle` on every page with whitespace normalized, and return one
    /// box per line of each match.
    ///
    /// Internal rather than private so the cross-line behavior is directly
    /// testable; the production entry point is redactionCoverage(in:surfaceTexts:).
    static func normalizedSearchBoxes(
        needle: String,
        token: String,
        in document: PDFDocument
    ) -> [RedactionBox] {
        return normalizedOccurrences(
            needle: needle,
            token: token,
            pages: normalizedPages(of: document)
        ).flatMap(\.boxes)
    }

    /// A page, its whitespace-normalized text, and the map back into the page's
    /// own UTF-16 offsets. Built once per document and reused for every value.
    struct NormalizedPage {
        let page: PDFPage
        let pageIndex: Int
        let haystack: NSString
        let originalIndexes: [Int]
    }

    /// Normalize every page that carries text. Pages with no text layer are
    /// omitted; their PII is boxed by the OCR channel instead.
    static func normalizedPages(of document: PDFDocument) -> [NormalizedPage] {
        var pages: [NormalizedPage] = []
        for pageIndex in 0 ..< document.pageCount {
            guard let page = document.page(at: pageIndex), let pageText = page.string else {
                continue
            }
            let normalized = normalizeWhitespace(pageText)
            guard !normalized.text.isEmpty else { continue }
            pages.append(
                NormalizedPage(
                    page: page,
                    pageIndex: pageIndex,
                    haystack: normalized.text as NSString,
                    originalIndexes: normalized.originalIndexes
                )
            )
        }
        return pages
    }

    /// Every whitespace-tolerant match of `needle`, one occurrence per match.
    ///
    /// An occurrence whose glyph geometry could not be read carries NO boxes
    /// rather than being dropped, so the caller can report it.
    static func normalizedOccurrences(
        needle: String,
        token: String,
        pages: [NormalizedPage]
    ) -> [PdfTextOccurrence] {
        let normalizedNeedle = normalizeWhitespace(needle).text
        guard !normalizedNeedle.isEmpty else { return [] }

        var found: [PdfTextOccurrence] = []
        for entry in pages {
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
            var searchStart = 0
            while searchStart < entry.haystack.length {
                let range = entry.haystack.range(
                    of: normalizedNeedle,
                    options: [.caseInsensitive],
                    range: NSRange(
                        location: searchStart,
                        length: entry.haystack.length - searchStart
                    )
                )
                guard range.location != NSNotFound, range.length > 0 else { break }
                let originalIndexes = Array(
                    entry.originalIndexes[range.location ..< range.location + range.length]
                )
                let sourceRange = NSRange(
                    location: originalIndexes[0],
                    length: originalIndexes[originalIndexes.count - 1] - originalIndexes[0] + 1
                )
                let pageText = (entry.page.string ?? "") as NSString
                found.append(
                    PdfTextOccurrence(
                        pageIndex: entry.pageIndex,
                        token: token,
                        boxes: lineBoxes(
                            for: originalIndexes,
                            on: entry.page,
                            pageIndex: entry.pageIndex,
                            token: token
                        ),
                        textRange: sourceRange,
                        matchedText: pageText.substring(with: sourceRange)
                    )
                )
                searchStart = range.location + range.length
            }
        }
        return found
    }

    /// A whitespace-normalized copy of text plus, for each UTF-16 code unit of
    /// the normalized text, the UTF-16 index it came from in the original.
    ///
    /// Normalization collapses every run of whitespace to a single space,
    /// drops it altogether between two CJK characters (a Chinese name wrapped
    /// at the margin holds no space: the page text has "华光精密" + newline +
    /// "仪器有限公司" where the document text, joined by PdfLineReflow, has the
    /// name in one piece; review 2026-11-11, F6), and trims the ends. INVARIANT: originalIndexes.count == text.utf16.count,
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
        // The space a whitespace run will become, written only once the next
        // character shows it is not between two CJK characters.
        var pendingSpace: Int?
        var lastScalar: Unicode.Scalar?
        func emit(_ scalar: Unicode.Scalar, at index: Int, width: Int) {
            if let space = pendingSpace {
                if !(lastScalar.map(PdfLineReflow.isWide) == true && PdfLineReflow.isWide(scalar)) {
                    output.append(" ")
                    indexes.append(space)
                }
                pendingSpace = nil
            }
            output.unicodeScalars.append(scalar)
            indexes.append(index)
            if width == 2 { indexes.append(index + 1) }
            lastScalar = scalar
            previousWasSpace = false
        }

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

            // Collapse the PDFKit non-breaking-space artifact to one space,
            // the same repair PdfTextNormalizer applied on import; see
            // isNbspArtifactPair for why. Both units map to the marker index,
            // which keeps the per-unit invariant and lets the box cover the
            // artifact glyph itself.
            if scalar.value == UInt32(PdfTextNormalizer.artifactMarkerUnit),
               isNbspArtifactPair(at: index, in: source) {
                if !previousWasSpace {
                    pendingSpace = index
                    previousWasSpace = true
                }
                index += 2
                continue
            }

            if Character(scalar).isWhitespace {
                if !previousWasSpace {
                    pendingSpace = index
                    previousWasSpace = true
                }
                index += unitWidth
                continue
            }

            emit(scalar, at: index, width: unitWidth)
            index += unitWidth
        }

        // A trailing whitespace run is dropped (pendingSpace is never
        // written), so a match at the end is not padded.
        return (output, indexes)
    }

    /// True when the units at `index` form the PDFKit non-breaking-space
    /// artifact PdfTextNormalizer repairs on import: U+00C2 followed by a
    /// space-like unit. The marker is a LETTER, so no whitespace rule would
    /// collapse it. normalizeWhitespace must mirror the import-time repair
    /// because the needle it searches for comes from the repaired document
    /// text while this raw page haystack still carries the marker; without
    /// the mirror the value would be detected and reported yet never boxed,
    /// leaving it VISIBLE in a PDF the app calls redacted.
    private static func isNbspArtifactPair(at index: Int, in source: NSString) -> Bool {
        guard source.character(at: index) == PdfTextNormalizer.artifactMarkerUnit,
              index + 1 < source.length else { return false }
        let next = source.character(at: index + 1)
        return next == PdfTextNormalizer.nonBreakingSpaceUnit
            || next == PdfTextNormalizer.plainSpaceUnit
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
        // PDFKit's own selection for the matched range, one rect per line.
        // characterBounds(at:) can drift from the page string by one index per
        // line break (in the review's CJK probe the wrapped half of a name was
        // boxed one glyph to the right, leaving 仪 visible, and a line further
        // down four glyphs off), while a selection made from the same range
        // lands on the glyphs (review 2026-11-11, F6). The glyph rects remain
        // the fallback when PDFKit gives no selection.
        if let first = originalIndexes.min(), let last = originalIndexes.max(),
           let selection = page.selection(for: NSRange(location: first, length: last - first + 1)) {
            let boxes = selection.selectionsByLine().compactMap { line -> RedactionBox? in
                let rect = line.bounds(for: page)
                guard !rect.isNull, !rect.isEmpty else { return nil }
                return RedactionBox(pageIndex: pageIndex, rect: rect, token: token)
            }
            if !boxes.isEmpty { return boxes }
        }
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
