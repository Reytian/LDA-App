//
//  DocxPackageLeakTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F5. The DOCX export scanned only w:t and w:delText and
//  neutralized only mailto: and tel: targets, so the review's probe document
//  came out with originals in: the hyperlink target in
//  word/_rels/document.xml.rels (the body showed {URL_1}); HYPERLINK, TA and
//  XE field instructions; a content control's w:alias, w:tag and w:listItem;
//  the header watermark's v:textpath string; TitlesOfParts, HLinks,
//  HyperlinkBase and Template in docProps/app.xml; cp:keywords, cp:category
//  and cp:contentStatus in docProps/core.xml. An SSN written with
//  w:noBreakHyphen between its groups was not detected, and a name holding
//  that element restored with the hyphen in the wrong place.
//
//  The export now audits the whole output package before it is moved into
//  place (every XML member parsed, character data and attribute values
//  searched for every value the export replaced, relationship targets
//  percent-decoded) and refuses on a hit, naming the member and the element,
//  never the value. The listed carriers are handled so ordinary documents
//  still export, and field instructions and text attributes restore.
//
//  The probe is the review's inputs/docx/mk.py rebuilt in Swift; its second
//  footnote's run-in name belongs to F9 and is written cleanly here. Every
//  name is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxPackageLeakTests: XCTestCase {

    // MARK: - The probe package

    static let namespaces = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" "#
        + #"xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" "#
        + #"xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office""#

    static func p(_ inner: String) -> String { "<w:p>\(inner)</w:p>" }
    static func r(_ text: String) -> String { #"<w:r><w:t xml:space="preserve">"# + text + "</w:t></w:r>" }
    static func field(_ instruction: String, result: String? = nil) -> String {
        var xml = #"<w:r><w:fldChar w:fldCharType="begin"/></w:r>"#
            + #"<w:r><w:instrText xml:space="preserve">"# + instruction + "</w:instrText></w:r>"
        if let result {
            xml += #"<w:r><w:fldChar w:fldCharType="separate"/></w:r>"# + r(result)
        }
        return xml + #"<w:r><w:fldChar w:fldCharType="end"/></w:r>"#
    }

    /// The probe's body paragraphs, with an optional extra paragraph.
    static func probeBody(extra: String = "") -> String {
        [
            p(r("SYNTHETIC TEST. This agreement is between Jordan Ellis and Willowcrest Studio LLC.")),
            p(r("Profile: ") + #"<w:hyperlink r:id="rId5">"# + r("https://www.linkedin.com/in/jordan-ellis-1234") + "</w:hyperlink>"),
            p(r("See the ") + field(#" HYPERLINK "https://willowcrest-studio.example/team/jordan-ellis" "#, result: "company page")
              + r(" for details.")),
            p(r("Authority cited.") + field(#" TA \l "Ellis v. Cedarbridge Analytics Inc., 123 F.3d 456" \s "Ellis" \c 1 "#)),
            p(r("Index entry.") + field(#" XE "Ellis, Jordan" "#)),
            p(#"<w:r><w:t xml:space="preserve">His SSN is 123</w:t><w:noBreakHyphen/><w:t>45</w:t><w:noBreakHyphen/>"#
              + #"<w:t>6789</w:t><w:t xml:space="preserve"> and he reports to Jean</w:t><w:noBreakHyphen/>"#
              + #"<w:t xml:space="preserve">Luc Moreau.</w:t></w:r>"#),
            p(#"<w:sdt><w:sdtPr><w:alias w:val="Signatory Jordan Ellis"/><w:tag w:val="jordan.ellis"/><w:dropDownList>"#
              + #"<w:listItem w:displayText="Jordan Ellis" w:value="Jordan Ellis"/>"#
              + #"<w:listItem w:displayText="Priya Raman" w:value="Priya Raman"/></w:dropDownList></w:sdtPr>"#
              + "<w:sdtContent>" + r("Choose a signatory") + "</w:sdtContent></w:sdt>"),
            p(r("Payment is due in 30 days.") + #"<w:r><w:footnoteReference w:id="2"/></w:r>"#),
            p(r("Second note.") + #"<w:r><w:footnoteReference w:id="3"/></w:r>"#),
            extra,
            #"<w:sectPr><w:headerReference w:type="default" r:id="rId6"/></w:sectPr>"#,
        ].joined()
    }

    static func writeProbe(to url: URL, extraBody: String = "", core: String? = nil) throws {
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:hdr \(namespaces)>"
            + p(r("Draft for Jordan Ellis")
                + ##"<w:r><w:pict><v:shape id="PowerPlusWaterMarkObject1" o:spid="_x0000_s2049" type="#_x0000_t136" "##
                + #"style="position:absolute;width:400pt;height:100pt"><v:textpath style="font-family:&quot;Calibri&quot;" "#
                + #"string="Prepared for Willowcrest Studio - J. Ellis copy"/></v:shape></w:pict></w:r>"#)
            + "</w:hdr>"
        let footnotes = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:footnotes \(namespaces)>"
            + #"<w:footnote w:type="separator" w:id="0"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>"#
            + #"<w:footnote w:type="continuationSeparator" w:id="1"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>"#
            + #"<w:footnote w:id="2">"# + p(r("Counsel for the buyer is Priya Raman of Hartwell Partners LLP.")) + "</w:footnote>"
            + #"<w:footnote w:id="3">"# + p(r("See the letter signed by Marek Okafor on file.")) + "</w:footnote></w:footnotes>"
        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document \(namespaces)><w:body>"
            + probeBody(extra: extraBody) + "</w:body></w:document>"
        let relsDocument = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + #"<Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes" Target="footnotes.xml"/>"#
            + #"<Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://www.linkedin.com/in/jordan-ellis-1234" TargetMode="External"/>"#
            + #"<Relationship Id="rId6" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>"#
            + "</Relationships>"
        let contentTypes = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
            + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>"#
            + #"<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>"#
            + #"<Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/>"#
            + #"<Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>"#
            + #"<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>"#
            + #"<Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>"#
        let relsRoot = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>"#
            + #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>"#
            + #"<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>"#
        let coreXML = core ?? (#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">"#
            + "<dc:title>SPA - Jordan Ellis / Willowcrest</dc:title><dc:subject>Willowcrest acquisition</dc:subject><dc:creator>Priya Raman</dc:creator>"
            + "<cp:keywords>Jordan Ellis; Willowcrest Studio; Project Falcon</cp:keywords><dc:description>Draft for Jordan Ellis</dc:description>"
            + "<cp:lastModifiedBy>Priya Raman</cp:lastModifiedBy><cp:category>Client Willowcrest</cp:category><cp:contentStatus>Sent to Jordan Ellis</cp:contentStatus></cp:coreProperties>")
        let app = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">"#
            + "<Template>Willowcrest-Client-Template.dotm</Template><Company>Hartwell Partners LLP</Company><Manager>Priya Raman</Manager>"
            + #"<TitlesOfParts><vt:vector size="1" baseType="lpstr"><vt:lpstr>SPA - Jordan Ellis / Willowcrest</vt:lpstr></vt:vector></TitlesOfParts>"#
            + #"<HLinks><vt:vector size="1" baseType="variant"><vt:variant><vt:lpwstr>https://www.linkedin.com/in/jordan-ellis-1234</vt:lpwstr></vt:variant></vt:vector></HLinks>"#
            + "<HyperlinkBase>https://willowcrest-studio.example/clients/jordan-ellis/</HyperlinkBase></Properties>"
        try DocxZip.writeArchive(parts: [
            ("[Content_Types].xml", Data(contentTypes.utf8)), ("_rels/.rels", Data(relsRoot.utf8)),
            ("word/document.xml", Data(document.utf8)), ("word/_rels/document.xml.rels", Data(relsDocument.utf8)),
            ("word/footnotes.xml", Data(footnotes.utf8)), ("word/header1.xml", Data(header.utf8)),
            ("docProps/core.xml", Data(coreXML.utf8)), ("docProps/app.xml", Data(app.utf8)),
        ], to: url)
    }

    /// What a model reports for every text it is given; values a text does
    /// not hold are ignored by the locator.
    static let reported = #"""
    {"entities":[{"value":"Jordan Ellis","type":"PERSON"},{"value":"Ellis, Jordan","type":"PERSON"},{"value":"Ellis","type":"PERSON"},{"value":"Willowcrest Studio LLC","type":"COMPANY"},{"value":"Willowcrest Studio","type":"COMPANY"},{"value":"Priya Raman","type":"PERSON"},{"value":"Hartwell Partners LLP","type":"COMPANY"},{"value":"Jean‑Luc Moreau","type":"PERSON"},{"value":"Cedarbridge Analytics Inc.","type":"COMPANY"},{"value":"Marek Okafor","type":"PERSON"}],"redacted_text":""}
    """#

    private struct FixedCompleter: TextCompleter {
        let output: String
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String { output }
    }

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocxPackageLeakTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        LDAService.makeExtractorForTesting = { _ in LLMExtractor(completer: FixedCompleter(output: Self.reported)) }
    }

    override func tearDownWithError() throws {
        LDAService.makeExtractorForTesting = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        try super.tearDownWithError()
    }

    private func anonymize(_ input: URL) throws -> AnonymizeResult {
        try LDAService.anonymize(
            input: input,
            outputDir: workDir.appendingPathComponent("out", isDirectory: true),
            protection: .passphrase("docx-package-leak"),
            createdAtISO8601: "2026-11-11T00:00:00Z",
            llmModelPath: workDir.appendingPathComponent("model.gguf").path
        )
    }

    /// Every member of the package as text, with XML references and percent
    /// escapes decoded and everything that is not a letter or a digit folded
    /// to one space, lowercased: the form an independent leak check reads.
    private func foldedMembers(of url: URL) throws -> [String: String] {
        var members: [String: String] = [:]
        let archive = try XCTUnwrap(try? ZIPArchiveReader.entries(of: url))
        for (path, data) in archive {
            guard let raw = String(data: data, encoding: .utf8) else { continue }
            var text = raw
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&amp;", with: "&")
            text = text.removingPercentEncoding ?? text
            let folded = String(text.lowercased().unicodeScalars.map {
                CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
            })
            members[path] = " " + folded.split(separator: " ").joined(separator: " ") + " "
        }
        return members
    }

    private static let leakProbes = [
        "jordan ellis", "ellis jordan", "willowcrest studio", "priya raman", "hartwell partners",
        "jean luc moreau", "cedarbridge analytics", "123 45 6789", "linkedin com in jordan ellis 1234",
        "jordan ellis 1234", "project falcon", "client willowcrest",
    ]

    // MARK: - The probe exports with no replaced value anywhere

    func testTheProbeExportsWithNoReplacedValueInAnyMember() throws {
        let input = workDir.appendingPathComponent("probe.docx")
        try Self.writeProbe(to: input)
        let result = try anonymize(input)
        for (path, folded) in try foldedMembers(of: result.redactedFileURL) {
            for probe in Self.leakProbes {
                XCTAssertFalse(folded.contains(" \(probe) "), "\(path) still holds \(probe)")
            }
            XCTAssertFalse(folded.contains(" jordan ellis ") || folded.contains(" ellis "),
                           "\(path) still holds a part of the name")
        }
    }

    func testAnSSNWrittenWithNonBreakingHyphensIsDetected() throws {
        let text = "His SSN is 123\u{2011}45\u{2011}6789 today."
        let spans = DeterministicEngine().detect(text)
        let ssn = try XCTUnwrap(spans.first { $0.text.contains("6789") }, "the SSN must be detected")
        XCTAssertEqual(ssn.text, "123\u{2011}45\u{2011}6789", "the value keeps the characters the document has")
    }

    func testANameHoldingANonBreakingHyphenRestoresWithTheHyphenInPlace() throws {
        let input = workDir.appendingPathComponent("probe.docx")
        try Self.writeProbe(to: input)
        let original = try DocxImporter().importDocument(input).text
        XCTAssertTrue(original.contains("Jean\u{2011}Luc Moreau"), "the hyphen element contributes its character")
        let result = try anonymize(input)
        let restoredURL = workDir.appendingPathComponent("restored.docx")
        _ = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("docx-package-leak"),
            output: restoredURL
        )
        let restored = try DocxImporter().importDocument(restoredURL).text
        XCTAssertEqual(restored, original)
    }

    func testFieldInstructionsAndContentControlsRestore() throws {
        let input = workDir.appendingPathComponent("probe.docx")
        try Self.writeProbe(to: input)
        let result = try anonymize(input)
        let restoredURL = workDir.appendingPathComponent("restored.docx")
        _ = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("docx-package-leak"),
            output: restoredURL
        )
        let restored = try DocxFixtureSupport.part("word/document.xml", in: restoredURL)
        XCTAssertTrue(restored.contains(#"TA \l "Ellis v. Cedarbridge Analytics Inc., 123 F.3d 456" \s "Ellis""#), restored)
        XCTAssertTrue(restored.contains(#"XE "Ellis, Jordan""#), restored)
        XCTAssertTrue(restored.contains(#"w:displayText="Priya Raman""#), restored)
        XCTAssertTrue(restored.contains(#"w:tag w:val="jordan.ellis""#), restored)
        XCTAssertTrue(restored.contains("https://willowcrest-studio.example/team/jordan-ellis"), restored)
    }

    func testAMetadataPartThatCannotBeReadRefusesTheExport() throws {
        let input = workDir.appendingPathComponent("probe.docx")
        // Not UTF-8: the scrub cannot read it, so copying it through would
        // ship whatever it holds.
        let latin1 = try XCTUnwrap("<cp:coreProperties><cp:keywords>Jordan Ellis \u{E9}</cp:keywords></cp:coreProperties>"
            .data(using: .isoLatin1))
        try Self.writeProbe(to: input, core: String(decoding: latin1, as: UTF8.self))
        // writeProbe stores the String as UTF-8; rewrite the member with the raw bytes.
        try ZIPArchiveReader.replace("docProps/core.xml", with: latin1, in: input)
        XCTAssertThrowsError(try anonymize(input))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workDir.appendingPathComponent("out/probe_redacted.docx").path
        ), "nothing is written")
    }

    // MARK: - The general mechanism: an unhandled carrier refuses

    func testAReplacedValueInACarrierLDADoesNotHandleRefusesAndNamesTheElement() throws {
        let input = workDir.appendingPathComponent("probe.docx")
        try Self.writeProbe(to: input, extraBody: #"<w:p><w:bookmarkStart w:id="0" w:name="Jordan_Ellis_signature"/>"#
            + Self.r("Signature block.") + #"<w:bookmarkEnd w:id="0"/></w:p>"#)
        XCTAssertThrowsError(try anonymize(input)) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("word/document.xml"), message)
            XCTAssertTrue(message.contains("w:bookmarkStart"), message)
            XCTAssertFalse(message.lowercased().contains("ellis"), "the value is never named: \(message)")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workDir.appendingPathComponent("out/probe_redacted.docx").path
        ), "nothing is written")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: workDir.appendingPathComponent("out").path)) ?? []
        XCTAssertFalse(leftovers.contains { $0.hasSuffix(".docx") }, "no partial package is left behind: \(leftovers)")
    }

    func testTheAuditReadsDecodedTextAndPercentDecodedTargets() throws {
        let url = workDir.appendingPathComponent("crafted.docx")
        try DocxZip.writeArchive(parts: [
            ("word/document.xml", Data(#"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Clean.</w:t></w:r></w:p></w:body></w:document>"#.utf8)),
            ("word/_rels/document.xml.rels", Data(#"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId9" Type="x" Target="https://example.com/J%6Frdan%20Ellis" TargetMode="External"/></Relationships>"#.utf8)),
        ], to: url)
        let finding = try XCTUnwrap(try DocxLeakAudit.firstFinding(
            inPackage: url,
            values: [("Jordan Ellis", .person)]
        ))
        XCTAssertEqual(finding.member, "word/_rels/document.xml.rels")
        XCTAssertEqual(finding.element, "Relationship")
        XCTAssertNil(try DocxLeakAudit.firstFinding(inPackage: url, values: [("Northwind Traders", .company)]))
    }

    // MARK: - Independent review of F5

    private func package(document: String, extra: [(String, String)] = []) throws -> URL {
        let url = workDir.appendingPathComponent("audit-\(UUID().uuidString).docx")
        let body = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>"#
            + document + "</w:t></w:r></w:p></w:body></w:document>"
        try DocxZip.writeArchive(parts: [("word/document.xml", Data(body.utf8))] + extra.map { ($0.0, Data($0.1.utf8)) }, to: url)
        return url
    }

    /// The independent review: a replaced $100 or $160, folded to "100" or
    /// "160", matched Word's own w:zoom w:percent="100" and
    /// w:spacing w:after="160" and refused ordinary documents (probes
    /// p22_zoom100.docx, p23_styles24.docx); the same short number would
    /// match "100 units" anywhere in the text. A value that folds to fewer
    /// than six digits is too generic to audit.
    func testAShortNumberDoesNotRefuseAnOrdinaryDocument() throws {
        let w = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        let url = try package(document: "Pay {AMOUNT_1} for 100 units and {AMOUNT_2} for 160 more.", extra: [
            ("word/settings.xml", "<w:settings \(w)><w:zoom w:percent=\"100\"/></w:settings>"),
            ("word/styles.xml", "<w:styles \(w)><w:style><w:pPr><w:spacing w:after=\"160\"/></w:pPr></w:style></w:styles>"),
        ])
        XCTAssertNil(try DocxLeakAudit.firstFinding(inPackage: url, values: [("$100", .amount), ("$160", .amount)]))
    }

    func testALongNumberIsStillAuditedEverywhere() throws {
        let w = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        let url = try package(document: "Clean.", extra: [
            ("word/settings.xml", "<w:settings \(w)><w:docVars><w:docVar w:name=\"x\" w:val=\"123-45-6789\"/></w:docVars></w:settings>"),
        ])
        let finding = try XCTUnwrap(try DocxLeakAudit.firstFinding(inPackage: url, values: [("123-45-6789", .nationalID)]))
        XCTAssertEqual(finding.member, "word/settings.xml")
    }

    /// The second independent review of F5 (probe t02_docket_link.docx): the
    /// six-digit floor meant for the audit was applied to hyperlink targets
    /// too, so a link to ".../docket/21-843.html" or ".../account/48213"
    /// kept the replaced docket and account numbers in the rels part while
    /// the body showed placeholders. A link is neutralized for any value the
    /// export replaced; only the audit keeps the floor.
    func testALinkTargetHoldingAShortReplacedNumberIsNeutralized() throws {
        let body = "Case No. 21-843 is set for argument. Paid into account no. 48213."
        let hyperlink = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
        let input = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(DocxTestPackage.run(body)),
            extraDocumentRelationships: [
                #"<Relationship Id="rId90" Type="\#(hyperlink)" Target="https://court.example/docket/21-843.html" TargetMode="External"/>"#,
                #"<Relationship Id="rId91" Type="\#(hyperlink)" Target="https://claims.example/account/48213" TargetMode="External"/>"#,
            ],
            to: workDir.appendingPathComponent("docket-link.docx")
        )
        let text = try DocxImporter().importDocument(input).text
        let replacements = [("21-843", EntityType.caseNumber, "{CASE_NUMBER_1}"), ("48213", .bankAccount, "{BANK_ACCOUNT_1}")]
            .map { value, type, token -> Replacement in
                let range = (text as NSString).range(of: value)
                return Replacement(
                    span: Span(start: range.location, end: range.location + range.length, type: type, text: value,
                               source: .deterministic, confidence: 1, priority: 100),
                    token: token
                )
            }
        let output = workDir.appendingPathComponent("docket-link-redacted.docx")
        let mapping = Mapping(entries: [:], createdAtISO8601: "2026-11-11T00:00:00Z", sourceFile: "docket-link.docx", style: .token)
        try DocxRedactor.redact(original: input, replacements: replacements, to: output,
                                nonBody: (mapping: mapping, detect: { _ in [] }))

        let rels = try DocxTestPackage.readPart("word/_rels/document.xml.rels", from: output)
        XCTAssertFalse(rels.contains("21-843"), rels)
        XCTAssertFalse(rels.contains("48213"), rels)
        XCTAssertEqual(rels.components(separatedBy: "about:blank").count - 1, 2, rels)
    }

    /// The independent review: a Latin name written against Chinese text in
    /// an attribute was not searched, because CJK characters are letters and
    /// the name had no word boundary. A change of script is one now.
    func testALatinNameWrittenAgainstChineseTextIsFound() throws {
        let url = try package(document: "Clean.", extra: [
            ("word/media-alt.xml", #"<alt descr="合同由Jordan Ellis签署"/>"#),
        ])
        let finding = try XCTUnwrap(try DocxLeakAudit.firstFinding(inPackage: url, values: [("Jordan Ellis", .person)]))
        XCTAssertEqual(finding.member, "word/media-alt.xml")
    }
}

/// Reads and rewrites zip members for the tests above without going through
/// the production writer's policies.
enum ZIPArchiveReader {
    static func entries(of url: URL) throws -> [(String, Data)] {
        try DocxParts.memberPaths(in: url).map { ($0, try DocxZip.readEntry($0, from: url)) }
    }

    static func replace(_ path: String, with data: Data, in url: URL) throws {
        let parts = try entries(of: url).map { $0.0 == path ? ($0.0, data) : $0 }
        try DocxZip.writeArchive(parts: parts, to: url)
    }
}
