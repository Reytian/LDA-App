//
//  DocxTestPackage.swift
//  LDACoreTests
//
//  Hand-built OOXML fixtures for the .docx fidelity tests. The older suites
//  build paragraphs out of plain run strings; the run-level fidelity tests
//  need raw run markup (w:tab, w:br, w:delText, field instructions, revision
//  authors), so this helper takes body XML verbatim and wraps it in a
//  minimal, valid package. Extra parts (headers, footers, comments, styles,
//  numbering, people) receive their content-type overrides and a relationship
//  from the main document part, so the package shape matches what Word writes.
//
//  House rules: all comments and strings in English. Fixture values may be
//  Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import Foundation
import XCTest
import ZIPFoundation
@testable import LDACore

enum DocxTestPackage {

    static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let relationshipsNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let w15Namespace = "http://schemas.microsoft.com/office/word/2012/wordml"

    /// Relationship ids the fixture assigns to its supplementary parts, for
    /// use in a body's w:sectPr references.
    static let headerRelationshipId = "rIdHeader1"
    static let footerRelationshipId = "rIdFooter1"

    // MARK: - Markup builders

    /// One w:r carrying `text` in a w:t. `preserve` adds xml:space="preserve",
    /// which Word writes whenever the text starts or ends with whitespace.
    /// `trailing` is raw markup appended after the w:t (a w:tab or w:br).
    static func run(
        _ text: String,
        rPr: String? = nil,
        preserve: Bool = false,
        trailing: String = ""
    ) -> String {
        let props = rPr.map { "<w:rPr>\($0)</w:rPr>" } ?? ""
        let open = preserve ? "<w:t xml:space=\"preserve\">" : "<w:t>"
        return "<w:r>\(props)\(open)\(xmlEncode(text))</w:t>\(trailing)</w:r>"
    }

    static func paragraph(_ runs: String..., pPr: String? = nil) -> String {
        paragraph(runs: runs, pPr: pPr)
    }

    static func paragraph(runs: [String], pPr: String? = nil) -> String {
        let props = pPr.map { "<w:pPr>\($0)</w:pPr>" } ?? ""
        return "<w:p>\(props)\(runs.joined())</w:p>"
    }

    /// A w:sectPr that binds the fixture's header and footer parts.
    static let sectionWithHeaderAndFooter = """
    <w:sectPr><w:headerReference w:type="default" r:id="\(headerRelationshipId)"/>\
    <w:footerReference w:type="default" r:id="\(footerRelationshipId)"/>\
    <w:pgSz w:w="11906" w:h="16838"/></w:sectPr>
    """

    /// Wrap body XML in the main document part.
    static func documentXML(body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="\(wordNamespace)" xmlns:r="\(relationshipsNamespace)">
        <w:body>\(body)</w:body>
        </w:document>
        """
    }

    /// Wrap a header, footer, notes, or comments body in its root element.
    static func wordPart(rootTag: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:\(rootTag) xmlns:w="\(wordNamespace)" xmlns:r="\(relationshipsNamespace)">\(body)</w:\(rootTag)>
        """
    }

    // MARK: - Package assembly

