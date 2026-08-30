//
//  IOTypes.swift
//  LDACore
//
//  Frozen public contract for Phase 3 (DocumentIO) and Phase 4 (MappingStore).
//  This file declares ONLY the shared types and the importer protocol. The
//  concrete units listed at the bottom are implemented by downstream agents.
//
//  Offset convention: ImportedDocument.text uses UTF-16 code-unit offsets, the
//  same NSRange-compatible convention as Span in CoreTypes.swift. A Replacement
//  references a Span in that text, so its offsets are UTF-16 too.
//
//  Edit-surface model (V1): the universal round-trip edit surface is a generated
//  companion (.docx or .txt) carrying the tokenized text. PDF is never edited in
//  place.
//   - .docx INPUT: a redacted .docx that preserves original formatting by
//     substituting tokens on the runs (w:t) of word/document.xml IS the edit
//     surface; restore substitutes token -> value back on those same runs.
//   - plain text INPUT: the redacted .txt is the edit surface.
//   - PDF INPUT (born-digital OR scanned): extract text, then generate a fresh
//     .docx/.txt companion (simple formatting) as the edit surface, PLUS a
//     redacted PDF for visual review (opaque boxes over detected PII regions).
//     Restore happens on the edited companion, not the PDF.
//
//  Token model: tokens are unique opaque strings like {PERSON_1} matching the
//  grammar TokenGrammar.placeholderPattern (\{[A-Z][A-Z0-9]*_\d+\}). During
//  restore a token always lives within a single run, so per-run find/replace of
//  token -> value is correct and safe.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import CoreGraphics

// MARK: - Document format

/// The input/output document formats DocumentIO understands.
public enum DocumentFormat: String, Sendable, Codable {
    case plainText
    case docx
    case pdf
    /// A standalone raster image (png / jpg / jpeg) whose text is recovered
    /// through OCR. The redacted edit surface is a companion .txt; the visual
    /// artifact is a boxes-over-PII PNG.
    case image
}

// MARK: - Imported document

/// A document after import and text extraction, ready for the detection engine.
///
/// text is the normalized full text; its UTF-16 offsets align with the engine's
/// Spans. isScanned is true only when a PDF had no usable text layer and OCR was
/// used to recover the text.
public struct ImportedDocument: Sendable {
    /// Normalized full text; UTF-16 offsets align with engine Spans.
    public var text: String
    /// The detected source format.
    public var format: DocumentFormat
    /// True when a PDF had no usable text layer at all and OCR was used for
    /// the entire document.
    public var isScanned: Bool
    /// Number of pages (1 for plain text and single-page surfaces).
    public var pageCount: Int
    /// Zero-based indexes of PDF pages that carry no usable text layer. For a
    /// fully scanned PDF this is every page; for a hybrid PDF (born-digital
    /// pages plus scanned exhibit or signature pages) it is the subset that
    /// needs OCR. Empty for non-PDF formats and fully born-digital PDFs.
    public var scannedPageIndexes: [Int]

    public init(
        text: String,
        format: DocumentFormat,
        isScanned: Bool,
        pageCount: Int,
        scannedPageIndexes: [Int] = []
    ) {
        self.text = text
        self.format = format
        self.isScanned = isScanned
        self.pageCount = pageCount
        self.scannedPageIndexes = scannedPageIndexes
    }
}

// MARK: - Replacement

/// A span in ImportedDocument.text to be replaced by an opaque token.
public struct Replacement: Sendable, Equatable {
    /// The span (UTF-16 offsets) in ImportedDocument.text.
    public var span: Span
    /// The opaque token that replaces the span, for example "{PERSON_1}".
    public var token: String

    public init(span: Span, token: String) {
        self.span = span
        self.token = token
    }
}

// MARK: - Redaction box

/// A visual box used to paint over PII in the redacted PDF review output.
public struct RedactionBox: Sendable, Equatable {
    /// Zero-based page index this box belongs to.
    public var pageIndex: Int
    /// The rectangle (PDF/CoreGraphics coordinates) to paint opaque.
    public var rect: CGRect
    /// The token this box corresponds to.
    public var token: String

    public init(pageIndex: Int, rect: CGRect, token: String) {
        self.pageIndex = pageIndex
        self.rect = rect
        self.token = token
    }
}

// MARK: - Image-origin observation

/// A piece of text recovered by OCR from an embedded image region (not the text
/// layer). rect is in PDF/CoreGraphics page coordinates; pageIndex is zero-based.
public struct ImageTextObservation: Sendable, Equatable {
    public var pageIndex: Int
    public var rect: CGRect
    public var text: String

    public init(pageIndex: Int, rect: CGRect, text: String) {
        self.pageIndex = pageIndex
        self.rect = rect
        self.text = text
    }
}

// MARK: - Errors

/// Errors raised by the DocumentIO and Security layers.
public enum DocumentIOError: Error, LocalizedError, Sendable {
    /// The file could not be read at all. Associated value is a detail string.
    case unreadable(String)
    /// The format is recognized but not supported. Associated value is a detail.
    case unsupportedFormat(String)
    /// The file is structurally corrupt. Associated value is a detail string.
    case corrupt(String)
    /// OCR was required but unavailable on this system.
    case ocrUnavailable
    /// A protected document could not be decrypted.
    case decryptionFailed
    /// A Keychain operation failed; carries the OSStatus from Security.framework.
    case keychainError(OSStatus)
    /// The input exceeded an ImportLimits ceiling (document size, archive
    /// payload, or archive entry count). Associated value is a user-facing
    /// detail naming the file and the limit.
    case tooLarge(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return "Could not read the document: \(detail)"
        case .unsupportedFormat(let detail):
            return "Unsupported format: \(detail)"
        case .corrupt(let detail):
            return "The document is corrupt: \(detail)"
        case .ocrUnavailable:
            return "OCR is required but unavailable on this system."
        case .decryptionFailed:
            return "Could not decrypt the document (wrong passphrase or tampered file)."
        case .keychainError(let status):
            return "Keychain operation failed with status \(status)."
        case .tooLarge(let detail):
            return "The file is too large to import: \(detail)"
        }
    }
}

// MARK: - Importer protocol

/// A document importer for one or more formats. Implementations extract a
/// normalized ImportedDocument whose text aligns with engine Spans.
public protocol DocumentImporter {
    /// Returns true when this importer can handle the file at url.
    func canImport(_ url: URL) -> Bool
    /// Imports and normalizes the document, or throws DocumentIOError.
    func importDocument(_ url: URL) throws -> ImportedDocument
}

// MARK: - Downstream units (NOT implemented here)
//
// The following unit types will be added by downstream agents. They are listed
// here for orientation only; this file freezes only the contract above.
//
// - TextDocumentIO: plain-text import plus redacted .txt edit-surface write and
//   token -> value restore.
// - DocxImporter: DocumentImporter for .docx; unzips and extracts run text from
//   word/document.xml (uses ZIPFoundation).
// - DocxRedactor: run-preserving redact (substitute token on w:t runs) plus
//   token -> value restore on those same runs; the redacted .docx is the edit
//   surface.
// - PdfImporter: born-digital PDF text extraction via PDFKit.
// - PdfOCRImporter: scanned-PDF text recovery via Vision; sets isScanned = true.
// - PdfRedactor: paints RedactionBox regions opaque to produce the review PDF.
// - CompanionWriter: writeText / writeDocx to generate the companion edit
//   surface for PDF inputs.
// - MappingStore (Phase 4): persists Mapping to disk, keyed/encrypted with a
//   Keychain-held key; surfaces keychainError(OSStatus) on failure.
