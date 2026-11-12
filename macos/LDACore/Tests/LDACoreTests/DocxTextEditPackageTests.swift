//
//  DocxTextEditPackageTests.swift
//  LDACoreTests
//
//  Found 2026-11-11: a .docx saved by macOS TextEdit, or converted with
//  textutil -convert docx, was refused by every privacy export (Save
//  Redacted, lda anonymize, lda batch) with "1 part of this document hold
//  content the redactor cannot clean". Apple's Cocoa OOXML writer adds
//  docProps/meta.xml, a custom XML part in Apple's metadata schema that the
//  main document part links with a customXml relationship, and the package
//  policy refused it as an unknown member.
//
//  The export now drops that part with its relationship, as it drops a custom
//  XML data store, and never copies what it holds. Parts the export genuinely
//  cannot clean still refuse it, and the refusal reads correctly for one part
//  and for several.
//
//  The fixture is synthetic and follows the package textutil wrote on
//  2026-11-11 (CocoaOOXMLWriter/2775.2) member for member: the body in
//  TextEdit's run markup, a theme, core and app properties, and the Apple
//  metadata part with its customXml relationship and no content-type
//  override. Every name is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxTextEditPackageTests: XCTestCase {

    // MARK: - Fixture

    static let person = "Jordan Ellis"
    static let counterparty = "Marek Okafor"
    static let company = "Brightwater Holdings LLC"
    static let email = "jordan.ellis@example.com"
    static let phone = "+1 212 555 0148"

    /// Every value of the source document that must not survive the export.
    static let sourceValues = [person, counterparty, company, email, phone]

    /// docProps/meta.xml exactly as TextEdit writes it.
    static let appleMetadataXML = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        + #"<meta xmlns="http://schemas.apple.com/cocoa/2006/metadata">"#
        + "<generator>CocoaOOXMLWriter/2775.2</generator></meta>"

    /// The main part's relationships, as TextEdit numbers them: the metadata
    /// part is a customXml target outside word/, then the theme.
    static let textEditDocumentRelationships = [
        #"<Relationship Id="rId1" "#
            + #"Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/customXml" "#
            + #"Target="../docProps/meta.xml"/>"#,
        #"<Relationship Id="rId2" "#
            + #"Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" "#
            + #"Target="theme/theme1.xml"/>"#
    ]

    /// TextEdit's run properties: Times, the size in w:sz and in its own
    /// w:sz-cs, no character spacing.
    static let textEditRunProperties = #"<w:rPr><w:rFonts w:ascii="Times" w:hAnsi="Times" w:cs="Times"/>"#
        + #"<w:sz w:val="24"/><w:sz-cs w:val="24"/><w:spacing w:val="0"/></w:rPr>"#

    static func textEditParagraph(_ text: String) -> String {
        #"<w:p><w:pPr><w:spacing w:after="240"/></w:pPr><w:r>"# + textEditRunProperties
            + #"<w:t xml:space="preserve">"# + xmlEncode(text) + "</w:t></w:r></w:p>"
    }

    /// A list item as TextEdit writes one: the bullet is literal text between
    /// tabs in a run of its own, the item text follows in another.
    static func textEditBullet(_ text: String) -> String {
        #"<w:p><w:pPr><w:ind w:left="720" w:first-line="-720"/></w:pPr><w:r>"# + textEditRunProperties
            + #"<w:t xml:space="preserve"/><w:tab/><w:t xml:space="preserve">"# + "\u{2022}"
            + #"</w:t><w:tab/><w:t xml:space="preserve"/></w:r><w:r>"# + textEditRunProperties
            + #"<w:t xml:space="preserve">"# + xmlEncode(text) + "</w:t></w:r></w:p>"
    }

    static let body = [
        textEditParagraph("Engagement memo"),
        textEditParagraph("Client contact: \(person), \(email), \(phone)."),
        textEditParagraph("Counterparty: \(counterparty) of \(company)."),
        textEditBullet("First call with \(person)"),
        textEditBullet("Draft terms for \(company)")
    ].joined() + "<w:sectPr></w:sectPr>"

    /// The core properties textutil writes from -author, -title and -editor.
    static let coreXML = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        + #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" "#
        + #"xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" "#
        + #"xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">"#
        + "<dc:title>Engagement memo</dc:title><dc:creator>\(person)</dc:creator>"
        + "<cp:lastModifiedBy>\(counterparty)</cp:lastModifiedBy></cp:coreProperties>"

    /// The extended properties textutil writes from -company.
    static let appXML = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        + #"<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" "#
        + #"xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">"#
        + "<Company>\(company)</Company></Properties>"

    static let themeXML = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        + #"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme">"#
        + "<a:themeElements/></a:theme>"

    /// What a model reports for the body; the locator ignores values a text
    /// does not hold.
    static let reported = #"""
    {"entities":[{"value":"Jordan Ellis","type":"PERSON"},{"value":"Marek Okafor","type":"PERSON"},{"value":"Brightwater Holdings LLC","type":"COMPANY"}],"redacted_text":""}
    """#

    private struct FixedCompleter: TextCompleter {
        let output: String
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String { output }
    }

    private static let passphrase = "docx-textedit-package"

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocxTextEditPackageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        LDAService.makeExtractorForTesting = { _ in LLMExtractor(completer: FixedCompleter(output: Self.reported)) }
    }

    override func tearDownWithError() throws {
        LDAService.makeExtractorForTesting = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        try super.tearDownWithError()
    }

    /// The TextEdit package, with `metadataXML` as its docProps/meta.xml and
    /// `extraParts` added.
    private func writeTextEditDocx(
        named name: String = "memo.docx",
        metadataXML: String = DocxTextEditPackageTests.appleMetadataXML,
        extraParts: [(String, String)] = []
    ) throws -> URL {
        try DocxTestPackage.write(
            body: Self.body,
            extraParts: [
                ("word/theme/theme1.xml", Self.themeXML),
                ("docProps/core.xml", Self.coreXML),
                ("docProps/app.xml", Self.appXML),
                ("docProps/meta.xml", metadataXML)
            ] + extraParts,
            extraDocumentRelationships: Self.textEditDocumentRelationships,
            to: workDir.appendingPathComponent(name)
        )
    }

    private func outputDir() -> URL {
        workDir.appendingPathComponent("out", isDirectory: true)
    }

    private func anonymize(_ input: URL) throws -> AnonymizeResult {
        try LDAService.anonymize(
            input: input,
            outputDir: outputDir(),
            protection: .passphrase(Self.passphrase),
            createdAtISO8601: "2026-11-11T00:00:00Z",
            llmModelPath: workDir.appendingPathComponent("model.gguf").path
        )
    }

    // MARK: - The fixture is the package TextEdit writes

    /// The fixture carries the metadata part where TextEdit puts it, so the
    /// assertions below test removal, not absence; and the policy drops that
    /// part and refuses nothing else in the package.
    func testTheFixtureLinksTheAppleMetadataPartAsTextEditDoes() throws {
        let input = try writeTextEditDocx()

        let paths = try DocxTestPackage.allMembers(in: input).map(\.path)
        for path in ["docProps/meta.xml", "word/theme/theme1.xml", "docProps/core.xml", "docProps/app.xml"] {
            XCTAssertTrue(paths.contains(path), "\(path) missing from \(paths.sorted())")
        }
        XCTAssertEqual(try DocxTestPackage.readPart("docProps/meta.xml", from: input), Self.appleMetadataXML)
        let rels = try DocxTestPackage.readPart("word/_rels/document.xml.rels", from: input)
        XCTAssertTrue(rels.contains(#"relationships/customXml" Target="../docProps/meta.xml""#), rels)
        let types = try DocxTestPackage.readPart("[Content_Types].xml", from: input)
        XCTAssertFalse(types.contains("meta.xml"), "TextEdit writes no override for the part: \(types)")

        let classified = DocxPackagePolicy.classify(paths: paths)
        XCTAssertEqual(classified.dropped, ["docProps/meta.xml"])
        XCTAssertEqual(classified.unsupported, [], "nothing else in a TextEdit package refuses the export")
    }

    // MARK: - The export

    /// The export succeeds, the metadata part and its relationship are gone,
    /// the rest of the package stays, and no member carries a source value.
    func testATextEditDocumentExportsWithoutTheAppleMetadataPart() throws {
        let result = try anonymize(try writeTextEditDocx())
        let output = result.redactedFileURL

        let members = try DocxTestPackage.allMembers(in: output)
        let paths = members.map(\.path)
        XCTAssertFalse(paths.contains { $0.lowercased() == "docprops/meta.xml" }, "\(paths.sorted())")
        for path in ["word/document.xml", "word/theme/theme1.xml", "docProps/core.xml", "docProps/app.xml"] {
            XCTAssertTrue(paths.contains(path), "\(path) should stay: \(paths.sorted())")
        }

        let rels = try DocxTestPackage.readPart("word/_rels/document.xml.rels", from: output)
        XCTAssertFalse(rels.contains("meta.xml"), "dangling relationship: \(rels)")
        XCTAssertTrue(rels.contains(#"Target="theme/theme1.xml""#), "the theme relationship stays: \(rels)")
        let types = try DocxTestPackage.readPart("[Content_Types].xml", from: output)
        XCTAssertFalse(types.contains("meta.xml"), types)

        for member in members {
            XCTAssertNil(
                member.data.range(of: Data("CocoaOOXMLWriter".utf8)),
                "\(member.path) carries the Apple metadata part's content"
            )
            for value in Self.sourceValues {
                XCTAssertNil(
                    member.data.range(of: Data(value.utf8)),
                    "\(member.path) still carries a source value after the export"
                )
            }
        }

        let text = try DocxImporter().importDocument(output).text
        XCTAssertTrue(text.contains("{EMAIL_1}"), text)
        XCTAssertTrue(text.contains("{PERSON_1}"), text)
        XCTAssertTrue(text.contains("{COMPANY_1}"), text)
    }

    /// Apple publishes no schema for the part, so a later writer may put more
    /// in it. Whatever it holds leaves with it, even a value nothing detects
    /// and the leak audit therefore does not look for.
    func testWhateverTheAppleMetadataPartHoldsNeverRidesOut() throws {
        let undetected = "Halvorsen Quarry Trust"
        let metadata = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
            + #"<meta xmlns="http://schemas.apple.com/cocoa/2006/metadata">"#
            + "<generator>CocoaOOXMLWriter/2775.2</generator><author>\(undetected)</author>"
            + "<contact>\(Self.email)</contact></meta>"
        let result = try anonymize(try writeTextEditDocx(metadataXML: metadata))

        for member in try DocxTestPackage.allMembers(in: result.redactedFileURL) {
            XCTAssertNil(member.data.range(of: Data(undetected.utf8)), "\(member.path) carries the part's value")
            XCTAssertNil(member.data.range(of: Data(Self.email.utf8)), "\(member.path) carries the part's value")
        }
    }

    /// The redacted copy restores to the document TextEdit saved.
    func testATextEditExportRestoresToTheSourceText() throws {
        let input = try writeTextEditDocx()
        let source = try DocxImporter().importDocument(input).text
        for value in Self.sourceValues {
            XCTAssertTrue(source.contains(value), "fixture: the body holds \(value)")
        }

        let result = try anonymize(input)
        let restoredURL = workDir.appendingPathComponent("restored.docx")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase(Self.passphrase),
            output: restoredURL
        )

        XCTAssertTrue(report.orphanTokens.isEmpty, "\(report.orphanTokens)")
        XCTAssertTrue(report.suspectPlaceholders.isEmpty, "\(report.suspectPlaceholders)")
        XCTAssertEqual(try DocxImporter().importDocument(restoredURL).text, source)
    }

    // MARK: - Parts the redactor cannot clean still refuse

    /// SmartArt data, a chart, an embedded workbook and a glossary document
    /// carry content the export can neither redact nor drop. Added to a
    /// TextEdit package, each still refuses the export, the message counts
    /// the part without naming it, and nothing is written.
    func testPartsTheRedactorCannotCleanStillRefuseTheExport() throws {
        let uncleanable: [(String, String)] = [
            (
                "word/diagrams/data1.xml",
                #"<dgm:dataModel xmlns:dgm="http://schemas.openxmlformats.org/drawingml/2006/diagram">"#
                    + "\(Self.person)</dgm:dataModel>"
            ),
            (
                "word/charts/chart1.xml",
                #"<c:chartSpace xmlns:c="http://schemas.openxmlformats.org/drawingml/2006/chart">"#
                    + "<c:v>\(Self.person)</c:v></c:chartSpace>"
            ),
            ("word/embeddings/Microsoft_Excel_Worksheet1.xlsx", "not a real workbook, \(Self.person)"),
            (
                "word/glossary/document.xml",
                "<w:glossaryDocument xmlns:w=\"\(DocxTestPackage.wordNamespace)\"><w:docParts><w:docPart>"
                    + "<w:docPartBody><w:p><w:r><w:t>\(Self.person)</w:t></w:r></w:p></w:docPartBody>"
                    + "</w:docPart></w:docParts></w:glossaryDocument>"
            )
        ]
        for (index, part) in uncleanable.enumerated() {
            let name = "uncleanable-\(index)"
            let input = try writeTextEditDocx(named: "\(name).docx", extraParts: [part])

            XCTAssertThrowsError(try anonymize(input), part.0) { error in
                guard case DocumentIOError.unsupportedFormat(let detail) = error else {
                    return XCTFail("\(part.0): expected an unsupported-part refusal, got \(error)")
                }
                XCTAssertTrue(detail.contains("1 part of this document holds content"), "\(part.0): \(detail)")
                XCTAssertFalse(detail.contains(part.0), "a part path can itself be PII: \(detail)")
            }
            let written = (try? FileManager.default.contentsOfDirectory(atPath: outputDir().path)) ?? []
            XCTAssertFalse(written.contains { $0.contains(name) }, "\(part.0): a refused export wrote \(written)")
        }
    }

    /// The refusal agrees with its count.
    func testTheRefusalReadsCorrectlyForOnePartAndForSeveral() throws {
        guard case DocumentIOError.unsupportedFormat(let one) = DocxPackagePolicy.unsupportedPartsError(count: 1),
              case DocumentIOError.unsupportedFormat(let three) = DocxPackagePolicy.unsupportedPartsError(count: 3)
        else {
            return XCTFail("the refusal is an unsupported-format error")
        }
        XCTAssertTrue(one.hasPrefix("1 part of this document holds content the redactor cannot clean"), one)
        XCTAssertTrue(three.hasPrefix("3 parts of this document hold content the redactor cannot clean"), three)

        let input = try writeTextEditDocx(named: "two-parts.docx", extraParts: [
            ("word/diagrams/data1.xml", "<dgm:dataModel/>"),
            ("word/charts/chart1.xml", "<c:chartSpace/>")
        ])
        XCTAssertThrowsError(try anonymize(input)) { error in
            guard case DocumentIOError.unsupportedFormat(let detail) = error else {
                return XCTFail("expected an unsupported-part refusal, got \(error)")
            }
            XCTAssertTrue(detail.contains("2 parts of this document hold content"), detail)
        }
    }
}