    /// Write a package whose main part body is `body`. `extraParts` are
    /// (path, xml) pairs such as ("word/header1.xml", ...). `extraDocumentRelationships`
    /// are raw <Relationship .../> elements appended to document.xml.rels
    /// (for example an external mailto hyperlink target).
    @discardableResult
    static func write(
        body: String,
        extraParts: [(String, String)] = [],
        extraDocumentRelationships: [String] = [],
        to url: URL
    ) throws -> URL {
        var parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes(for: extraParts.map { $0.0 }).utf8)),
            ("_rels/.rels", Data(packageRelationships.utf8)),
            ("word/document.xml", Data(documentXML(body: body).utf8)),
            (
                "word/_rels/document.xml.rels",
                Data(documentRelationships(
                    for: extraParts.map { $0.0 },
                    extra: extraDocumentRelationships
                ).utf8)
            )
        ]
        for (path, xml) in extraParts {
            parts.append((path, Data(xml.utf8)))
        }
        try DocxZip.writeArchive(parts: parts, to: url)
        return url
    }

    static func readPart(_ path: String, from url: URL) throws -> String {
        let data = try DocxZip.readEntry(path, from: url)
        guard let xml = String(data: data, encoding: .utf8) else {
            throw DocumentIOError.corrupt("\(path) is not UTF-8")
        }
        return xml
    }

    /// Every file entry of the package as (path, UTF-8 text), so a test can
    /// assert a value appears in NO part at all. Non-UTF-8 entries are skipped.
    static func allTextParts(in url: URL) throws -> [(path: String, xml: String)] {
        let archive = try Archive(url: url, accessMode: .read)
        var parts: [(path: String, xml: String)] = []
        for entry in archive where entry.type == .file {
            var collected = Data()
            _ = try archive.extract(entry) { collected.append($0) }
            guard let xml = String(data: collected, encoding: .utf8) else { continue }
            parts.append((entry.path, xml))
        }
        return parts
    }

    /// Build a UTF-16 span from a surface's first occurrence in text.
    static func span(in text: String, surface: String, type: EntityType) -> Span {
        let ns = text as NSString
        let range = ns.range(of: surface)
        precondition(range.location != NSNotFound, "surface not found in text: \(surface)")
        return Span(
            start: range.location,
            end: range.location + range.length,
            type: type,
            text: surface,
            source: .deterministic,
            confidence: 0.9,
            priority: 0
        )
    }

    // MARK: - Package plumbing

    private static let officeDocumentPrefix = "application/vnd.openxmlformats-officedocument.wordprocessingml."

    private static func contentType(for path: String) -> String? {
        if path.hasPrefix("word/header") { return officeDocumentPrefix + "header+xml" }
        if path.hasPrefix("word/footer") { return officeDocumentPrefix + "footer+xml" }
        switch path {
        case "word/document.xml": return officeDocumentPrefix + "document.main+xml"
        case "word/footnotes.xml": return officeDocumentPrefix + "footnotes+xml"
        case "word/endnotes.xml": return officeDocumentPrefix + "endnotes+xml"
        case "word/comments.xml": return officeDocumentPrefix + "comments+xml"
        case "word/styles.xml": return officeDocumentPrefix + "styles+xml"
        case "word/numbering.xml": return officeDocumentPrefix + "numbering+xml"
        case "word/people.xml": return officeDocumentPrefix + "people+xml"
        case "docProps/core.xml": return "application/vnd.openxmlformats-package.core-properties+xml"
        case "docProps/app.xml": return "application/vnd.openxmlformats-officedocument.extended-properties+xml"
        default: return nil
        }
    }

    private static func contentTypes(for extraPaths: [String]) -> String {
        var overrides = ""
        for path in ["word/document.xml"] + extraPaths {
            guard let type = contentType(for: path) else { continue }
            overrides += "<Override PartName=\"/\(path)\" ContentType=\"\(type)\"/>\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        \(overrides)</Types>
        """
    }

    private static let packageRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="\(relationshipsNamespace)/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    /// The relationship (id, type) the main part declares for a supplementary part.
    private static func documentRelationship(for path: String) -> (id: String, type: String)? {
        switch path {
        case "word/header1.xml": return (headerRelationshipId, relationshipsNamespace + "/header")
        case "word/footer1.xml": return (footerRelationshipId, relationshipsNamespace + "/footer")
        case "word/footnotes.xml": return ("rIdFootnotes", relationshipsNamespace + "/footnotes")
        case "word/endnotes.xml": return ("rIdEndnotes", relationshipsNamespace + "/endnotes")
        case "word/comments.xml": return ("rIdComments", relationshipsNamespace + "/comments")
        case "word/styles.xml": return ("rIdStyles", relationshipsNamespace + "/styles")
        case "word/numbering.xml": return ("rIdNumbering", relationshipsNamespace + "/numbering")
        case "word/people.xml":
            return ("rIdPeople", "http://schemas.microsoft.com/office/2011/relationships/people")
        default: return nil
        }
    }

    private static func documentRelationships(for extraPaths: [String], extra: [String]) -> String {
        var elements = ""
        for path in extraPaths {
            guard let rel = documentRelationship(for: path) else { continue }
            let target = String(path.dropFirst("word/".count))
            elements += "<Relationship Id=\"\(rel.id)\" Type=\"\(rel.type)\" Target=\"\(target)\"/>\n"
        }
        for element in extra {
            elements += element + "\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(elements)</Relationships>
        """
    }
}
