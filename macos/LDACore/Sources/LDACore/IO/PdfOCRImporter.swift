//
//  PdfOCRImporter.swift
//  LDACore
//
//  DocumentImporter for SCANNED / image-only PDFs (no usable text layer). Uses
//  the Vision framework for OCR, PDFKit to access pages, and CoreGraphics to
//  rasterize each page before recognition.
//
//  Pipeline:
//   - Render each PDF page to a CGImage at a readable DPI.
//   - Run VNRecognizeTextRequest (accurate, language-corrected, en-US + zh-Hans)
//     on each rasterized page.
//   - Concatenate recognized strings in reading order (top to bottom), joining
//     pages with a blank line.
//   - Return ImportedDocument(text:, format: .pdf, isScanned: true, pageCount:).
//
//  This importer never edits the PDF in place. The recovered text becomes a
//  fresh companion edit surface elsewhere; here we only recover text and, on
//  request, expose per-observation bounding boxes so a caller can paint visual
//  redaction boxes on scanned pages.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import CoreGraphics
import PDFKit
import Vision

/// A DocumentImporter for scanned, image-only PDFs. Recovers text through Vision
/// OCR and reports isScanned = true on the produced ImportedDocument.
public struct PdfOCRImporter: DocumentImporter {

    // MARK: - Tunables

    /// Render DPI for rasterizing PDF pages before OCR. 200 dpi is a good balance
    /// between recognition quality and memory use for typical scanned documents.
    private static let renderDPI: CGFloat = 200.0

    /// The nominal PDF user-space resolution. PDF coordinates are 72 units per
    /// inch, so the render scale is renderDPI / 72.
    private static let pdfPointsPerInch: CGFloat = 72.0

    /// Languages requested from Vision, in priority order.
    private static let recognitionLanguages: [String] = ["en-US", "zh-Hans"]

    public init() {}

    // MARK: - DocumentImporter

    public func canImport(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    /// Imports a scanned PDF by running OCR over every page.
    ///
    /// Throws DocumentIOError.unreadable when the PDF cannot be opened, and
    /// DocumentIOError.ocrUnavailable when Vision is unavailable or recognition
    /// fails on any page.
    public func importDocument(_ url: URL) throws -> ImportedDocument {
        try ImportLimits.enforceDocumentSize(at: url)
        guard let document = PDFDocument(url: url) else {
            throw DocumentIOError.unreadable(
                "PDFDocument could not open file at \(url.path)"
            )
        }

        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw DocumentIOError.corrupt("PDF has zero pages")
        }

        var pageTexts: [String] = []
        pageTexts.reserveCapacity(pageCount)

        for pageIndex in 0..<pageCount {
            guard let page = document.page(at: pageIndex) else {
                throw DocumentIOError.corrupt(
                    "PDF page \(pageIndex) could not be accessed"
                )
            }

            let cgImage = try Self.render(page: page)
            let lines = try Self.recognizeLines(in: cgImage)
            pageTexts.append(lines.joined(separator: "\n"))
        }

        let fullText = pageTexts.joined(separator: "\n\n")

        return ImportedDocument(
            text: fullText,
            format: .pdf,
            isScanned: true,
            pageCount: pageCount,
            scannedPageIndexes: Array(0..<pageCount)
        )
    }

