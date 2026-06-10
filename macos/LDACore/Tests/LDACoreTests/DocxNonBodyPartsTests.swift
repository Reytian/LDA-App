//
//  DocxNonBodyPartsTests.swift
//  LDACoreTests
//
//  Regression tests for io-docx-nonbody-parts-leak: PII in headers, footers,
//  footnotes, endnotes, comments, docProps metadata, and external hyperlink
//  targets in document.xml.rels must NOT survive the redacted .docx package.
//
//  Every fixture is built in code with ZIPFoundation, so no binary fixtures are
//  committed and tests are hermetic. Detection runs deterministic-only
//  (llmModelPath: nil), so the seeded PII is restricted to types the
//  DeterministicEngine recognizes: EMAIL, PHONE, NATIONAL_ID, DATE, AMOUNT.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxNonBodyPartsTests: XCTestCase {

    private static let createdAt = "2026-06-10T00:00:00Z"

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-nonbody-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Seeded PII (deterministic-only types)

    // A checksum-valid Chinese national ID so the deterministic engine boxes it.
    private static let headerID = "110101199003072877"
    private static let headerEmail = "jane.roe@example.com"
    private static let footerPhone = "+1 212 555 0147"
    private static let footnoteEmail = "michael.author@example.com"
    private static let commentEmail = "secret.witness@example.com"
    private static let creatorName = "Michael Author"
    private static let mailtoTarget = "mailto:jane.roe@example.com"

    // MARK: - The leak regression

    /// The full anonymize pipeline must remove every seeded PII surface from EVERY
    /// part of the package, not just word/document.xml.
    func testAnonymizeRedactsAllNonBodyParts() throws {
        let input = try writeFullFixtureDocx()

        let result = try LDAService.anonymize(
            input: input,
            outputDir: workDir,
            protection: .passphrase("pw"),
            createdAtISO8601: Self.createdAt,
            llmModelPath: nil
        )

        let redacted = result.redactedFileURL

        // Body PII gone (the existing guarantee).
        assertPartLacks(Self.headerEmail, "word/document.xml", isDirectBody: true, in: redacted)

        // Header and footer PII gone.
        assertPartLacks(Self.headerID, "word/header1.xml", in: redacted)
        assertPartLacks(Self.headerEmail, "word/header1.xml", in: redacted)
        assertPartLacks(Self.footerPhone, "word/footer1.xml", in: redacted)

        // Footnotes, endnotes, comments PII gone.
        assertPartLacks(Self.footnoteEmail, "word/footnotes.xml", in: redacted)
        assertPartLacks(Self.footnoteEmail, "word/endnotes.xml", in: redacted)
        assertPartLacks(Self.commentEmail, "word/comments.xml", in: redacted)

        // docProps author metadata scrubbed.
        assertPartLacks(Self.creatorName, "docProps/core.xml", in: redacted)
        assertPartLacks(Self.creatorName, "docProps/app.xml", in: redacted)

        // External mailto hyperlink target neutralized in the .rels.
        assertPartLacks(Self.mailtoTarget, "word/_rels/document.xml.rels", in: redacted)
        assertPartLacks(Self.headerEmail, "word/_rels/document.xml.rels", in: redacted)
    }

    /// A token in the header must round-trip back to its original surface on
    /// restore (the non-body parts carry tokens the same way the body does).
    func testRestoreRoundTripsHeaderAndBody() throws {
        let input = try writeFullFixtureDocx()

        let result = try LDAService.anonymize(
            input: input,
            outputDir: workDir,
            protection: .passphrase("pw"),
            createdAtISO8601: Self.createdAt,
            llmModelPath: nil
        )

        let restored = workDir.appendingPathComponent("restored.docx")
        _ = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("pw"),
            output: restored
        )

        // The header email returns verbatim in the restored package.
        let header = try readPart("word/header1.xml", from: restored)
        XCTAssertTrue(header.contains(Self.headerEmail),
                      "header email should round-trip back on restore")

        // The body restores too: importing the restored body shows no tokens.
        let body = try DocxImporter().importDocument(restored).text
        XCTAssertFalse(body.contains("{"), "restored body should carry no tokens")
    }

    // MARK: - Targeted unit coverage

    /// External mailto:/tel: targets are neutralized; internal part targets and
    /// http(s) links are left intact (no over-redaction).
    func testNeutralizeExternalTargetsScopesToSensitiveSchemes() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="r1" Type="t/header" Target="header1.xml"/>
        <Relationship Id="r2" Type="t/hyperlink" Target="mailto:secret@example.com" TargetMode="External"/>
        <Relationship Id="r3" Type="t/hyperlink" Target="tel:+12125550147" TargetMode="External"/>
        <Relationship Id="r4" Type="t/hyperlink" Target="https://example.com/page" TargetMode="External"/>
        </Relationships>
        """
        let out = DocxParts.neutralizeExternalTargets(xml)
        XCTAssertFalse(out.contains("mailto:secret@example.com"), "mailto target should be neutralized")
        XCTAssertFalse(out.contains("tel:+12125550147"), "tel target should be neutralized")
        XCTAssertTrue(out.contains("Target=\"header1.xml\""), "internal target must be preserved")
        XCTAssertTrue(out.contains("https://example.com/page"), "http link must be preserved")
    }

    /// core.xml author/title elements are blanked while their tags survive.
    func testScrubCorePropsBlanksAuthorAndTitle() {
        let xml = """
        <cp:coreProperties xmlns:cp="ns" xmlns:dc="dc">
        <dc:title>Secret Matter</dc:title>
        <dc:creator>Michael Author</dc:creator>
        <cp:lastModifiedBy>Michael Author</cp:lastModifiedBy>
        </cp:coreProperties>
        """
        let out = DocxParts.scrubCoreProps(xml)
        XCTAssertFalse(out.contains("Michael Author"), "creator and lastModifiedBy must be blanked")
        XCTAssertFalse(out.contains("Secret Matter"), "title must be blanked")
        XCTAssertTrue(out.contains("<dc:creator>"), "the creator tag itself should survive")
        XCTAssertTrue(out.contains("</dc:creator>"), "the creator close tag should survive")
    }

    /// A package that has no header/footer/notes/comments/docProps parts must be
    /// redacted exactly like the legacy body-only path (no crash, body PII gone).
    func testBodyOnlyDocxStillRedactsCleanly() throws {
        let url = workDir.appendingPathComponent("bodyonly.docx")
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        let doc = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t xml:space="preserve">Email \(Self.headerEmail) here.</w:t></w:r></w:p></w:body>
        </w:document>
        """
        try DocxZip.writeArchive(parts: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rels.utf8)),
            ("word/document.xml", Data(doc.utf8))
        ], to: url)

        let result = try LDAService.anonymize(
            input: url, outputDir: workDir, protection: .passphrase("pw"),
            createdAtISO8601: Self.createdAt, llmModelPath: nil)

        let body = try DocxImporter().importDocument(result.redactedFileURL).text
        XCTAssertFalse(body.contains(Self.headerEmail), "body email must be redacted")
        XCTAssertTrue(body.contains("{EMAIL_1}"), "body email should be tokenized")
    }

    // MARK: - Assertions

    /// Asserts the named part exists and does not contain the seeded PII string.
    /// For the body part, we read the decoded visible text via DocxImporter so the
    /// assertion matches the run-text edit surface; for other parts we scan the raw
    /// XML/rels bytes (which is where these leaks live).
    private func assertPartLacks(
        _ pii: String,
        _ path: String,
        isDirectBody: Bool = false,
        in docx: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let content: String
            if isDirectBody {
                content = try DocxImporter().importDocument(docx).text
            } else {
                content = try readPart(path, from: docx)
            }
            XCTAssertFalse(content.contains(pii),
                           "\(path) still contains seeded PII \(pii)",
                           file: file, line: line)
        } catch {
            XCTFail("could not read \(path): \(error)", file: file, line: line)
        }
    }

    private func readPart(_ path: String, from docx: URL) throws -> String {
        let data = try DocxZip.readEntry(path, from: docx)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Fixture authoring

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
    <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
    <Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/>
    <Override PartName="/word/endnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.endnotes+xml"/>
    <Override PartName="/word/comments.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.comments+xml"/>
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
    <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
    </Types>
    """

    private static let packageRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
    </Relationships>
    """

    /// document.xml.rels with a header/footer link plus an EXTERNAL mailto target.
    private static let documentRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId10" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>
    <Relationship Id="rId11" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>
    <Relationship Id="rId12" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="\(mailtoTarget)" TargetMode="External"/>
    </Relationships>
    """

    private static let coreXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/">
    <dc:title>Confidential Matter</dc:title>
    <dc:creator>\(creatorName)</dc:creator>
    <cp:lastModifiedBy>\(creatorName)</cp:lastModifiedBy>
    </cp:coreProperties>
    """

    private static let appXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">
    <Company>\(creatorName) Holdings</Company>
    <Manager>\(creatorName)</Manager>
    </Properties>
    """

    /// A minimal header/footer/notes part containing a single paragraph and run.
    private static func wordPart(_ text: String, rootTag: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:\(rootTag) xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:p><w:r><w:t xml:space="preserve">\(xmlEncode(text))</w:t></w:r></w:p>
        </w:\(rootTag)>
        """
    }

    private static let documentXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:body>
    <w:p><w:r><w:t xml:space="preserve">Contact us at \(headerEmail) for details.</w:t></w:r></w:p>
    </w:body>
    </w:document>
    """

    private func writeFullFixtureDocx() throws -> URL {
        let url = workDir.appendingPathComponent("input.docx")
        let parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(Self.contentTypesXML.utf8)),
            ("_rels/.rels", Data(Self.packageRelsXML.utf8)),
            ("word/document.xml", Data(Self.documentXML.utf8)),
            ("word/_rels/document.xml.rels", Data(Self.documentRelsXML.utf8)),
            ("word/header1.xml", Data(Self.wordPart(
                "Confidential memo for \(Self.headerEmail), ID \(Self.headerID)",
                rootTag: "hdr").utf8)),
            ("word/footer1.xml", Data(Self.wordPart(
                "Call \(Self.footerPhone) with questions",
                rootTag: "ftr").utf8)),
            ("word/footnotes.xml", Data(Self.wordPart(
                "Footnote reachable at \(Self.footnoteEmail)",
                rootTag: "footnotes").utf8)),
            ("word/endnotes.xml", Data(Self.wordPart(
                "Endnote reachable at \(Self.footnoteEmail)",
                rootTag: "endnotes").utf8)),
            ("word/comments.xml", Data(Self.wordPart(
                "Comment: witness is \(Self.commentEmail)",
                rootTag: "comments").utf8)),
            ("docProps/core.xml", Data(Self.coreXML.utf8)),
            ("docProps/app.xml", Data(Self.appXML.utf8))
        ]
        try DocxZip.writeArchive(parts: parts, to: url)
        return url
    }
}
