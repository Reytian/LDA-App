//
//  FillServiceTests.swift
//  LDACoreTests
//
//  End-to-end tests for the three fill facade operations added to LDAService
//  in LDAFillService.swift: extractProfile, planFill, applyFill.
//
//  No GGUF model is required: all tests use the internal completer seam
//  (makeCompleterForTesting) to inject a FakeCompleter, or run modelPath-nil
//  so only deterministic matching applies.
//
//  Fixture helpers reuse the DocxFillTests pattern (buildDocumentXML, writeFixtureDocx)
//  and the AcroFormFillTests programmatic-PDF pattern (makeWidget, makePage).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import PDFKit
@testable import LDACore

final class FillServiceTests: XCTestCase {

    // MARK: - Hermetic working directory

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FillServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        // Clear the test seam so other test classes see no residue.
        LDAService.makeCompleterForTesting = nil
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fake completer

    /// A fake TextCompleter returning queued responses. Mirrors FakeCompleter in
    /// ProfileExtractorTests; each test file is intentionally self-contained.
    private final class FakeCompleter: TextCompleter {
        var queue: [String]
        init(_ queue: [String]) { self.queue = queue }
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return queue.isEmpty ? "[]" : queue.removeFirst()
        }
    }

    // MARK: - Docx fixture helpers
    //
    // Deliberately local copies following the DocxFillTests pattern. Each test
    // file stands alone without shared helper coupling.

    private struct FixtureParagraph { var runs: [String] }

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

    private func buildDocumentXML(_ paragraphs: [FixtureParagraph]) -> String {
        var body = ""
        for paragraph in paragraphs {
            body += "<w:p>"
            for runText in paragraph.runs {
                body += "<w:r><w:t xml:space=\"preserve\">"
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

    private func writeFixtureDocx(_ paragraphs: [FixtureParagraph], name: String? = nil) throws -> URL {
        let fileName = name ?? "lda-fillsvc-\(UUID().uuidString).docx"
        let url = workDir.appendingPathComponent(fileName)
        let documentXML = buildDocumentXML(paragraphs)
        let parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(Self.contentTypesXML.utf8)),
            ("_rels/.rels", Data(Self.relsXML.utf8)),
            ("word/document.xml", Data(documentXML.utf8))
        ]
        try DocxZip.writeArchive(parts: parts, to: url)
        return url
    }

    /// Rewrite a docx fixture at the same URL with new paragraph content.
    private func overwriteFixtureDocx(_ url: URL, paragraphs: [FixtureParagraph]) throws {
        let documentXML = buildDocumentXML(paragraphs)
        let parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(Self.contentTypesXML.utf8)),
            ("_rels/.rels", Data(Self.relsXML.utf8)),
            ("word/document.xml", Data(documentXML.utf8))
        ]
        try DocxZip.writeArchive(parts: parts, to: url)
    }

    // MARK: - AcroForm PDF fixture helpers
    //
    // Mirrors AcroFormFillTests.makeWidget; self-contained per the test-isolation rule.

    private static let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)

    private func makeWidget(
        name: String,
        fieldType: String,
        rect: CGRect,
        extraProperties: [AnyHashable: Any] = [:]
    ) -> PDFAnnotation {
        var props: [AnyHashable: Any] = [PDFAnnotationKey.widgetFieldType: fieldType]
        for (k, v) in extraProperties { props[k] = v }
        let annotation = PDFAnnotation(bounds: rect, forType: .widget, withProperties: props)
        annotation.fieldName = name
        if fieldType == "Tx" {
            annotation.widgetFieldType = .text
        } else if fieldType == "Btn" {
            annotation.widgetFieldType = .button
            annotation.widgetControlType = .checkBoxControl
        }
        return annotation
    }

    /// One-page form PDF: one text widget ("Company Name" with a space so the
    /// synonym pass can hit it directly), one checkbox ("Agree").
    private func makeFormPDF() throws -> URL {
        let page = PDFPage()
        page.setBounds(Self.pageBounds, for: .mediaBox)
        page.addAnnotation(makeWidget(
            name: "Company Name",
            fieldType: "Tx",
            rect: CGRect(x: 50, y: 700, width: 300, height: 20)
        ))
        page.addAnnotation(makeWidget(
            name: "Agree",
            fieldType: "Btn",
            rect: CGRect(x: 50, y: 660, width: 20, height: 20)
        ))
        let document = PDFDocument()
        document.insert(page, at: 0)
        let url = workDir.appendingPathComponent("form-\(UUID().uuidString).pdf")
        guard document.write(to: url) else {
            throw NSError(domain: "FillServiceTests.fixture", code: 1)
        }
        return url
    }

    /// Plain PDF with no widgets (tests that planFill returns an empty-blanks plan).
    private func makePlainPDF() throws -> URL {
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(Self.pageBounds, for: .mediaBox)
        document.insert(page, at: 0)
        let url = workDir.appendingPathComponent("plain-\(UUID().uuidString).pdf")
        guard document.write(to: url) else {
            throw NSError(domain: "FillServiceTests.fixture", code: 2)
        }
        return url
    }

    // MARK: - Helpers

    private static let createdAt = "2026-06-10T00:00:00Z"

    /// Build a minimal ClientPortfolio holding only companyName.
    private func makeProfile(companyName: String) -> ClientPortfolio {
        let field = ProfileField(
            key: .companyName,
            value: companyName,
            sourceDocument: "test",
            sourceSnippet: "",
            snippetVerified: false,
            confidence: 1.0,
            userEdited: false
        )
        return ClientPortfolio(
            label: "TestCo",
            fields: [field],
            sourceDocuments: ["test"],
            createdAtISO8601: Self.createdAt,
            incomplete: false
        )
    }

    // MARK: - extractProfile tests

    // Test: one readable .txt source and one nonexistent path.
    // The readable source contributes; the bad one lands in failedSources.
    // Uses the internal completer seam so no GGUF model is needed.
    func testExtractProfilePartialSourcesYieldsProfileAndFailedSources() throws {
        // Arrange: write a valid txt source.
        let sourceURL = workDir.appendingPathComponent("cert.txt")
        let sourceText = "The company name is Acme Holdings Limited."
        try Data(sourceText.utf8).write(to: sourceURL)

        let badURL = workDir.appendingPathComponent("does_not_exist.txt")

        // The fake completer returns one row for the readable source.
        let fakeRow = """
        [{"key":"companyName","value":"Acme Holdings Limited","snippet":"company name is Acme Holdings Limited","confidence":0.95}]
        """
        let fake = FakeCompleter([fakeRow])
        LDAService.makeCompleterForTesting = { fake }

        // Act
        let result = try LDAService.extractProfile(
            sources: [sourceURL, badURL],
            label: "Acme",
            modelPath: "fake-path",
            createdAtISO8601: Self.createdAt
        )

        // Assert: profile produced from the readable source.
        XCTAssertEqual(result.profile.label, "Acme")
        XCTAssertFalse(result.profile.fields.isEmpty, "profile must contain extracted fields")
        XCTAssertEqual(result.profile.fields.first?.key, .companyName)

        // The bad source must appear in failedSources.
        XCTAssertEqual(result.failedSources.count, 1)
        XCTAssertEqual(result.failedSources[0].name, badURL.lastPathComponent)
        XCTAssertFalse(result.failedSources[0].reason.isEmpty)
    }

    // Test: all sources unreadable throws noReadableSources.
    func testExtractProfileAllSourcesUnreadableThrowsNoReadableSources() throws {
        let badURL = workDir.appendingPathComponent("ghost.txt")
        let fake = FakeCompleter([])
        LDAService.makeCompleterForTesting = { fake }

        XCTAssertThrowsError(
            try LDAService.extractProfile(
                sources: [badURL],
                label: "Empty",
                modelPath: "fake-path",
                createdAtISO8601: Self.createdAt
            )
        ) { error in
            guard case LDAServiceError.noReadableSources = error else {
                return XCTFail("expected noReadableSources, got \(error)")
            }
        }
    }

    // MARK: - planFill tests

    // Test: planFill on a .txt target throws DocumentIOError.unsupportedFormat.
    func testPlanFillOnTxtTargetThrowsUnsupportedFormat() throws {
        let txtURL = workDir.appendingPathComponent("contract.txt")
        try Data("Hello [Company Name]".utf8).write(to: txtURL)
        let profile = makeProfile(companyName: "Acme Holdings Limited")

        XCTAssertThrowsError(
            try LDAService.planFill(
                target: txtURL,
                profile: profile,
                modelPath: nil
            )
        ) { error in
            guard case DocumentIOError.unsupportedFormat = error else {
                return XCTFail("expected unsupportedFormat, got \(error)")
            }
        }
    }

    // Test: planFill on a plain PDF with no widgets returns empty-blanks plan.
    func testPlanFillOnPlainPDFReturnsEmptyBlanks() throws {
        let pdfURL = try makePlainPDF()
        let profile = makeProfile(companyName: "Acme Holdings Limited")

        let plan = try LDAService.planFill(
            target: pdfURL,
            profile: profile,
            modelPath: nil
        )

        XCTAssertEqual(plan.targetFormat, .pdf)
        XCTAssertTrue(plan.blanks.isEmpty, "plain PDF with no widgets must produce no blanks")
        XCTAssertTrue(plan.manualWidgetNames.isEmpty)
    }

    // Test: planFill on a form PDF proposes a match for "Company Name" field via
    // the synonym table (no model required), and the checkbox goes into manualWidgetNames.
    func testPlanFillOnFormPDFProposesCompanyNameAndListsManualWidgets() throws {
        let pdfURL = try makeFormPDF()
        let profile = makeProfile(companyName: "Acme Holdings Limited")

        let plan = try LDAService.planFill(
            target: pdfURL,
            profile: profile,
            modelPath: nil
        )

        XCTAssertEqual(plan.targetFormat, .pdf)
        // "Company Name" must be proposed via the synonym pass.
        let companyBlank = plan.blanks.first { $0.location == .acroFormField(name: "Company Name") }
        XCTAssertNotNil(companyBlank, "Company Name field must appear as a blank")
        XCTAssertEqual(companyBlank?.status, .proposed)
        XCTAssertEqual(companyBlank?.proposedValue, "Acme Holdings Limited")
        // The checkbox must be reported as a manual widget.
        XCTAssertTrue(plan.manualWidgetNames.contains("Agree"))
    }

    // Test: planFill on a docx containing "[Company Name]" proposes a fill via
    // the synonym table (no model required).
    func testPlanFillOnDocxProposesCompanyName() throws {
        let docxURL = try writeFixtureDocx([
            .init(runs: ["This agreement is between [Company Name], a company"])
        ])
        let profile = makeProfile(companyName: "Acme Holdings Limited")

        let plan = try LDAService.planFill(
            target: docxURL,
            profile: profile,
            modelPath: nil
        )

        XCTAssertEqual(plan.targetFormat, .docx)
        let proposed = plan.blanks.first { $0.label == "Company Name" }
        XCTAssertNotNil(proposed, "Company Name blank must be proposed")
        XCTAssertEqual(proposed?.status, .proposed)
        XCTAssertEqual(proposed?.proposedValue, "Acme Holdings Limited")
    }


}
