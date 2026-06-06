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
            pageCount: pageCount
        )
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
    public static func ocrBoxes(
        in url: URL,
        matching surfaceTexts: [(text: String, token: String)]
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

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            guard let cgImage = try? render(page: page) else { continue }
            guard let observations = try? recognize(in: cgImage) else { continue }

            let mediaBox = page.bounds(for: .mediaBox)

            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else {
                    continue
                }
                let recognized = candidate.string.lowercased()
                guard !recognized.isEmpty else { continue }

                for entry in needles where recognized.contains(entry.needle) {
                    let rect = pageRect(
                        fromNormalized: observation.boundingBox,
                        mediaBox: mediaBox
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

    // MARK: - Rendering

    /// Rasterizes a single PDF page into a CGImage at renderDPI.
    private static func render(page: PDFPage) throws -> CGImage {
        let pageRect = page.bounds(for: .mediaBox)
        let scale = renderDPI / pdfPointsPerInch

        let pixelWidth = Int((pageRect.width * scale).rounded())
        let pixelHeight = Int((pageRect.height * scale).rounded())

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
        // Shift so the page media box origin maps to the context origin.
        context.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
        page.draw(with: .mediaBox, to: context)
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

    /// Maps a Vision normalized bounding box (origin bottom-left, 0 through 1)
    /// into PDF page coordinates using the page media box.
    ///
    /// PDF/CoreGraphics page coordinates also use a bottom-left origin, so the
    /// vertical axis does not need flipping; we only scale by the media box size
    /// and offset by its origin.
    private static func pageRect(
        fromNormalized box: CGRect,
        mediaBox: CGRect
    ) -> CGRect {
        CGRect(
            x: mediaBox.origin.x + box.origin.x * mediaBox.width,
            y: mediaBox.origin.y + box.origin.y * mediaBox.height,
            width: box.width * mediaBox.width,
            height: box.height * mediaBox.height
        )
    }
}
