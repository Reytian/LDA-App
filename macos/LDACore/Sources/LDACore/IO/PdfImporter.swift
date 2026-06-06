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
    /// - pageCount comes from the document.
    public func importDocument(_ url: URL) throws -> ImportedDocument {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DocumentIOError.unreadable("File not found at \(url.path)")
        }

        guard let document = PDFDocument(url: url) else {
            throw DocumentIOError.corrupt("PDFKit could not open the document at \(url.path)")
        }

        let pageCount = document.pageCount

        var pageTexts: [String] = []
        pageTexts.reserveCapacity(pageCount)
        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            pageTexts.append(page.string ?? "")
        }

        let text = pageTexts.joined(separator: pageSeparator)

        let isScanned = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return ImportedDocument(
            text: text,
            format: .pdf,
            isScanned: isScanned,
            pageCount: pageCount
        )
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

            let selections = document.findString(needle, withOptions: .caseInsensitive)
            for selection in selections {
                for page in selection.pages {
                    guard let pageIndex = pageIndexByPage[page] else { continue }
                    let rect = selection.bounds(for: page)
                    if rect.isNull || rect.isEmpty {
                        continue
                    }
                    boxes.append(
                        RedactionBox(pageIndex: pageIndex, rect: rect, token: entry.token)
                    )
                }
            }
        }

        return boxes
    }
}
