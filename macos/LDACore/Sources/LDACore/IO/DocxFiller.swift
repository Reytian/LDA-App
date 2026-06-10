//
//  DocxFiller.swift
//  LDACore
//
//  Run-preserving blank filling for .docx targets. Filling is the same
//  span-replacement operation DocxRedactor performs for redaction, with the
//  fill value as the written string, so this stays a thin wrapper and the
//  formatting guarantees are inherited rather than reimplemented.
//
//  Offsets: DocxFill.span uses UTF-16 offsets into DocxImporter's text for the
//  SAME original file, matching the Replacement contract.
//
//  XML escaping of special characters (& < >) is handled by the existing
//  DocxDocumentXML serialization layer that DocxRedactor already routes through,
//  so no custom escaping is required or written here.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// One confirmed fill: where in the document, and what value to write.
public struct DocxFill: Equatable, Sendable {
    /// The span (UTF-16 offsets into DocxImporter's text) that identifies the
    /// blank to replace.
    public var span: Span
    /// The plain-text value to write in place of the blank.
    public var value: String

    public init(span: Span, value: String) {
        self.span = span
        self.value = value
    }
}

/// Fills blanks in a .docx template by delegating to DocxRedactor.redact.
///
/// Because a fill is just a span-replacement with an arbitrary value as the
/// written string, the run-preservation and XML-escaping guarantees of
/// DocxRedactor apply without any additional work here.
public enum DocxFiller {

    /// Apply confirmed fills to `original` and write the result to `out`.
    /// The original file is never modified.
    ///
    /// The output is a filled document, not a redacted edit surface; do not pass it to DocxRedactor.restore.
    ///
    /// - Parameters:
    ///   - original: The source .docx whose blanks are to be filled.
    ///   - fills: One `DocxFill` per blank, each carrying a UTF-16 span into
    ///     the text produced by `DocxImporter().importDocument(original)` and
    ///     the value to write at that span.
    ///   - out: Destination URL for the filled .docx.
    /// - Throws: `DocumentIOError` on read or write failure.
    public static func fill(original: URL, fills: [DocxFill], to out: URL) throws {
        let replacements = fills.map { Replacement(span: $0.span, token: $0.value) } // Replacement.token carries the fill value here (not a grammar token).
        try DocxRedactor.redact(original: original, replacements: replacements, to: out)
    }
}
