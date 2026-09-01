//
//  ImageTextExtractor.swift
//  LDACore
//
//  DocumentImporter for STANDALONE image evidence (png / jpg / jpeg): chat
//  screenshots, transfer receipts, invoices. Uses the Vision framework for
//  OCR, mirroring PdfOCRImporter's recognition settings, and exposes the
//  per-observation geometry so the image redactor can paint boxes over the
//  ranges detection replaced.
//
//  Seam: detection code consumes only the joined TEXT (ImportedDocument /
//  ImageExtraction.text); the per-line geometry is used exclusively by
//  ImageRedactor. Recognition is injectable (ImageTextRecognizing) so the
//  ordering, range building, and refusal logic stay testable without Vision.
//
//  Honest degrade: an image in which Vision finds no readable text FAILS the
//  import with a clear error. An empty success would let a blank or
//  unreadable image masquerade as a cleanly processed document.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import CoreGraphics
import ImageIO
import Vision

// MARK: - Recognition seam

/// One recognized text line: the candidate string plus its Vision-normalized
/// bounding box (origin bottom-left, 0 through 1, relative to the image).
public struct RecognizedTextLine: Sendable, Equatable {
    public var text: String
    public var normalizedBox: CGRect

    public init(text: String, normalizedBox: CGRect) {
        self.text = text
        self.normalizedBox = normalizedBox
    }
}

/// Text recognition over a CGImage. Production uses Vision; tests inject
/// canned observations so geometry logic is verifiable without OCR.
public protocol ImageTextRecognizing: Sendable {
    func recognizeTextLines(in image: CGImage) throws -> [RecognizedTextLine]
}

/// The production recognizer: VNRecognizeTextRequest in accurate mode with
/// language correction, prioritizing Simplified Chinese for litigation
/// evidence while keeping Latin recognition strong.
public struct VisionImageTextRecognizer: ImageTextRecognizing {

    /// Languages requested from Vision, in priority order. Simplified Chinese
    /// leads because standalone image evidence in this product is dominated by
    /// PRC litigation material; en-US keeps Latin recognition strong.
    private static let recognitionLanguages: [String] = ["zh-Hans", "en-US"]

    public init() {}

    public func recognizeTextLines(in image: CGImage) throws -> [RecognizedTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = Self.recognitionLanguages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw DocumentIOError.ocrUnavailable
        }

        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedTextLine(
                text: candidate.string,
                normalizedBox: observation.boundingBox
            )
        }
    }
}

// MARK: - Extraction result

/// One positioned line of the extraction: its text, its normalized box, and
/// the UTF-16 range it occupies inside the joined extraction text.
public struct ImageTextLine: Sendable, Equatable {
    public var text: String
    public var normalizedBox: CGRect
    public var range: Range<Int>

    public init(text: String, normalizedBox: CGRect, range: Range<Int>) {
        self.text = text
        self.normalizedBox = normalizedBox
        self.range = range
    }
}