    /// OCRs only the given pages and returns the recovered text per page
    /// index. Used for hybrid PDFs, where born-digital pages keep their text
    /// layer and only the scanned pages need recovery.
    ///
    /// Throws when a requested page cannot be rasterized or recognized: a
    /// silently skipped scanned page would leave its PII out of detection
    /// entirely, which must surface as an error rather than a clean result.
    public static func pageTexts(in url: URL, pages: [Int]) throws -> [Int: String] {
        guard !pages.isEmpty else { return [:] }
        try ImportLimits.enforceDocumentSize(at: url)
        guard let document = PDFDocument(url: url) else {
            throw DocumentIOError.unreadable(
                "PDFDocument could not open file at \(url.path)"
            )
        }

        var result: [Int: String] = [:]
        for pageIndex in pages {
            guard pageIndex >= 0, pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex) else {
                throw DocumentIOError.corrupt(
                    "PDF page \(pageIndex) could not be accessed"
                )
            }
            let cgImage = try render(page: page)
            let lines = try recognizeLines(in: cgImage)
            result[pageIndex] = lines.joined(separator: "\n")
        }
        return result
    }

    // MARK: - Bounding boxes for visual redaction

    /// Runs OCR over every page and returns redaction boxes for observations whose
    /// recognized text contains one of the requested surface texts.
    ///
    /// Vision reports normalized boxes (origin bottom-left, 0 through 1) relative
    /// to the rendered image. We map them into PDF/CoreGraphics page coordinates
    /// using each page's media box so callers can paint opaque rectangles.
    ///
    /// Matching is case-insensitive and substring-based, which tolerates OCR noise
    /// and the fact that one observation line can hold several words. Returns an
    /// empty array when nothing matches or when OCR yields no observations.
    ///
    /// - Parameter pages: when non-nil, only these zero-based page indexes are
    ///   scanned (the hybrid-PDF path passes just the scanned pages); nil scans
    ///   the whole document.
    public static func ocrBoxes(
        in url: URL,
        matching surfaceTexts: [(text: String, token: String)],
        pages: [Int]? = nil
    ) -> [RedactionBox] {
        guard let document = PDFDocument(url: url) else {
            return []
        }

        // Normalize the needles once. Skip empty surface texts so they do not
        // match every observation.
        let needles: [(needle: String, token: String)] = surfaceTexts.compactMap {
            pair in
            let lowered = pair.text.lowercased()
            guard !lowered.isEmpty else { return nil }
            return (needle: lowered, token: pair.token)
        }
        guard !needles.isEmpty else { return [] }

        var boxes: [RedactionBox] = []

        let pageIndexes = pages ?? Array(0..<document.pageCount)
        for pageIndex in pageIndexes {
            guard pageIndex >= 0, pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex) else { continue }
            guard let cgImage = try? render(page: page) else { continue }
            guard let observations = try? recognize(in: cgImage) else { continue }

            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else {
                    continue
                }
                let recognized = candidate.string.lowercased()
                guard !recognized.isEmpty else { continue }

                for entry in needles where recognized.contains(entry.needle) {
                    let rect = pageRect(
                        fromNormalized: observation.boundingBox,
                        page: page
                    )
                    boxes.append(
                        RedactionBox(
                            pageIndex: pageIndex,
                            rect: rect,
                            token: entry.token
                        )
                    )
                    // One box per observation is enough; stop at the first match.
                    break
                }
            }
        }

        return boxes
    }

    // MARK: - Image-origin observations (hybrid text + image PDFs)

    /// Default vertical inset (fraction of rect height) trimmed off the top and
    /// bottom before the text-layer lookup, so the lookup does not bleed into the
    /// line above or below. Width is barely trimmed so the full line text is read.
    private static let dedupVerticalInset: CGFloat = 0.30
    private static let dedupHorizontalInset: CGFloat = 0.05

    /// OCR the given pages and return only the observations the text layer does NOT
    /// already cover, in PDF page coordinates. Used by the image-PII channel for
    /// PDFs that have a text layer but also embed raster images (signatures, stamps).
    ///
    /// Text-layer coverage is decided per observation: inset the observation rect
    /// vertically, read PDFPage.selection(for:)?.string at that rect, and treat the
    /// observation as text-layer (skip) when that selection is non-empty AND shares
    /// a significant word with the OCR text. Otherwise it is image-origin and kept.
    public func imageOriginObservations(in url: URL, pages: [Int]) -> [ImageTextObservation] {
        guard !pages.isEmpty, let document = PDFDocument(url: url) else { return [] }
        var result: [ImageTextObservation] = []

        for pageIndex in pages {
            guard pageIndex >= 0, pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex),
                  let image = try? Self.render(page: page),
                  let observations = try? Self.recognize(in: image) else { continue }

            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                let rect = Self.pageRect(fromNormalized: observation.boundingBox, page: page)
                if Self.textLayerCovers(text: text, rect: rect, page: page) { continue }
                result.append(ImageTextObservation(pageIndex: pageIndex, rect: rect, text: text))
            }
        }
        return result
    }

    /// True when the page's text layer already holds this observation's text.
    private static func textLayerCovers(text: String, rect: CGRect, page: PDFPage) -> Bool {
        let inset = rect.insetBy(dx: rect.width * dedupHorizontalInset,
                                 dy: rect.height * dedupVerticalInset)
        let lookup = inset.isNull || inset.isEmpty ? rect : inset
        guard let selection = page.selection(for: lookup)?.string,
              !TextMatching.normalize(selection).isEmpty else { return false }
        return TextMatching.sharesSignificantWord(text, selection)
    }

    // MARK: - Rendering

    /// Rasterizes a single PDF page into an UPRIGHT CGImage at renderDPI.
    ///
    /// The canvas uses the page's display size (swapped for /Rotate 90/270)
    /// and the content is drawn through the page's rotation transform, so
    /// scanner output stored sideways OCRs in reading orientation. Vision
    /// boxes therefore come back in display space; pageRect(fromNormalized:
    /// page:) maps them into raw content space.
    private static func render(page: PDFPage) throws -> CGImage {
        let displaySize = PdfPageGeometry.displaySize(of: page)
        let scale = renderDPI / pdfPointsPerInch

        let pixelWidth = Int((displaySize.width * scale).rounded())
        let pixelHeight = Int((displaySize.height * scale).rounded())

        guard pixelWidth > 0, pixelHeight > 0 else {
            throw DocumentIOError.corrupt("PDF page has empty media box")
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw DocumentIOError.ocrUnavailable
        }

        // Paint a white background so transparent PDFs OCR cleanly.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        PdfPageGeometry.drawContentUpright(page, in: context)
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw DocumentIOError.ocrUnavailable
        }

        return image
    }

    // MARK: - Recognition

    /// Runs Vision text recognition on a CGImage and returns the recognized
    /// observations sorted in reading order (top to bottom).
    private static func recognize(
        in image: CGImage
    ) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
        } catch {
            throw DocumentIOError.ocrUnavailable
        }

        let observations = request.results ?? []

        // Vision normalized coordinates put the origin at the bottom-left, so a
        // larger midY is higher on the page. Sort by descending midY for natural
        // top-to-bottom reading order, then left to right within a line.
        return observations.sorted { lhs, rhs in
            let lhsY = lhs.boundingBox.midY
            let rhsY = rhs.boundingBox.midY
            if abs(lhsY - rhsY) > 0.01 {
                return lhsY > rhsY
            }
            return lhs.boundingBox.midX < rhs.boundingBox.midX
        }
    }

    /// Recognizes text in an image and returns the top candidate strings in
    /// reading order, one per observation.
    private static func recognizeLines(in image: CGImage) throws -> [String] {
        let observations = try recognize(in: image)
        return observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }
    }

    // MARK: - Coordinate mapping

    /// Maps a Vision normalized bounding box (origin bottom-left, 0 through 1,
    /// relative to the upright raster) into the page's RAW content space.
    ///
    /// The raster is rendered in display space, so the normalized box scales
    /// by the display size and then maps back through the inverse of the
    /// page's content-to-display transform. For an unrotated page this
    /// reduces to the old behavior (scale by the media box and shift by its
    /// origin). Axis-aligned rects stay axis-aligned because the transform is
    /// a multiple-of-90-degrees rotation plus translation.
    private static func pageRect(
        fromNormalized box: CGRect,
        page: PDFPage
    ) -> CGRect {
        let display = PdfPageGeometry.displaySize(of: page)
        let displayRect = CGRect(
            x: box.origin.x * display.width,
            y: box.origin.y * display.height,
            width: box.width * display.width,
            height: box.height * display.height
        )
        let toDisplay = PdfPageGeometry.contentToDisplay(of: page)
        return displayRect.applying(toDisplay.inverted()).standardized
    }
}
