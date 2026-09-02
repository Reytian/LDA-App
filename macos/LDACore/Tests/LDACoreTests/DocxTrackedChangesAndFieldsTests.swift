//
//  DocxTrackedChangesAndFieldsTests.swift
//  LDACoreTests
//
//  D5: PII that hides outside w:t. A tracked deletion keeps its text in
//  w:delText, a hyperlink field keeps its mailto:/tel: target in a field
//  instruction (w:instrText or w:fldSimple/@w:instr), and every revision and
//  comment names its author in w:author/w:initials, with word/people.xml
//  listing the same people (and, for directory accounts, their email in
//  w15:userId). None of that flowed through the redactor, so the redacted
//  package shipped it in clear. The redacted package must not contain any of
//  those values in ANY part, and restore must still succeed.
//
//  House rules: all comments and strings in English. Fixture values may be
//  Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxTrackedChangesAndFieldsTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-tracked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private static let createdAt = "2026-09-02T00:00:00Z"
    private static let insertedPhone = "13500001111"
    private static let deletedPhone = "13600002222"
    private static let commentPhone = "13812345678"
    private static let reviewer = "李四"
    private static let editor = "张三"
    private static let directoryUserId = "S::zhangsan@example.com::0b1c"

    // MARK: - Fixtures

    private static let revisionsBody = """
    <w:p><w:r><w:t xml:space="preserve">修订记录：新电话 </w:t></w:r>\
    <w:ins w:id="901" w:author="\(editor)" w:date="2026-03-01T00:00:00Z"><w:r><w:t>\(insertedPhone)</w:t></w:r></w:ins>\
    <w:r><w:t xml:space="preserve"> 替换旧电话 </w:t></w:r>\
    <w:del w:id="902" w:author="\(editor)" w:initials="ZS" w:date="2026-03-01T00:00:00Z"><w:r><w:delText>\(deletedPhone)</w:delText></w:r></w:del>\
    <w:r><w:t>。</w:t></w:r></w:p>\
    <w:p><w:commentRangeStart w:id="0"/><w:r><w:t>联系电话以本条为准。</w:t></w:r><w:commentRangeEnd w:id="0"/>\
    <w:r><w:commentReference w:id="0"/></w:r></w:p>
    """

    private static let commentsXML = DocxTestPackage.wordPart(
        rootTag: "comments",
        body: "<w:comment w:id=\"0\" w:author=\"\(reviewer)\" w:date=\"2026-03-02T00:00:00Z\" w:initials=\"LS\">"
            + "<w:p><w:r><w:t>请核对电话 \(commentPhone)。</w:t></w:r></w:p></w:comment>"
    )

    private static let peopleXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w15:people xmlns:w15="\(DocxTestPackage.w15Namespace)">\
    <w15:person w15:author="\(reviewer)"><w15:presenceInfo w15:providerId="None" w15:userId="\(reviewer)"/></w15:person>\
    <w15:person w15:author="\(editor)"><w15:presenceInfo w15:providerId="AD" w15:userId="\(directoryUserId)"/></w15:person>\
    </w15:people>
    """

    private static let bodyMailtoSimple = "hidden.simple@example.com"
    private static let bodyMailtoComplex = "hidden.complex@example.com"
    private static let bodyTel = "+12125550147"
    private static let headerMailto = "header.hidden@example.com"
    private static let keptLink = "https://example.com/terms"

    private static func complexField(instruction: String, display: String) -> String {
        "<w:r><w:fldChar w:fldCharType=\"begin\"/></w:r>"
            + "<w:r><w:instrText xml:space=\"preserve\">\(instruction)</w:instrText></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"separate\"/></w:r>"
            + "<w:r><w:t>\(display)</w:t></w:r>"
            + "<w:r><w:fldChar w:fldCharType=\"end\"/></w:r>"
    }

    private static let fieldsBody = "<w:p><w:r><w:t>字段：</w:t></w:r>"
        + "<w:fldSimple w:instr=\" HYPERLINK &quot;mailto:\(bodyMailtoSimple)&quot; \"><w:r><w:t>简单字段显示文本</w:t></w:r></w:fldSimple>"
        + "<w:r><w:t xml:space=\"preserve\"> | </w:t></w:r>"
        + complexField(instruction: " HYPERLINK \"mailto:\(bodyMailtoComplex)\" ", display: "复杂字段显示文本")
        + complexField(instruction: " HYPERLINK \"tel:\(bodyTel)\" ", display: "call")
        + complexField(instruction: " HYPERLINK \"\(keptLink)\" ", display: "terms")
        + "</w:p>"
        + DocxTestPackage.sectionWithHeaderAndFooter

    /// A header with a PAGE field and a mailto field but no detectable PII, so
    /// the field scrub must run even where detection finds nothing.
    private static let fieldsHeaderXML = DocxTestPackage.wordPart(
        rootTag: "hdr",
        body: "<w:p><w:fldSimple w:instr=\" PAGE \"><w:r><w:t>1</w:t></w:r></w:fldSimple>"
            + "<w:fldSimple w:instr=' HYPERLINK \"mailto:\(headerMailto)\" '><w:r><w:t>联系</w:t></w:r></w:fldSimple></w:p>"
    )

    private static let fieldsFooterXML = DocxTestPackage.wordPart(
        rootTag: "ftr",
        body: "<w:p><w:r><w:t>第 1 页</w:t></w:r></w:p>"
    )

    private func anonymize(_ input: URL) throws -> AnonymizeResult {
        try LDAService.anonymize(
            input: input,
            outputDir: workDir,
            protection: .passphrase("pw"),
            createdAtISO8601: Self.createdAt,
            llmModelPath: nil
        )
    }

    private func restore(_ result: AnonymizeResult, to name: String) throws -> (RestoreReport, URL) {
        let restored = workDir.appendingPathComponent(name)
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("pw"),
            output: restored
        )
        return (report, restored)
    }

    private func assertNoPart(
        of package: URL,
        contains values: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for part in try DocxTestPackage.allTextParts(in: package) {
            for value in values where part.xml.contains(value) {
                XCTFail("\(part.path) still contains \(value)", file: file, line: line)
            }
        }
    }

    // MARK: - Tracked deletions and revision authors

    /// The text of a tracked deletion is detected and redacted like visible
    /// text, and restores back into its w:delText.
    func testTrackedDeletionTextIsRedactedAndRestored() throws {
        let original = try DocxTestPackage.write(
            body: Self.revisionsBody,
            extraParts: [("word/comments.xml", Self.commentsXML), ("word/people.xml", Self.peopleXML)],
            to: workDir.appendingPathComponent("revisions.docx")
        )
        let importer = DocxImporter()
        let originalText = try importer.importDocument(original).text
        XCTAssertTrue(originalText.contains(Self.deletedPhone), "deleted text must be read for detection")

        let result = try anonymize(original)

        let redactedXML = try DocxTestPackage.readPart(docxMainPartPath, from: result.redactedFileURL)
        XCTAssertTrue(redactedXML.contains("<w:delText>{PHONE_"), "deleted text must be tokenized: \(redactedXML)")
        XCTAssertEqual(
            try importer.importDocument(result.redactedFileURL).text,
            "修订记录：新电话 {PHONE_1} 替换旧电话 {PHONE_2}。\n联系电话以本条为准。"
        )
        try assertNoPart(of: result.redactedFileURL, contains: [Self.insertedPhone, Self.deletedPhone])

        let (report, restored) = try restore(result, to: "restored.docx")
        XCTAssertTrue(report.orphanTokens.isEmpty)
        XCTAssertEqual(report.restoredCount, 3)
        XCTAssertEqual(try importer.importDocument(restored).text, originalText)
        XCTAssertTrue(
            try DocxTestPackage.readPart(docxMainPartPath, from: restored).contains("<w:delText>\(Self.deletedPhone)</w:delText>")
        )
    }

    /// Revision and comment authors, their initials, and the people part are
    /// blanked in the redacted copy, so no part of the package names a person.
    func testRevisionAndCommentAuthorsAreBlankedEverywhere() throws {
        let original = try DocxTestPackage.write(
            body: Self.revisionsBody,
            extraParts: [("word/comments.xml", Self.commentsXML), ("word/people.xml", Self.peopleXML)],
            to: workDir.appendingPathComponent("authors.docx")
        )

        let result = try anonymize(original)

        try assertNoPart(
            of: result.redactedFileURL,
            contains: [Self.editor, Self.reviewer, Self.directoryUserId, Self.commentPhone, "ZS", "LS"]
        )
        let redactedXML = try DocxTestPackage.readPart(docxMainPartPath, from: result.redactedFileURL)
        XCTAssertTrue(redactedXML.contains("<w:ins w:id=\"901\" w:author=\"\" w:date=\"2026-03-01T00:00:00Z\">"), redactedXML)
        XCTAssertTrue(redactedXML.contains("w:initials=\"\""), redactedXML)
        let comments = try DocxTestPackage.readPart("word/comments.xml", from: result.redactedFileURL)
        XCTAssertTrue(comments.contains("w:author=\"\""), comments)
        XCTAssertTrue(comments.contains("{PHONE_"), "comment body PII must still be tokenized: \(comments)")
        let people = try DocxTestPackage.readPart("word/people.xml", from: result.redactedFileURL)
        XCTAssertTrue(people.contains("<w15:person w15:author=\"\">"), people)
        XCTAssertTrue(people.contains("w15:userId=\"\""), people)
        XCTAssertTrue(people.contains("w15:providerId=\"AD\""), "non-identifying attributes survive: \(people)")

        // The blanked authors are destructive by design; restore still works.
        let (report, restored) = try restore(result, to: "restored.docx")
        XCTAssertTrue(report.orphanTokens.isEmpty)
        XCTAssertTrue(try DocxTestPackage.readPart("word/comments.xml", from: restored).contains(Self.commentPhone))
    }

    /// Filling a form goes through the same run rewriter without the non-body
    /// pass, and a filled form is not a redacted copy: its revision authors
    /// must stay exactly as they were.
    func testBodyOnlyRewriteLeavesRevisionAuthorsAlone() throws {
        let original = try DocxTestPackage.write(
            body: Self.revisionsBody,
            to: workDir.appendingPathComponent("fill-source.docx")
        )
        let out = workDir.appendingPathComponent("filled.docx")

        try DocxRedactor.redact(original: original, replacements: [], to: out)

        let xml = try DocxTestPackage.readPart(docxMainPartPath, from: out)
        XCTAssertTrue(xml.contains("w:author=\"\(Self.editor)\""), xml)
    }

    // MARK: - Field instructions

    /// mailto: and tel: targets inside field instructions are neutralized to
    /// about:blank in the body and in a header that has no other PII, while
    /// http links, PAGE fields, and every display text survive.
    func testFieldInstructionTargetsAreNeutralized() throws {
        let original = try DocxTestPackage.write(
            body: Self.fieldsBody,
            extraParts: [("word/header1.xml", Self.fieldsHeaderXML), ("word/footer1.xml", Self.fieldsFooterXML)],
            to: workDir.appendingPathComponent("fields.docx")
        )
        let importer = DocxImporter()
        let originalText = try importer.importDocument(original).text

        let result = try anonymize(original)

        try assertNoPart(
            of: result.redactedFileURL,
            contains: [Self.bodyMailtoSimple, Self.bodyMailtoComplex, Self.bodyTel, Self.headerMailto]
        )
        let body = try DocxTestPackage.readPart(docxMainPartPath, from: result.redactedFileURL)
        XCTAssertEqual(body.components(separatedBy: "about:blank").count, 4, "three body targets neutralized: \(body)")
        XCTAssertTrue(body.contains("<w:fldSimple w:instr=\" HYPERLINK &quot;about:blank&quot; \">"), body)
        XCTAssertTrue(body.contains("<w:instrText xml:space=\"preserve\"> HYPERLINK \"about:blank\" </w:instrText>"), body)
        XCTAssertTrue(body.contains(Self.keptLink), "http link must be preserved")
        XCTAssertEqual(try importer.importDocument(result.redactedFileURL).text, originalText, "display text is not PII")

        let header = try DocxTestPackage.readPart("word/header1.xml", from: result.redactedFileURL)
        XCTAssertTrue(header.contains("<w:fldSimple w:instr=\" PAGE \"><w:r><w:t>1</w:t></w:r></w:fldSimple>"), header)
        XCTAssertTrue(header.contains("w:instr=' HYPERLINK \"about:blank\" '"), header)

        let (report, restored) = try restore(result, to: "restored.docx")
        XCTAssertEqual(report.restoredCount, 0)
        XCTAssertTrue(report.orphanTokens.isEmpty)
        XCTAssertEqual(try importer.importDocument(restored).text, originalText)
    }
}