/// The full OCR extraction of one image: the joined text detection consumes,
/// the per-line geometry the redactor consumes, and the pixel size.
public struct ImageExtraction: Sendable {
    public var text: String
    public var lines: [ImageTextLine]
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(text: String, lines: [ImageTextLine], pixelWidth: Int, pixelHeight: Int) {
        self.text = text
        self.lines = lines
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

// MARK: - ImageTextExtractor

/// A DocumentImporter for standalone raster images. Recovers text through
/// Vision OCR and reports isScanned = true on the produced ImportedDocument.
public struct ImageTextExtractor: DocumentImporter {

    /// The file extensions this importer recognizes. Lowercased, no dot.
    public static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg"]

    private let recognizer: any ImageTextRecognizing

    public init(recognizer: any ImageTextRecognizing = VisionImageTextRecognizer()) {
        self.recognizer = recognizer
    }

    // MARK: File type recognition

    /// True when the URL is an image by extension OR by magic bytes. The
    /// magic-byte check exists because a PNG that reaches disk under a .txt
    /// name (the vault stores by normalized format) must never fall through
    /// to the text importer, whose Latin-1 fallback would decode the raster
    /// bytes into mojibake and silently "anonymize" garbage.
    public static func isImageFile(_ url: URL) -> Bool {
        if supportedExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        return hasImageMagicBytes(url)
    }

    /// The ONE routing rule every edge shares: a file routes through the
    /// image pipeline when it carries an image extension, or when any OTHER
    /// extension outside docx and pdf carries image magic bytes. The docx and
    /// pdf extensions are exempt from sniffing because their own importers
    /// surface real structural errors for mismatched bytes.
    public static func shouldTreatAsImage(_ url: URL, extension ext: String) -> Bool {
        if supportedExtensions.contains(ext) { return true }
        if ext == "docx" || ext == "pdf" { return false }
        return isImageFile(url)
    }

    /// PNG and JPEG signatures. Neither prefix is decodable as the start of
    /// any real text file (0x89 is an invalid UTF-8 lead byte and 0xFF an
    /// invalid start), so sniffing cannot misroute genuine text.
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
    private static let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]

    /// True when the file starts with a PNG or JPEG signature.
    private static func hasImageMagicBytes(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count >= 4 else {
            return false
        }
        let bytes = [UInt8](head)
        if Array(bytes.prefix(pngSignature.count)) == pngSignature { return true }
        if Array(bytes.prefix(jpegSignature.count)) == jpegSignature { return true }
        return false
    }

    // MARK: DocumentImporter

    public func canImport(_ url: URL) -> Bool {
        Self.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public func importDocument(_ url: URL) throws -> ImportedDocument {
        let extraction = try extract(url)
        return ImportedDocument(
            text: extraction.text,
            format: .image,
            isScanned: true,
            pageCount: 1
        )
    }

    // MARK: Extraction

    /// Run OCR and return the joined text plus per-line geometry. Throws
    /// DocumentIOError.unreadable when the file is not a decodable image or
    /// when no readable text is found in it.
    public func extract(_ url: URL) throws -> ImageExtraction {
        try ImportLimits.enforceDocumentSize(at: url)
        let image = try Self.loadImage(at: url)
        let recognized = try recognizer.recognizeTextLines(in: image)

        // Reading order: Vision normalized coordinates put the origin at the
        // bottom-left, so a larger midY is HIGHER on the image. Sort by
        // descending midY (top to bottom), then left to right within a line,
        // matching PdfOCRImporter's convention.
        let ordered = recognized
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                let lhsY = lhs.normalizedBox.midY
                let rhsY = rhs.normalizedBox.midY
                if abs(lhsY - rhsY) > 0.01 {
                    return lhsY > rhsY
                }
                return lhs.normalizedBox.midX < rhs.normalizedBox.midX
            }

        guard !ordered.isEmpty else {
            throw DocumentIOError.unreadable(
                "No readable text found in the image \(url.lastPathComponent). "
                    + "The image may be blank, too small, or too blurry for OCR."
            )
        }

        // Join with one newline per observation and record each line's UTF-16
        // range inside the joined text, so detection offsets over the text map
        // straight back to line geometry.
        var text = ""
        var lines: [ImageTextLine] = []
        lines.reserveCapacity(ordered.count)
        for (index, line) in ordered.enumerated() {
            let start = text.utf16.count
            text += line.text
            lines.append(
                ImageTextLine(
                    text: line.text,
                    normalizedBox: line.normalizedBox,
                    range: start..<text.utf16.count
                )
            )
            if index < ordered.count - 1 { text += "\n" }
        }

        return ImageExtraction(
            text: text,
            lines: lines,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    // MARK: Image loading

    /// Decode the first frame of the image file. Shared with ImageRedactor so
    /// OCR and painting always operate on the same pixel space (no EXIF
    /// orientation is applied on either side, keeping boxes consistent).
    internal static func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw DocumentIOError.unreadable(
                "\(url.lastPathComponent) could not be decoded as an image."
            )
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        _ = try validatedPixelDimensions(
            in: properties,
            filename: url.lastPathComponent
        )
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DocumentIOError.unreadable(
                "\(url.lastPathComponent) could not be decoded as an image."
            )
        }
        try ImportLimits.enforceDecodedImageSize(
            width: image.width,
            height: image.height,
            filename: url.lastPathComponent
        )
        return image
    }

    /// Read trustworthy positive integer dimensions from first-frame metadata
    /// and enforce the decoded-pixel ceiling before ImageIO allocates the
    /// raster. Missing, fractional, non-finite, or nonpositive dimensions fail
    /// closed because the post-decode check would be too late to bound memory.
    internal static func validatedPixelDimensions(
        in properties: [CFString: Any]?,
        filename: String
    ) throws -> (width: Int, height: Int) {
        guard let properties,
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw DocumentIOError.corrupt(
                "\(filename) does not declare valid positive pixel dimensions."
            )
        }

        func dimension(_ number: NSNumber) throws -> Int {
            let value = number.doubleValue
            guard value.isFinite,
                  value > 0,
                  value.rounded(.towardZero) == value else {
                throw DocumentIOError.corrupt(
                    "\(filename) does not declare valid positive pixel dimensions."
                )
            }
            guard value <= Double(ImportLimits.maxDecodedImagePixels) else {
                throw DocumentIOError.tooLarge(
                    "\(filename) is larger than the 50 megapixel decoded-image limit."
                )
            }
            return Int(value)
        }

        let width = try dimension(widthNumber)
        let height = try dimension(heightNumber)
        try ImportLimits.enforceDecodedImageSize(
            width: width,
            height: height,
            filename: filename
        )
        return (width, height)
    }
}
