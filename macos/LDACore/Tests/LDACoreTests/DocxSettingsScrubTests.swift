//
//  DocxSettingsScrubTests.swift
//  LDACoreTests
//
//  Review R4 (2026-09-07): the package policy classified word/settings.xml as
//  structural, carrying no free-form user content, and copied it through byte
//  for byte. It is not. Word keeps DOCUMENT VARIABLES there, and a document
//  variable is whatever a template author or a macro put in it:
//
//    <w:docVars><w:docVar w:name="ClientEmail" w:val="client@example.test"/></w:docVars>
//
//  The reviewer's fixture exported successfully with one detected entity. The
//  visible email was replaced and the complete original stayed in the settings
//  part, with no unboxed or embedded-media warning naming it. The mail merge
//  block is the same channel: it holds the data source path and the query,
//  and a PRC matter's recipient list is named after the parties.
//
//  The redacted copy needs neither, and the package is valid without them, so
//  the privacy export strips both. Filling a form is not a privacy export and
//  must leave them alone.
//
//  House rules: all comments and strings in English. Fixture values may be
//  Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxSettingsScrubTests: XCTestCase {

    private var workDir: URL!

    private static let email = "client@example.test"
    private static let settingsPath = "word/settings.xml"
    private static let settingsRelsPath = "word/_rels/settings.xml.rels"

    /// A mail merge data source path. A recipient list is named after the
    /// matter, so the PATH is itself identifying, before anyone opens it.
    private static let mergeSourcePath = "file:///Volumes/Matters/Zhang%20Wei/recipients.xlsx"

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocxSettingsScrub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private static func settings(_ inner: String) -> String {
        "<w:settings xmlns:w=\"\(DocxTestPackage.wordNamespace)\" "
            + "xmlns:r=\"\(DocxTestPackage.relationshipsNamespace)\">"
            + inner
            + "</w:settings>"
    }

    /// The reviewer's settings part: one document variable holding the whole
    /// address, beside an ordinary setting that must survive.
    private static let documentVariableSettings = settings(
        "<w:docVars><w:docVar w:name=\"ClientEmail\" w:val=\"\(email)\"/></w:docVars>"
            + "<w:zoom w:percent=\"100\"/>"
    )

    /// A mail merge block: the query quotes the address and the data source
    /// points at a relationship whose target is the recipient list.
    private static let mailMergeSettings = settings(
        "<w:mailMerge><w:mainDocumentType w:val=\"formLetters\"/>"
            + "<w:query w:val=\"SELECT * FROM recipients WHERE email = '\(email)'\"/>"
            + "<w:dataSource r:id=\"rIdMergeSource\"/></w:mailMerge>"
            + "<w:zoom w:percent=\"100\"/>"
    )

    private static let mailMergeRels =
        "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rIdMergeSource\" "
            + "Type=\"\(DocxTestPackage.relationshipsNamespace)/mailMergeSource\" "
            + "Target=\"\(mergeSourcePath)\" TargetMode=\"External\"/></Relationships>"

    private static let settingsRelationship =
        "<Relationship Id=\"rIdSettings\" "
            + "Type=\"\(DocxTestPackage.relationshipsNamespace)/settings\" Target=\"settings.xml\"/>"

    /// A package whose visible body carries the address and whose settings
    /// part is `settings`. The settings part gets the relationship Word
    /// writes; its content type comes from the xml Default.
    private func writeDocx(
        settings: String,
        body: String = "<w:p><w:r><w:t>\(DocxSettingsScrubTests.email)</w:t></w:r></w:p>",
        extraParts: [(String, String)] = [],
        named name: String
    ) throws -> URL {
        try DocxTestPackage.write(
            body: body,
            extraParts: [(Self.settingsPath, settings)] + extraParts,
            extraDocumentRelationships: [Self.settingsRelationship],
            to: workDir.appendingPathComponent(name)
        )
    }

    private func anonymize(_ input: URL) throws -> URL {
        let result = try LDAService.anonymize(
            input: input,
            outputDir: workDir.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true),
            protection: .passphrase("synthetic-review-passphrase"),
            createdAtISO8601: "2026-09-07T00:00:00Z"
        )
        XCTAssertEqual(result.entityCount, 1, "fixture: the visible email is detected")
        return result.redactedFileURL
    }

    private func assertNoMemberCarries(
        _ needles: [String],
        of url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for member in try DocxTestPackage.allMembers(in: url) {
            for needle in needles {
                XCTAssertNil(
                    member.data.range(of: Data(needle.utf8)),
                    "\(member.path) still carries \(needle) after the privacy export",
                    file: file,
                    line: line
                )
            }
        }
    }

    // MARK: - The leak

    /// The fixture really keeps the address in the settings part, so the
    /// assertions below test removal and not absence.
    func testFixtureCarriesTheDocumentVariable() throws {
        let input = try writeDocx(settings: Self.documentVariableSettings, named: "docvars.docx")
        let settings = try DocxTestPackage.readPart(Self.settingsPath, from: input)
        XCTAssertTrue(settings.contains("<w:docVars>"), settings)
        XCTAssertTrue(settings.contains(Self.email), settings)
    }

    /// The reviewer's probe, widened from one named part to every byte of the
    /// archive.
    func testPrivacyExportLeavesTheDocumentVariableInNoMember() throws {
        let output = try anonymize(
            try writeDocx(settings: Self.documentVariableSettings, named: "docvars.docx")
        )
        try assertNoMemberCarries([Self.email], of: output)
    }

    /// The variable block is gone as a whole and the rest of the part
    /// survives, so the package Word opens is still a valid settings part.
    func testPrivacyExportKeepsTheRestOfTheSettingsPart() throws {
        let output = try anonymize(
            try writeDocx(settings: Self.documentVariableSettings, named: "docvars.docx")
        )
        let settings = try DocxTestPackage.readPart(Self.settingsPath, from: output)
        XCTAssertFalse(settings.contains("w:docVar"), settings)
        XCTAssertTrue(settings.contains("<w:zoom w:percent=\"100\"/>"), settings)
        XCTAssertTrue(settings.contains("</w:settings>"), settings)
    }

    /// The mail merge block and the relationship naming its data source both
    /// go: stripping the block alone would leave the recipient list's PATH in
    /// the package, and the path is identifying on its own.
    func testPrivacyExportRemovesTheMailMergeBlockAndItsDataSource() throws {
        let output = try anonymize(
            try writeDocx(
                settings: Self.mailMergeSettings,
                extraParts: [(Self.settingsRelsPath, Self.mailMergeRels)],
                named: "mailmerge.docx"
            )
        )

        try assertNoMemberCarries([Self.email, "Zhang%20Wei", "recipients.xlsx"], of: output)
        let settings = try DocxTestPackage.readPart(Self.settingsPath, from: output)
        XCTAssertFalse(settings.contains("w:mailMerge"), settings)
        XCTAssertTrue(settings.contains("<w:zoom w:percent=\"100\"/>"), settings)
    }

    // MARK: - What must not change

    /// A settings part with neither block is copied through byte for byte:
    /// the export rewrites a member only when it has something to remove.
    func testSettingsWithoutVariablesCopyThroughByteForByte() throws {
        let plain = Self.settings("<w:zoom w:percent=\"100\"/><w:defaultTabStop w:val=\"720\"/>")
        let input = try writeDocx(settings: plain, named: "plain-settings.docx")
        let output = try anonymize(input)

        let before = try DocxZip.readEntry(Self.settingsPath, from: input)
        let after = try DocxZip.readEntry(Self.settingsPath, from: output)
        XCTAssertEqual(after, before, "an untouched settings part must not be rewritten")
    }

    /// Filling a form is not a privacy export: the document the user keeps
    /// stays whole, document variables included.
    func testTheFillPathLeavesDocumentVariablesAlone() throws {
        let input = try writeDocx(
            settings: Self.documentVariableSettings,
            body: "<w:p><w:r><w:t>Contact [Client] today</w:t></w:r></w:p>",
            named: "fill-settings.docx"
        )
        let text = try DocxImporter().importDocument(input).text
        let span = DocxTestPackage.span(in: text, surface: "[Client]", type: .company)
        let out = workDir.appendingPathComponent("filled.docx")

        try DocxFiller.fill(original: input, fills: [DocxFill(span: span, value: "Acme")], to: out)

        let settings = try DocxTestPackage.readPart(Self.settingsPath, from: out)
        XCTAssertTrue(settings.contains(Self.email), "the fill path must not scrub the settings part")
        XCTAssertTrue(try DocxImporter().importDocument(out).text.contains("Contact Acme today"))
    }
}
