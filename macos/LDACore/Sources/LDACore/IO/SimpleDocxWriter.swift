//
//  SimpleDocxWriter.swift
//  LDACore
//
//  The restored-output fidelity floor for the AI round-trip (R8): when the
//  external AI returns an edited or generated document as text/Markdown and
//  the user wants a Word file back, this writer produces a clean, minimal
//  .docx (one paragraph per line). This matches the agreed design floor: a
//  clean regenerated document, not a pixel-perfect copy of the original.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

/// Writes a minimal, valid .docx from plain text.
public enum SimpleDocxWriter {

    /// Write `text` as a fresh Word document: each line becomes a paragraph,
    /// XML-escaped, with spaces preserved.
    public static func write(_ text: String, to url: URL) throws {
        let parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypesXML.utf8)),
            ("_rels/.rels", Data(relsXML.utf8)),
            ("word/document.xml", Data(documentXML(for: text).utf8))
        ]
        try DocxZip.writeArchive(parts: parts, to: url)
    }

    // MARK: - Parts

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let relsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    /// The main document part: one <w:p> per input line. xml:space="preserve"
    /// keeps leading and trailing spaces.
    private static func documentXML(for text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let paragraphs = lines.map { line in
            let cleaned = line.hasSuffix("\r") ? String(line.dropLast()) : line
            return "<w:p><w:r><w:t xml:space=\"preserve\">"
                + xmlEncode(cleaned)
                + "</w:t></w:r></w:p>"
        }.joined()

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        """
        + paragraphs
        + "</w:body></w:document>"
    }
}
