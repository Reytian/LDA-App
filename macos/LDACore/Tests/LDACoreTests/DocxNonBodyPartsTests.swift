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
    func testTokenRestoreReportCountsBodyAndEveryNonBodyOccurrence() throws {
        let input = try writeFullFixtureDocx()

        let result = try LDAService.anonymize(
            input: input,
            outputDir: workDir,
            protection: .passphrase("pw"),
            createdAtISO8601: Self.createdAt,
            llmModelPath: nil
        )

        let restored = workDir.appendingPathComponent("restored.docx")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("pw"),
            output: restored
        )

        // One body email plus six occurrences across the header, footer,
        // footnote, endnote, and comment parts must contribute to one report.
        XCTAssertEqual(report.restoredCount, 7)
        XCTAssertTrue(report.orphanTokens.isEmpty)
        XCTAssertTrue(report.suspectPlaceholders.isEmpty)

        // The header email returns verbatim in the restored package.
        let header = try readPart("word/header1.xml", from: restored)
        XCTAssertTrue(header.contains(Self.headerEmail),
                      "header email should round-trip back on restore")

        // The body restores too: importing the restored body shows no tokens.
        let body = try DocxImporter().importDocument(restored).text
        XCTAssertFalse(body.contains("{"), "restored body should carry no tokens")
    }

    func testTokenRestoreWritesASupplementaryTokenSplitAcrossRuns() throws {
        let result = try anonymizeFullFixture()
        let mapping = try MappingStore.load(
            from: result.mappingFileURL,
            protection: .passphrase("pw")
        )
        let emailToken = try XCTUnwrap(
            mapping.entries.values.first { $0.value == Self.headerEmail }?.token
        )
        let splitIndex = emailToken.index(
            emailToken.startIndex,
            offsetBy: emailToken.count / 2
        )
        let splitToken = String(emailToken[..<splitIndex])
            + "</w:t></w:r><w:r><w:t>"
            + String(emailToken[splitIndex...])
        let header = try readPart("word/header1.xml", from: result.redactedFileURL)
        XCTAssertTrue(header.contains(emailToken))

        let edited = workDir.appendingPathComponent("split-header-token.docx")
        try DocxZip.rewrite(
            source: result.redactedFileURL,
            replacing: [
                "word/header1.xml": Data(
                    header.replacingOccurrences(of: emailToken, with: splitToken).utf8
                )
            ],
            to: edited
        )

        let restored = workDir.appendingPathComponent("restored-split-header-token.docx")
        let report = try LDAService.restore(
            editedRedacted: edited,
            mapping: result.mappingFileURL,
            protection: .passphrase("pw"),
            output: restored
        )
        let restoredVisibleText = try DocxParts.restoreReportText(from: restored)

        XCTAssertEqual(report.restoredCount, 7)
        XCTAssertTrue(report.orphanTokens.isEmpty)
        XCTAssertTrue(restoredVisibleText.contains(Self.headerEmail))
        XCTAssertFalse(
            restoredVisibleText.contains(emailToken),
            "every site counted as restored must actually be rewritten"
        )
    }

    /// Pseudonym restore uses ordinary replacement strings in the body, while
    /// supplementary parts can also carry brace tokens minted during package
    /// redaction. Both replacement shapes belong to the same package-wide
    /// report and every mapped occurrence in this fixture is present.
    func testPseudonymRestoreReportCountsBodyAndEveryNonBodyOccurrence() throws {
        let input = try writeFullFixtureDocx()

        let result = try LDAService.anonymize(
            input: input,
            outputDir: workDir,
            protection: .passphrase("pw"),
            createdAtISO8601: Self.createdAt,
            llmModelPath: nil,
            style: .pseudonym
        )

        let restored = workDir.appendingPathComponent("restored-pseudonym.docx")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("pw"),
            output: restored
        )

        XCTAssertEqual(report.restoredCount, 7)
        XCTAssertTrue(report.orphanTokens.isEmpty)
        XCTAssertTrue(report.suspectPlaceholders.isEmpty)
        XCTAssertTrue(report.ambiguousReplacements.isEmpty)

        let header = try readPart("word/header1.xml", from: restored)
        XCTAssertTrue(header.contains(Self.headerEmail))
        XCTAssertTrue(header.contains(Self.headerID))
        let comments = try readPart("word/comments.xml", from: restored)
        XCTAssertTrue(comments.contains(Self.commentEmail))
    }

    func testRestoreReportFailsWhenAnEnumeratedSupplementaryPartIsMalformed() throws {
        let result = try anonymizeFullFixture()
        let malformed = workDir.appendingPathComponent("malformed-header.docx")
        let brokenHeader = Data(
            "<w:hdr xmlns:w=\"urn:test\"><w:p><w:r><w:t>unterminated".utf8
        )
        try DocxZip.rewrite(
            source: result.redactedFileURL,
            replacing: ["word/header1.xml": brokenHeader],
            to: malformed
        )

        XCTAssertTrue(DocxParts.textBearingPartPaths(in: malformed).contains("word/header1.xml"))
        XCTAssertThrowsError(try DocxParts.restoreReportText(from: malformed)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("word/header1.xml"),
                "the visible failure must identify the supplementary part: \(error)"
            )
        }
    }

    func testTokenRestorationFailsWhenAnEnumeratedSupplementaryPartCannotBeRead() throws {
        let result = try anonymizeFullFixture()
        let damaged = workDir.appendingPathComponent("unreadable-header.docx")
        try FileManager.default.copyItem(at: result.redactedFileURL, to: damaged)
        try corruptCompressedPayload(of: "word/header1.xml", in: damaged)

        XCTAssertTrue(DocxParts.textBearingPartPaths(in: damaged).contains("word/header1.xml"))
        let mapping = try MappingStore.load(
            from: result.mappingFileURL,
            protection: .passphrase("pw")
        )
        let tokenToValue = Dictionary(
            uniqueKeysWithValues: mapping.entries.values.map { ($0.token, $0.value) }
        )
        let output = workDir.appendingPathComponent("must-not-exist.docx")

        XCTAssertThrowsError(
            try DocxRedactor.restore(
                redactedDocx: damaged,
                tokenToValue: tokenToValue,
                to: output
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("word/header1.xml"),
                "the visible failure must identify the unreadable supplementary part: \(error)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.path),
            "restoration must fail before writing a partial package"
        )
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

    /// XML permits single OR double quotes around an attribute value, and
    /// non-Word producers (LibreOffice, python-docx variants, XML tooling, and
    /// hand-edited packages) emit single quotes. A single-quoted external
    /// mailto:/tel: target must be neutralized exactly like a double-quoted
    /// one, or the address rides out of the app inside the redacted package.
    func testNeutralizeExternalTargetsHandlesSingleQuotedAttributes() {
        let xml = "<Relationships>"
            + "<Relationship Id='rId1' TargetMode='External' Target='mailto:client@example.com'/>"
            + "<Relationship Id='rId2' TargetMode='External' Target='tel:+12125550147'/>"
            + "<Relationship Id='rId3' Target='header1.xml'/>"
            + "<Relationship Id='rId4' TargetMode='External' Target='https://example.com/page'/>"
            + "</Relationships>"
        let out = DocxParts.neutralizeExternalTargets(xml)
        XCTAssertFalse(out.contains("client@example.com"),
                       "single-quoted mailto target must be neutralized")
        XCTAssertFalse(out.contains("+12125550147"),
                       "single-quoted tel target must be neutralized")
        XCTAssertTrue(out.contains("header1.xml"),
                      "internal target must be preserved")
        XCTAssertTrue(out.contains("https://example.com/page"),
                      "http link must be preserved")
    }

    /// XML scopes the quote choice per attribute, so one element can carry a
    /// double-quoted TargetMode beside a single-quoted Target. The TargetMode
    /// guard and the Target rewrite must therefore each be quote-agnostic on
    /// their own: a quote-agnostic rewrite behind a double-quote-only guard is
    /// dead code for exactly the files that need it.
    func testNeutralizeExternalTargetsHandlesMixedQuoteStyles() {
        let xml = "<Relationships>"
            + "<Relationship Id='rId1' TargetMode=\"External\" Target='mailto:a@example.com'/>"
            + "<Relationship Id=\"rId2\" TargetMode='External' Target=\"mailto:b@example.com\"/>"
            + "</Relationships>"
        let out = DocxParts.neutralizeExternalTargets(xml)
        XCTAssertFalse(out.contains("a@example.com"),
                       "single-quoted Target under a double-quoted TargetMode must be neutralized")
        XCTAssertFalse(out.contains("b@example.com"),
                       "double-quoted Target under a single-quoted TargetMode must be neutralized")
    }

    /// A value delimited by one quote style may legally CONTAIN the other, and
    /// an apostrophe in an email local part is both legal and real
    /// ("o'brien@..."). A matcher that ends the value at the first quote of
    /// EITHER style would rewrite only the opening fragment and strand the rest
    /// of the address as loose text in the part: a leak dressed up as a fix.
    func testNeutralizeExternalTargetsHandlesInnerQuoteOfTheOtherStyle() {
        let apostrophe = "<Relationships>"
            + "<Relationship Id=\"rId1\" TargetMode=\"External\" Target=\"mailto:o'brien@example.com\"/>"
            + "</Relationships>"
        let outApostrophe = DocxParts.neutralizeExternalTargets(apostrophe)
        XCTAssertFalse(outApostrophe.contains("example.com"),
                       "no fragment of an apostrophe-bearing address may survive the rewrite")
        XCTAssertTrue(outApostrophe.contains("Target=\"about:blank\""),
                      "a well-formed neutralized Target must replace the whole attribute")

        let innerDouble = "<Relationships>"
            + "<Relationship Id='rId1' TargetMode='External' Target='mailto:a\"b@example.com'/>"
            + "</Relationships>"
        let outInnerDouble = DocxParts.neutralizeExternalTargets(innerDouble)
        XCTAssertFalse(outInnerDouble.contains("example.com"),
                       "no fragment of a quote-bearing single-quoted address may survive")
        XCTAssertTrue(outInnerDouble.contains("Target=\"about:blank\""),
                      "a well-formed neutralized Target must replace the whole attribute")
    }

    func testNeutralizeExternalTargetsIgnoresDecoyAttributeNameTails() {
        // The whitespace lookbehind anchors the rewrite to the real attribute
        // name: an attribute whose name merely ENDS in "Target" must survive
        // untouched while the genuine Target on the same element is still
        // neutralized. No such decoy exists in the OOXML relationships schema
        // today, so this pins the boundary against a regression, not a live
        // exploit.
        let xml = "<Relationships>"
            + "<Relationship Id=\"rId1\" TargetMode=\"External\""
            + " FakeTarget=\"mailto:decoy@example.net\""
            + " Target='mailto:real@example.com'/>"
            + "</Relationships>"
        let out = DocxParts.neutralizeExternalTargets(xml)
        XCTAssertTrue(out.contains("FakeTarget=\"mailto:decoy@example.net\""),
                      "a decoy attribute name ending in Target must not be rewritten")
        XCTAssertFalse(out.contains("real@example.com"),
                       "the genuine Target on the same element must still be neutralized")
        XCTAssertTrue(out.contains("Target=\"about:blank\""),
                      "a well-formed neutralized Target must replace the whole attribute")
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

    /// custom.xml string-typed property values are blanked while the property
    /// names and structure survive. DMS-stamped custom properties (client
    /// names, matter numbers, billing codes) are a routine PII channel.
    func testScrubCustomPropsBlanksStringValues() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" \
        xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
        <property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="2" name="Client"><vt:lpwstr>Acme Corporation</vt:lpwstr></property>
        <property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="3" name="Matter"><vt:lpwstr>2026-0042 Roe Settlement</vt:lpwstr></property>
        <property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="4" name="Reviewed"><vt:bool>true</vt:bool></property>
        </Properties>
        """
        let out = DocxParts.scrubCustomProps(xml)
        XCTAssertFalse(out.contains("Acme Corporation"), "string property values must be blanked")
        XCTAssertFalse(out.contains("Roe Settlement"), "string property values must be blanked")
        XCTAssertTrue(out.contains("name=\"Client\""), "property names survive")
        XCTAssertTrue(out.contains("<vt:lpwstr></vt:lpwstr>"), "value tags survive empty")
        XCTAssertTrue(out.contains("<vt:bool>true</vt:bool>"), "non-string types are untouched")
    }

    /// The anonymize pipeline must scrub docProps/custom.xml and report how many
    /// embedded media files (signature images, stamps) were copied through
    /// unscanned, so the caller can warn the user.
    func testAnonymizeScrubsCustomPropsAndCountsMedia() throws {
        let withMedia = try writeCustomPropsFixtureDocx(includeMedia: true)
        let result = try LDAService.anonymize(
            input: withMedia,
            outputDir: workDir,
            protection: .passphrase("pw"),
            createdAtISO8601: Self.createdAt,
            llmModelPath: nil
        )

        let custom = try readPart("docProps/custom.xml", from: result.redactedFileURL)
        XCTAssertFalse(custom.contains("Acme Corporation"), "custom property value leaked")
        XCTAssertFalse(custom.contains("2026-0042"), "matter number leaked")
        XCTAssertEqual(
            result.embeddedMediaCount, 1,
            "one embedded media file must be reported as unscanned"
        )

        let withoutMedia = try writeCustomPropsFixtureDocx(includeMedia: false)
        let outputDir2 = workDir.appendingPathComponent("nomedia", isDirectory: true)
        let result2 = try LDAService.anonymize(
            input: withoutMedia,
            outputDir: outputDir2,
            protection: .passphrase("pw"),
            createdAtISO8601: Self.createdAt,
            llmModelPath: nil
        )
        XCTAssertEqual(result2.embeddedMediaCount, 0)
    }

    /// Minimal package with a custom.xml carrying client and matter identifiers
    /// and optionally an embedded media file.
    private func writeCustomPropsFixtureDocx(includeMedia: Bool) throws -> URL {
        let suffix = includeMedia ? "media" : "nomedia"
        let url = workDir.appendingPathComponent("customprops-\(suffix).docx")
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/docProps/custom.xml" ContentType="application/vnd.openxmlformats-officedocument.custom-properties+xml"/>
        </Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t xml:space="preserve">Contact jane.roe@example.com today.</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let custom = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties" \
        xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
        <property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="2" name="Client"><vt:lpwstr>Acme Corporation</vt:lpwstr></property>
        <property fmtid="{D5CDD505-2E9C-101B-9397-08002B2CF9AE}" pid="3" name="Matter"><vt:lpwstr>2026-0042</vt:lpwstr></property>
        </Properties>
        """
        var parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rels.utf8)),
            ("word/document.xml", Data(document.utf8)),
            ("docProps/custom.xml", Data(custom.utf8))
        ]
        if includeMedia {
            // Any bytes work; the pipeline only counts media entries.
            parts.append(("word/media/image1.png", Data([0x89, 0x50, 0x4E, 0x47])))
        }
        try DocxZip.writeArchive(parts: parts, to: url)
        return url
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

    private func anonymizeFullFixture() throws -> AnonymizeResult {
        try LDAService.anonymize(
            input: writeFullFixtureDocx(),
            outputDir: workDir,
            protection: .passphrase("pw"),
            createdAtISO8601: Self.createdAt,
            llmModelPath: nil
        )
    }

    /// Flip one byte in the target entry's compressed payload while preserving
    /// its local header and the central directory. ZIP enumeration therefore
    /// still names the part, but extraction fails its deflate or CRC check.
    private func corruptCompressedPayload(of targetPath: String, in archiveURL: URL) throws {
        var bytes = try Data(contentsOf: archiveURL)
        let localHeader = [UInt8](arrayLiteral: 0x50, 0x4B, 0x03, 0x04)
        var cursor = 0

        while cursor + 30 <= bytes.count {
            guard Array(bytes[cursor ..< cursor + 4]) == localHeader else {
                cursor += 1
                continue
            }
            let nameLength = Int(bytes[cursor + 26]) | (Int(bytes[cursor + 27]) << 8)
            let extraLength = Int(bytes[cursor + 28]) | (Int(bytes[cursor + 29]) << 8)
            let nameStart = cursor + 30
            let nameEnd = nameStart + nameLength
            guard nameEnd <= bytes.count else { break }
            let path = String(data: bytes[nameStart ..< nameEnd], encoding: .utf8)
            if path == targetPath {
                let payloadStart = nameEnd + extraLength
                guard payloadStart < bytes.count else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                bytes[payloadStart] ^= 0xFF
                try bytes.write(to: archiveURL, options: .atomic)
                return
            }
            cursor = nameEnd + extraLength
        }
        throw CocoaError(.fileReadNoSuchFile)
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
