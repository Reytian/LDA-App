//
//  DocxFixtureSupport.swift
//  LDACoreTests
//
//  Shared builder for small but structurally honest .docx fixtures: runs that
//  carry their OWN run properties (so a test can tell a bold run from an
//  italic one after a round trip), an optional header part, and a styles part
//  whose bytes a fidelity test can compare before and after. Everything is
//  built in code with the library's own zip writer, so no binary fixtures are
//  committed and every test stays hermetic.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
@testable import LDACore

enum DocxFixtureSupport {

    // MARK: - Runs

    /// One w:r element: its visible text and the inner XML of its w:rPr
    /// (empty for a run with no run properties).
    struct Run {
        let text: String
        let properties: String

        static func plain(_ text: String) -> Run { Run(text: text, properties: "") }
        static func bold(_ text: String) -> Run { Run(text: text, properties: "<w:b/>") }
        static func italic(_ text: String) -> Run { Run(text: text, properties: "<w:i/>") }
    }

    // MARK: - Fixed parts

    private static let wordNamespace =
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let relationshipsNamespace =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    /// A small styles part. Fidelity tests compare these bytes before and after
    /// a round trip, so the content only needs to be stable, not rich.
    static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="\(wordNamespace)">
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/>
    <w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman"/><w:sz w:val="24"/></w:rPr></w:style>
    <w:style w:type="character" w:styleId="Strong"><w:name w:val="Strong"/><w:rPr><w:b/></w:rPr></w:style>
    </w:styles>
    """

    // MARK: - Building

    /// Write a .docx package whose body holds `paragraphs` and, when given,
    /// whose default header holds `header`. Every package carries a styles part
    /// and the relationships Word expects, so it is a real (if minimal) document.
    static func write(
        paragraphs: [[Run]],
        header: [[Run]]? = nil,
        to url: URL
    ) throws {
        var overrides = """
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        """
        var documentRelationships = """
        <Relationship Id="rId1" Type="\(relationshipsNamespace)/styles" Target="styles.xml"/>
        """
        var sectionProperties = ""
        var parts: [(String, Data)] = []

        if let header {
            overrides += """

            <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
            """
            documentRelationships += """

            <Relationship Id="rId2" Type="\(relationshipsNamespace)/header" Target="header1.xml"/>
            """
            sectionProperties = "<w:sectPr><w:headerReference w:type=\"default\" r:id=\"rId2\"/></w:sectPr>"
            let headerXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:hdr xmlns:w="\(wordNamespace)">\(paragraphsXML(header))</w:hdr>
            """
            parts.append(("word/header1.xml", Data(headerXML.utf8)))
        }

        let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        \(overrides)
        </Types>
        """
        let packageRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="\(relationshipsNamespace)/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        let documentRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(documentRelationships)
        </Relationships>
        """
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="\(wordNamespace)" xmlns:r="\(relationshipsNamespace)">
        <w:body>\(paragraphsXML(paragraphs))\(sectionProperties)</w:body>
        </w:document>
        """

        parts = [
            ("[Content_Types].xml", Data(contentTypesXML.utf8)),
            ("_rels/.rels", Data(packageRelsXML.utf8)),
            ("word/_rels/document.xml.rels", Data(documentRelsXML.utf8)),
            ("word/document.xml", Data(documentXML.utf8)),
            ("word/styles.xml", Data(stylesXML.utf8))
        ] + parts
        try DocxZip.writeArchive(parts: parts, to: url)
    }

    /// The w:p elements for a list of paragraphs, each run with its own w:rPr.
    static func paragraphsXML(_ paragraphs: [[Run]]) -> String {
        var body = ""
        for runs in paragraphs {
            body += "<w:p>"
            for run in runs {
                body += "<w:r>"
                if !run.properties.isEmpty {
                    body += "<w:rPr>\(run.properties)</w:rPr>"
                }
                body += "<w:t xml:space=\"preserve\">\(xmlEscape(run.text))</w:t></w:r>"
            }
            body += "</w:p>"
        }
        return body
    }

    // MARK: - Reading

    /// The raw bytes of one package entry.
    static func partData(_ path: String, in url: URL) throws -> Data {
        try DocxZip.readEntry(path, from: url)
    }

    /// One package entry decoded as UTF-8 text.
    static func part(_ path: String, in url: URL) throws -> String {
        String(decoding: try partData(path, in: url), as: UTF8.self)
    }

    /// The document's visible body text, the way the importer sees it.
    static func bodyText(of url: URL) throws -> String {
        try DocxImporter().importDocument(url).text
    }

    // MARK: - Simulated human edits

    /// Simulate a human editing the body in Word: rewrite document.xml with one
    /// string replacement and copy every other entry byte for byte. The edit is
    /// made in the raw XML so run properties around it stay exactly as they were.
    static func editingBody(
        of source: URL,
        replacing target: String,
        with replacement: String,
        to destination: URL
    ) throws {
        let body = try part(docxMainPartPath, in: source)
        guard body.contains(target) else {
            throw DocumentIOError.corrupt("fixture edit target is not in the body")
        }
        let edited = body.replacingOccurrences(of: target, with: replacement)
        try DocxZip.rewrite(
            source: source,
            replacing: [docxMainPartPath: Data(edited.utf8)],
            to: destination
        )
    }

    // MARK: - Escaping

    /// XML-escape text for inclusion in w:t (the five predefined entities).
    static func xmlEscape(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }
}
