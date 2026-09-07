//
//  DocxCustomXMLStripTests.swift
//  LDACoreTests
//
//  Review finding 4 (2026-09-06): a content control bound to a custom XML
//  data store (customXml/item*.xml) kept the ORIGINAL value in that store
//  after the visible body was redacted, because the package rewriter copied
//  every member it did not recognize byte for byte. A lawyer who opened the
//  redacted copy saw a token; anyone who unzipped it read the client's email.
//
//  The privacy export must leave the value in NO member of the archive, and
//  the package must stay valid: no dangling relationship, no content-type
//  override for a part that is gone, no data binding pointing at nothing.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import ZIPFoundation
@testable import LDACore

final class DocxCustomXMLStripTests: XCTestCase {

    private var workDir: URL!

    private static let email = "client@example.test"
    private static let storeID = "{92AA6235-8121-4EEE-B819-849CDA9A264B}"
    private static let customXMLPropertiesType =
        "application/vnd.openxmlformats-officedocument.customXmlProperties+xml"

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocxCustomXMLStrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    /// The review's bound-content package: a content control whose text is
    /// bound to /client/email in customXml/item1.xml, with the properties
    /// part and its .rels exactly as Word lays them out.
    private func writeBoundContentDocx(named name: String = "bound-content.docx") throws -> URL {
        let body = "<w:sdt><w:sdtPr>"
            + "<w:dataBinding w:xpath=\"/client/email\" w:storeItemID=\"\(Self.storeID)\"/>"
            + "</w:sdtPr><w:sdtContent><w:p><w:r><w:t>\(Self.email)</w:t></w:r></w:p></w:sdtContent></w:sdt>"
        let itemProps = "<ds:datastoreItem ds:itemID=\"\(Self.storeID)\" "
            + "xmlns:ds=\"http://schemas.openxmlformats.org/officeDocument/2006/customXml\">"
            + "<ds:schemaRefs/></ds:datastoreItem>"
        let itemRels = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"\(DocxTestPackage.relationshipsNamespace)/customXmlProps\" "
            + "Target=\"itemProps1.xml\"/></Relationships>"
        return try DocxTestPackage.write(
            body: body,
            extraParts: [
                ("customXml/item1.xml", "<client><email>\(Self.email)</email></client>"),
                ("customXml/itemProps1.xml", itemProps),
                ("customXml/_rels/item1.xml.rels", itemRels)
            ],
            to: workDir.appendingPathComponent(name)
        )
    }

    private func anonymize(_ input: URL) throws -> URL {
        let result = try LDAService.anonymize(
            input: input,
            outputDir: workDir.appendingPathComponent("out", isDirectory: true),
            protection: .passphrase("synthetic-review-passphrase"),
            createdAtISO8601: "2026-09-06T00:00:00Z",
            llmModelPath: nil
        )
        XCTAssertEqual(result.entityCount, 1, "fixture: the visible email is detected")
        return result.redactedFileURL
    }

    // MARK: - The leak

    /// The fixture really carries the store, the binding, the relationship
    /// and the override, so the assertions below test removal, not absence.
    func testFixtureCarriesTheDataStoreEverywhereWordPutsIt() throws {
        let input = try writeBoundContentDocx()

        let paths = try DocxTestPackage.allMembers(in: input).map(\.path)
        XCTAssertTrue(paths.contains("customXml/item1.xml"))
        XCTAssertTrue(paths.contains("customXml/itemProps1.xml"))
        XCTAssertTrue(paths.contains("customXml/_rels/item1.xml.rels"))
        XCTAssertTrue(try DocxTestPackage.readPart("word/document.xml", from: input).contains("<w:dataBinding"))
        XCTAssertTrue(try DocxTestPackage.readPart("word/_rels/document.xml.rels", from: input)
            .contains("Target=\"../customXml/item1.xml\""))
        XCTAssertTrue(try DocxTestPackage.readPart("[Content_Types].xml", from: input)
            .contains("PartName=\"/customXml/itemProps1.xml\" ContentType=\"\(Self.customXMLPropertiesType)\""))
    }

    /// The value must survive in NO member of the exported archive, whatever
    /// the member is called. This is the review's probe, widened from one
    /// named part to every byte the archive holds.
    func testPrivacyExportLeavesTheBoundValueInNoMember() throws {
        let output = try anonymize(try writeBoundContentDocx())

        let needle = Data(Self.email.utf8)
        for member in try DocxTestPackage.allMembers(in: output) {
            XCTAssertNil(
                member.data.range(of: needle),
                "\(member.path) still carries the original value after the privacy export"
            )
        }
    }

    /// The data store parts are gone as a whole: the item, its properties,
    /// and the item's own relationships part.
    func testPrivacyExportRemovesEveryCustomXMLMember() throws {
        let output = try anonymize(try writeBoundContentDocx())

        let paths = try DocxTestPackage.allMembers(in: output).map(\.path)
        XCTAssertFalse(
            paths.contains { $0.lowercased().hasPrefix("customxml/") },
            "custom XML members survived the export: \(paths.sorted())"
        )
        XCTAssertTrue(paths.contains("word/document.xml"), "the body is still there")
    }

    /// The package stays valid: nothing points at the removed parts, and our
    /// own importer opens the result and reads the token where the value was.
    func testPrivacyExportLeavesAValidPackageWithoutDanglingReferences() throws {
        let output = try anonymize(try writeBoundContentDocx())

        let body = try DocxTestPackage.readPart("word/document.xml", from: output)
        XCTAssertFalse(body.contains("dataBinding"), "the binding to the removed store must go: \(body)")
        XCTAssertTrue(body.contains("<w:sdt>"), "the content control itself stays")

        let rels = try DocxTestPackage.readPart("word/_rels/document.xml.rels", from: output)
        XCTAssertFalse(rels.lowercased().contains("customxml"), "dangling relationship: \(rels)")
        XCTAssertTrue(rels.contains("<Relationships"), "the relationships part is still well formed")

        let types = try DocxTestPackage.readPart("[Content_Types].xml", from: output)
        XCTAssertFalse(types.lowercased().contains("customxml"), "dangling override: \(types)")
        XCTAssertTrue(types.contains("PartName=\"/word/document.xml\""), "other overrides survive")

        let reimported = try DocxImporter().importDocument(output)
        XCTAssertEqual(reimported.text, "{EMAIL_1}")
    }
}
