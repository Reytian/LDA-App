//
//  CompanionWriter.swift
//  LDACore
//
//  Generates the companion edit surface for inputs that cannot be edited in
//  place (PDF) and, more generally, anywhere a fresh tokenized companion is
//  needed. Two output shapes are supported:
//   - writeText: a plain UTF-8 .txt file carrying the tokenized text.
//   - writeDocx: a minimal but valid .docx built from scratch with ZIPFoundation,
//     one paragraph per line of tokenized text. The result opens in Word and
//     round-trips its text through DocxImporter.
//
//  The .docx is assembled with exactly the parts a conforming consumer needs:
//  [Content_Types].xml, _rels/.rels, and word/document.xml. Text is XML-escaped
//  so tokens like {PERSON_1} and arbitrary line content survive the round trip.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ZIPFoundation

// MARK: - CompanionWriter

/// Writes companion edit-surface files (plain text or minimal .docx) carrying
/// tokenized text.
public enum CompanionWriter {
    // MARK: Plain text

    /// Writes the tokenized text to the given URL as UTF-8. Throws
    /// DocumentIOError.unreadable when encoding or writing fails.
    public static func writeText(_ tokenizedText: String, to url: URL) throws {
        try TextDocumentIO.exportText(tokenizedText, to: url)
    }

    // MARK: Minimal .docx

    /// Builds a minimal valid .docx at the given URL. The body contains one
    /// paragraph (w:p/w:r/w:t) per line of tokenizedText, with text XML-escaped.
    ///
    /// Any pre-existing file at the URL is removed first so the archive is built
    /// fresh. Throws DocumentIOError.corrupt when the archive cannot be created
    /// or written.
    public static func writeDocx(_ tokenizedText: String, to url: URL) throws {
        // Start from a clean path. ZIPFoundation's create mode expects no file to
        // exist at the destination.
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw DocumentIOError.corrupt(
                    "Could not clear existing file at \(url.path): \(error.localizedDescription)"
                )
            }
        }

        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .create)
        } catch {
            throw DocumentIOError.corrupt(
                "Could not create .docx archive at \(url.path): \(error.localizedDescription)"
            )
        }

        let parts: [(path: String, data: Data)] = [
            ("[Content_Types].xml", Data(contentTypesXML.utf8)),
            ("_rels/.rels", Data(relsXML.utf8)),
            ("word/document.xml", Data(documentXML(for: tokenizedText).utf8))
        ]

        for part in parts {
            do {
                try archive.addEntry(
                    with: part.path,
                    type: .file,
                    uncompressedSize: Int64(part.data.count),
                    compressionMethod: .deflate,
                    provider: { position, size in
                        let start = Int(position)
                        let end = min(start + size, part.data.count)
                        guard start < end else { return Data() }
                        return part.data.subdata(in: start ..< end)
                    }
                )
            } catch {
                throw DocumentIOError.corrupt(
                    "Could not add \(part.path) to .docx at \(url.path): \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: Fixed XML parts

    /// The [Content_Types].xml declaring the default part extensions and the main
    /// document part. Word requires the rels default and the wordprocessing
    /// document content type to open the file.
    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Override PartName="/word/document.xml" \
    ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    </Types>
    """

    /// The package-level _rels/.rels pointing at the main document part.
    private static let relsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" \
    Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
    Target="word/document.xml"/>\
    </Relationships>
    """

    // MARK: Document body

    /// The WordprocessingML namespace used on the document root.
    private static let wordprocessingNamespace =
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    /// Builds word/document.xml with one paragraph per line of the input. Empty
    /// lines still produce an empty paragraph so the line structure round-trips.
    private static func documentXML(for text: String) -> String {
        // Split on newlines while keeping empty trailing lines so the paragraph
        // count matches the visible line count. CRLF and bare CR split exactly
        // like LF: a raw CR must never reach w:t content (Word renders it as a
        // stray break and rewrites the document on save). Text import already
        // normalizes line endings, but other producers (PDFKit page text) can
        // still carry CR, so this stays defensive.
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var body = ""
        for line in lines {
            let escaped = xmlEscape(line)
            // xml:space="preserve" keeps leading and trailing spaces intact.
            body += "<w:p><w:r><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r></w:p>"
        }

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="\(wordprocessingNamespace)"><w:body>\(body)</w:body></w:document>
        """
    }

    /// XML-escapes the five predefined entities so token braces and arbitrary
    /// line text are safe inside w:t. Ampersand is replaced first so later
    /// replacements do not double-escape it.
    private static func xmlEscape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }
}
