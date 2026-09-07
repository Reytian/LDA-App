//
//  DocxImporter.swift
//  LDACore
//
//  A DocumentImporter for .docx packages. It opens the zip, reads
//  word/document.xml, extracts the visible text by concatenating every w:t run
//  in document order (inserting "\n" at w:p paragraph boundaries and at w:br
//  and w:cr line breaks, and "\t" at w:tab elements), and keeps an
//  internal offset map from each character position back to its source run so a
//  later redact pass can target the correct runs.
//
//  Offset convention: ImportedDocument.text uses UTF-16 code-unit offsets, the
//  same NSRange-compatible convention as Span in CoreTypes.swift.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Imports .docx files into an ImportedDocument and, when needed, the richer
/// DocxLayout that carries the run offset map.
public struct DocxImporter: DocumentImporter {
    public init() {}

    /// True when the file has a .docx extension. The actual structural check
    /// happens in importDocument, which throws on a malformed package.
    public func canImport(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "docx"
    }

    /// Import the document and return only the normalized ImportedDocument.
    /// pageCount is always 1 for the V1 edit-surface model; isScanned is false.
    public func importDocument(_ url: URL) throws -> ImportedDocument {
        try importDocxLayout(url).0
    }

    /// Import against a caller-owned ledger, so one user gesture that reads
    /// several documents spends one allowance.
    public func importDocument(_ url: URL, budget: ArchiveBudget) throws -> ImportedDocument {
        try importDocxLayout(url, budget: budget).0
    }

    /// Import the document and also return the internal DocxLayout, which holds
    /// the parsed runs and the offset map needed by DocxRedactor.
    /// budget meters the bytes this import INFLATES. The document-size
    /// ceiling above checks the compressed file, so it alone let a package of
    /// a few hundred bytes expand without limit; see ArchiveBudget.
    func importDocxLayout(
        _ url: URL,
        budget: ArchiveBudget = ArchiveBudget()
    ) throws -> (ImportedDocument, DocxLayout) {
        try ImportLimits.enforceDocumentSize(at: url)
        let data = try DocxZip.readEntry(docxMainPartPath, from: url, budget: budget)
        let layout = try DocxDocumentXML.parse(data)
        let imported = ImportedDocument(
            text: layout.text,
            format: .docx,
            isScanned: false,
            pageCount: 1,
            trackedChangeCount: layout.trackedChangeCount
        )
        return (imported, layout)
    }
}
