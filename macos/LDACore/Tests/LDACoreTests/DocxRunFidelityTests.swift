//
//  DocxRunFidelityTests.swift
//  LDACoreTests
//
//  Run-level fidelity of the .docx rewrite.
//
//  D2: a rewritten w:t whose text gains leading or trailing whitespace must
//  carry xml:space="preserve". Without it Word renders "{EMAIL_1}for details"
//  and a Word re-save drops the space for good. The attribute is needed on
//  the redact pass and on both restore passes (token and literal), because
//  Word routinely re-splits a token or a pseudonym across runs.
//
//  House rules: all comments and strings in English. Fixture values may be
//  Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxRunFidelityTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-run-fidelity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private static let email = "zhangsan@example.com"
    private let preservedTail = "<w:t xml:space=\"preserve\"> for details</w:t>"

    // MARK: - D2: xml:space="preserve" on rewritten runs

    /// A bold run boundary sits inside the email and the tail run continues
    /// with " for details". After redaction the tail run starts with a space
    /// it never had before, so its open tag must gain xml:space="preserve".
    func testRedactAddsSpacePreserveWhenTailRunGainsLeadingSpace() throws {
        let original = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Contact zhang", rPr: "<w:b/>"),
                DocxTestPackage.run("san@example.com for details")
            ),
            to: workDir.appendingPathComponent("original.docx")
        )
        let importer = DocxImporter()
        let imported = try importer.importDocument(original)
        XCTAssertEqual(imported.text, "Contact \(Self.email) for details")

        let redacted = workDir.appendingPathComponent("redacted.docx")
        try DocxRedactor.redact(
            original: original,
            replacements: [
                Replacement(
                    span: DocxTestPackage.span(in: imported.text, surface: Self.email, type: .email),
                    token: "{EMAIL_1}"
                )
            ],
            to: redacted
        )

        let xml = try DocxTestPackage.readPart(docxMainPartPath, from: redacted)
        XCTAssertTrue(xml.contains("<w:t>Contact {EMAIL_1}</w:t>"), xml)
        XCTAssertTrue(xml.contains(preservedTail), "tail run must preserve its new leading space: \(xml)")
        XCTAssertTrue(xml.contains("<w:rPr><w:b/></w:rPr>"), "run formatting must survive")
        XCTAssertEqual(try importer.importDocument(redacted).text, "Contact {EMAIL_1} for details")

        let restored = workDir.appendingPathComponent("restored.docx")
        try DocxRedactor.restore(
            redactedDocx: redacted,
            tokenToValue: ["{EMAIL_1}": Self.email],
            to: restored
        )
        XCTAssertEqual(try importer.importDocument(restored).text, imported.text)
    }

    /// Word re-split the token across two runs while the user edited. The
    /// token restore writes the value into the first run and the tail run is
    /// left starting with a space, so the tail's open tag must preserve it.
    func testTokenRestoreAddsSpacePreserveWhenWordSplitTheToken() throws {
        let edited = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Contact {EMAIL", rPr: "<w:b/>"),
                DocxTestPackage.run("_1} for details")
            ),
            to: workDir.appendingPathComponent("edited.docx")
        )

        let restored = workDir.appendingPathComponent("restored.docx")
        try DocxRedactor.restore(
            redactedDocx: edited,
            tokenToValue: ["{EMAIL_1}": Self.email],
            to: restored
        )

        let xml = try DocxTestPackage.readPart(docxMainPartPath, from: restored)
        XCTAssertTrue(xml.contains("<w:t>Contact \(Self.email)</w:t>"), xml)
        XCTAssertTrue(xml.contains(preservedTail), xml)
        XCTAssertEqual(
            try DocxImporter().importDocument(restored).text,
            "Contact \(Self.email) for details"
        )
    }

    /// The literal (pseudonym) restore lands on the same run planner and
    /// needs the same attribute when Word split the pseudonym.
    func testLiteralRestoreAddsSpacePreserveWhenWordSplitTheReplacement() throws {
        let edited = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Contact 某邮箱", rPr: "<w:b/>"),
                DocxTestPackage.run("A for details")
            ),
            to: workDir.appendingPathComponent("edited.docx")
        )
        let mapping = Mapping(
            entries: [
                "某邮箱A": MappingEntry(
                    token: "某邮箱A",
                    value: Self.email,
                    type: .email,
                    surfaceText: Self.email,
                    aliases: []
                )
            ],
            createdAtISO8601: "2026-09-02T00:00:00Z",
            sourceFile: "doc.docx",
            style: .pseudonym
        )

        let restored = workDir.appendingPathComponent("restored.docx")
        let outcome = try DocxRedactor.restoreLiteral(
            redactedDocx: edited,
            plan: Restorer.literalRestorePlan(for: mapping),
            to: restored
        )

        XCTAssertEqual(outcome.restoredCount, 1)
        let xml = try DocxTestPackage.readPart(docxMainPartPath, from: restored)
        XCTAssertTrue(xml.contains("<w:t>Contact \(Self.email)</w:t>"), xml)
        XCTAssertTrue(xml.contains(preservedTail), xml)
        XCTAssertEqual(
            try DocxImporter().importDocument(restored).text,
            "Contact \(Self.email) for details"
        )
    }

    /// The established cross-run shape is unchanged: the token seals into the
    /// first run, the covered middle run is emptied, and open tags whose text
    /// gained no edge whitespace are copied through untouched.
    func testSealedTokenInFirstRunLeavesOtherOpenTagsUntouched() throws {
        let original = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Hello John"),
                DocxTestPackage.run(" Smith", preserve: true),
                DocxTestPackage.run(", welcome.")
            ),
            to: workDir.appendingPathComponent("original.docx")
        )
        let imported = try DocxImporter().importDocument(original)

        let redacted = workDir.appendingPathComponent("redacted.docx")
        try DocxRedactor.redact(
            original: original,
            replacements: [
                Replacement(
                    span: DocxTestPackage.span(in: imported.text, surface: "John Smith", type: .person),
                    token: "{PERSON_1}"
                )
            ],
            to: redacted
        )

        let xml = try DocxTestPackage.readPart(docxMainPartPath, from: redacted)
        XCTAssertTrue(xml.contains("<w:t>Hello {PERSON_1}</w:t>"), xml)
        XCTAssertTrue(xml.contains("<w:t xml:space=\"preserve\"></w:t>"), "emptied run keeps its own tag: \(xml)")
        XCTAssertTrue(xml.contains("<w:t>, welcome.</w:t>"), "untouched run tag must not change: \(xml)")
        XCTAssertEqual(try DocxImporter().importDocument(redacted).text, "Hello {PERSON_1}, welcome.")
    }

    /// An explicit xml:space="default" on a run that gains edge whitespace is
    /// rewritten to preserve, since "default" tells Word to strip the space.
    func testExplicitDefaultSpaceIsRewrittenToPreserve() throws {
        let original = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Contact zhang"),
                "<w:r><w:t xml:space=\"default\">san@example.com for details</w:t></w:r>"
            ),
            to: workDir.appendingPathComponent("original.docx")
        )
        let imported = try DocxImporter().importDocument(original)

        let redacted = workDir.appendingPathComponent("redacted.docx")
        try DocxRedactor.redact(
            original: original,
            replacements: [
                Replacement(
                    span: DocxTestPackage.span(in: imported.text, surface: Self.email, type: .email),
                    token: "{EMAIL_1}"
                )
            ],
            to: redacted
        )

        let xml = try DocxTestPackage.readPart(docxMainPartPath, from: redacted)
        XCTAssertTrue(xml.contains(preservedTail), xml)
        XCTAssertFalse(xml.contains("xml:space=\"default\""), xml)
    }
}
