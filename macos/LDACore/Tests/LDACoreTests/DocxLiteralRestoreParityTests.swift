//
//  DocxLiteralRestoreParityTests.swift
//  LDACoreTests
//
//  The literal restore of a .docx happens on two surfaces at once: the
//  compliance report scans the whole imported body text, while the writer
//  rewrites the w:t runs of word/document.xml. A word is routinely split
//  across several runs (bold, spell-check state, rsid splits), so a decision
//  taken run by run reads a DIFFERENT string than the report reads.
//
//  That divergence is not cosmetic. Under the asterisk style a mask is a pure
//  function of the surface, so 张三 masks to 张* and 张伟明 masks to 张*明, and
//  a site spelled by both is refused and flagged rather than guessed. When the
//  runs split 张*|明, an isolated run "张*" looks unambiguous to a per-run
//  walker: it writes 张三 into a document whose true party is 张伟明, while the
//  report, scanning the joined text, says the site was left as-is and nothing
//  was guessed.
//
//  The invariant pinned here: for one document and one mapping, the sites the
//  writer substitutes are exactly the sites the report counts as restored, and
//  the sites it leaves verbatim are exactly the ones the report reports as
//  ambiguous. Run boundaries must not enter the decision at all.
//
//  House rules: all comments and strings in English. Fixture values may be
//  Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxLiteralRestoreParityTests: XCTestCase {

    // MARK: - Fixture building

    /// A paragraph is an ordered list of run texts, so a test can place a
    /// replacement across a run boundary the way real Word markup does.
    private struct FixtureParagraph {
        var runs: [String]
    }

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

    /// Each run carries run properties so the test also proves formatting
    /// survives a cross-run writeback.
    private func buildDocumentXML(_ paragraphs: [FixtureParagraph]) -> String {
        var body = ""
        for paragraph in paragraphs {
            body += "<w:p>"
            for runText in paragraph.runs {
                body += "<w:r><w:rPr><w:b/></w:rPr>"
                body += "<w:t xml:space=\"preserve\">"
                body += xmlEncode(runText)
                body += "</w:t></w:r>"
            }
            body += "</w:p>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>\(body)</w:body>
        </w:document>
        """
    }

    /// Write a minimal valid .docx whose runs are exactly `runs`.
    private func writeFixtureDocx(paragraphs: [[String]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-parity-\(UUID().uuidString).docx")
        let documentXML = buildDocumentXML(paragraphs.map { FixtureParagraph(runs: $0) })
        try DocxZip.writeArchive(
            parts: [
                ("[Content_Types].xml", Data(Self.contentTypesXML.utf8)),
                ("_rels/.rels", Data(Self.relsXML.utf8)),
                ("word/document.xml", Data(documentXML.utf8))
            ],
            to: url
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func tempOutputURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-parity-out-\(UUID().uuidString).docx")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func entry(
        replacement: String,
        value: String,
        type: EntityType
    ) -> MappingEntry {
        MappingEntry(
            token: replacement,
            value: value,
            type: type,
            surfaceText: value,
            aliases: []
        )
    }

    private func mapping(
        _ entries: [String: MappingEntry],
        style: SubstitutionStyle
    ) -> Mapping {
        Mapping(
            entries: entries,
            createdAtISO8601: "2026-08-31T00:00:00Z",
            sourceFile: "doc.docx",
            style: style
        )
    }

    // MARK: - The parity harness

    /// Restore one fixture on both surfaces and assert they agree.
    ///
    /// The report is the whole-document scan LDAService runs over the
    /// PRE-restore imported text; the writer is DocxRedactor's run rewrite.
    /// Agreement is asserted three ways: the written document re-imports to
    /// the report's restored text, the substituted counts match, and the
    /// refused replacements match.
    @discardableResult
    private func assertWriterAgreesWithReport(
        paragraphs: [[String]],
        mapping fixtureMapping: Mapping,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (report: RestoreResult, restoredText: String) {
        let docx = try writeFixtureDocx(paragraphs: paragraphs)
        let out = tempOutputURL()

        let preRestoreText = try DocxImporter().importDocument(docx).text
        let report = Restorer.restore(text: preRestoreText, mapping: fixtureMapping)

        let outcome = try DocxRedactor.restoreLiteral(
            redactedDocx: docx,
            plan: Restorer.literalRestorePlan(for: fixtureMapping),
            to: out
        )
        let restoredText = try DocxImporter().importDocument(out).text

        XCTAssertEqual(
            restoredText,
            report.text,
            "the written document and the reported restore must be the same text",
            file: file,
            line: line
        )
        XCTAssertEqual(
            outcome.restoredCount,
            report.restoredCount,
            "the writer must substitute exactly the sites the report counts",
            file: file,
            line: line
        )
        XCTAssertEqual(
            outcome.ambiguousReplacements,
            report.ambiguousReplacements,
            "the writer must leave verbatim exactly the sites the report flags",
            file: file,
            line: line
        )
        return (report, restoredText)
    }

    // MARK: - The critical divergence

    /// A mask split across runs must not be resolved on the isolated run.
    ///
    /// Runs are "张*" and "明另有说法。". The joined text spells 张*明, which
    /// two masks match at the same position, so the site is refused. A per-run
    /// walker sees only "张*", finds no conflict, and writes 张三 over a site
    /// whose party is 张伟明 while the report says nothing was guessed.
    func testRunSplitMaskIsRefusedByTheWriterExactlyAsByTheReport() throws {
        let fixture = mapping(
            [
                "张*": entry(replacement: "张*", value: "张三", type: .person),
                "张*明": entry(replacement: "张*明", value: "张伟明", type: .person)
            ],
            style: .asterisk
        )

        let result = try assertWriterAgreesWithReport(
            paragraphs: [["张*", "明另有说法。"]],
            mapping: fixture
        )

        XCTAssertEqual(result.restoredText, "张*明另有说法。")
        XCTAssertFalse(
            result.restoredText.contains("张三"),
            "the wrong person was written into the document"
        )
        XCTAssertEqual(result.report.restoredCount, 0)
        XCTAssertEqual(result.report.ambiguousReplacements, ["张*明"])
    }

    /// The same shape one character further along: the run boundary falls
    /// inside the mask itself ("张" and "*明..."), so the isolated runs spell
    /// no replacement at all and the per-run walker silently restores nothing
    /// while the report still refuses the joined site.
    func testMaskSplitInsideItselfIsRefusedOnBothSurfaces() throws {
        let fixture = mapping(
            [
                "张*": entry(replacement: "张*", value: "张三", type: .person),
                "张*明": entry(replacement: "张*明", value: "张伟明", type: .person)
            ],
            style: .asterisk
        )

        let result = try assertWriterAgreesWithReport(
            paragraphs: [["本案当事人", "张", "*明", "到场。"]],
            mapping: fixture
        )

        XCTAssertEqual(result.restoredText, "本案当事人张*明到场。")
        XCTAssertEqual(result.report.ambiguousReplacements, ["张*明"])
    }

    /// The already-acknowledged direction, which the same fix closes: a
    /// replacement split across runs used to restore in the report and NOT in
    /// the document, so the report over-counted.
    func testReplacementSplitAcrossRunsRestoresInTheDocument() throws {
        let fixture = mapping(
            ["某公司A": entry(replacement: "某公司A", value: "北京华辰科技", type: .company)],
            style: .pseudonym
        )

        let result = try assertWriterAgreesWithReport(
            paragraphs: [["本案由", "某公司", "A", "承办。"]],
            mapping: fixture
        )

        XCTAssertEqual(result.restoredText, "本案由北京华辰科技承办。")
        XCTAssertEqual(result.report.restoredCount, 1)
        XCTAssertTrue(result.report.orphanTokens.isEmpty)
    }

    /// Longest match wins across a run boundary too: the site spells 某地址AA,
    /// not 某地址A followed by a stray letter.
    func testLongestMatchWinsAcrossARunBoundaryForPseudonyms() throws {
        let fixture = mapping(
            [
                "某地址A": entry(replacement: "某地址A", value: "1 Main St", type: .address),
                "某地址AA": entry(replacement: "某地址AA", value: "27 Long Rd", type: .address)
            ],
            style: .pseudonym
        )

        let result = try assertWriterAgreesWithReport(
            paragraphs: [["送达：某地址A", "A；抄送：某地址A。"]],
            mapping: fixture
        )

        XCTAssertEqual(result.restoredText, "送达：27 Long Rd；抄送：1 Main St。")
        XCTAssertEqual(result.report.restoredCount, 2)
    }

    /// The synthetic paragraph newline belongs to no run, so document-text
    /// offsets and run offsets differ by one per paragraph break. A site in
    /// the second paragraph must still land on the right run: an off-by-one
    /// here would write the value one character out.
    func testSitesInLaterParagraphsLandOnTheRightRuns() throws {
        let fixture = mapping(
            ["某公司A": entry(replacement: "某公司A", value: "北京华辰科技", type: .company)],
            style: .pseudonym
        )

        let result = try assertWriterAgreesWithReport(
            paragraphs: [["甲方：某公司", "A"], ["乙方：某公司A"]],
            mapping: fixture
        )

        XCTAssertEqual(result.restoredText, "甲方：北京华辰科技\n乙方：北京华辰科技")
        XCTAssertEqual(result.report.restoredCount, 2)
    }

    /// The other refusal reason travels the same way. 张* is shared outright
    /// by two people, so it is never substituted, and the site 张*明 is spelled
    /// by two masks. Both must reach the writer as refusals even though the
    /// runs split them, and both must appear in the report in document order.
    func testSharedMaskAndPrefixConflictBothReachTheWriter() throws {
        let fixture = mapping(
            [
                "张*": entry(replacement: "张*", value: "张三", type: .person),
                "张*#2": entry(replacement: "张*", value: "张万", type: .person),
                "张*明": entry(replacement: "张*明", value: "张伟明", type: .person)
            ],
            style: .asterisk
        )

        let result = try assertWriterAgreesWithReport(
            paragraphs: [["张", "*到场。张*", "明另有说法。"]],
            mapping: fixture
        )

        XCTAssertEqual(result.restoredText, "张*到场。张*明另有说法。")
        XCTAssertEqual(result.report.restoredCount, 0)
        XCTAssertEqual(result.report.ambiguousReplacements, ["张*", "张*明"])
    }

    /// Control: a single-run document already agreed before the fix, and must
    /// keep agreeing.
    func testSingleRunDocumentStillAgrees() throws {
        let fixture = mapping(
            [
                "张*": entry(replacement: "张*", value: "张三", type: .person),
                "张*明": entry(replacement: "张*明", value: "张伟明", type: .person)
            ],
            style: .asterisk
        )

        let result = try assertWriterAgreesWithReport(
            paragraphs: [["张*到场。张*明另有说法。"]],
            mapping: fixture
        )

        XCTAssertEqual(result.restoredText, "张三到场。张*明另有说法。")
        XCTAssertEqual(result.report.restoredCount, 1)
        XCTAssertEqual(result.report.ambiguousReplacements, ["张*明"])
    }

    // MARK: - The same invariant through the service facade

    /// The product-level statement of the defect. LDAService writes the
    /// restored .docx and hands the user a RestoreReport; the two must
    /// describe the same document. Before the fix this report said nothing
    /// was guessed while the file it wrote named 张三 instead of 张伟明.
    func testServiceRestoreReportDescribesTheDocumentItWrote() throws {
        let fixture = mapping(
            [
                "张*": entry(replacement: "张*", value: "张三", type: .person),
                "张*明": entry(replacement: "张*明", value: "张伟明", type: .person)
            ],
            style: .asterisk
        )
        let docx = try writeFixtureDocx(paragraphs: [["受托人张*", "明。见证人张*。"]])
        let mappingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-parity-\(UUID().uuidString).ldamap")
        addTeardownBlock { try? FileManager.default.removeItem(at: mappingURL) }
        let protection = MappingProtection.passphrase("parity-test-passphrase")
        try MappingStore.save(fixture, to: mappingURL, protection: protection)
        let out = tempOutputURL()

        let report = try LDAService.restore(
            editedRedacted: docx,
            mapping: mappingURL,
            protection: protection,
            output: out
        )
        let restoredText = try DocxImporter().importDocument(out).text

        // 张*明 is refused and stays verbatim; the isolated 张* is restored.
        XCTAssertEqual(restoredText, "受托人张*明。见证人张三。")
        XCTAssertEqual(report.restoredCount, 1)
        XCTAssertEqual(report.ambiguousReplacements, ["张*明"])
        XCTAssertFalse(
            restoredText.contains("张三明"),
            "the report promised the ambiguous site was left as-is"
        )
    }

    /// Formatting and untouched runs survive a cross-run writeback: the value
    /// lands in the first covered run and the covered tail is removed from the
    /// others, exactly as redaction writes a cross-run token.
    func testCrossRunWritebackPreservesRunPropertiesAndOtherRuns() throws {
        let fixture = mapping(
            ["某公司A": entry(replacement: "某公司A", value: "北京华辰科技", type: .company)],
            style: .pseudonym
        )
        let docx = try writeFixtureDocx(paragraphs: [["本案由", "某公司", "A", "承办。"]])
        let out = tempOutputURL()

        _ = try DocxRedactor.restoreLiteral(
            redactedDocx: docx,
            plan: Restorer.literalRestorePlan(for: fixture),
            to: out
        )

        let xml = String(
            data: try DocxZip.readEntry(docxMainPartPath, from: out),
            encoding: .utf8
        )
        XCTAssertNotNil(xml)
        XCTAssertEqual(
            xml?.components(separatedBy: "<w:b/>").count,
            5,
            "all four runs must keep their run properties"
        )
        XCTAssertEqual(xml?.contains("北京华辰科技"), true)
        XCTAssertEqual(xml?.contains("某公司"), false)
    }
}
