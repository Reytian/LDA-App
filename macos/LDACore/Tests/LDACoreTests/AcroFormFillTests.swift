//
//  AcroFormFillTests.swift
//  LDACoreTests
//
//  AcroForm enumeration and text-widget filling. Fixtures are built
//  programmatically with PDFKit in the temporary directory.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import PDFKit
@testable import LDACore

final class AcroFormFillTests: XCTestCase {

    // MARK: - Hermetic working directory

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AcroFormFillTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        try super.tearDownWithError()
    }

    private func tempURL(_ ext: String) -> URL {
        workDir
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    // MARK: - Fixture builders

    /// Standard media box used for all fixture pages.
    private static let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)

    /// Build a widget annotation using a low-level properties dictionary so that
    /// the annotation type and AcroForm keys round-trip through PDFDocument.write.
    /// PDFKit on macOS 13+ requires explicit /FT and /T in the properties dict for
    /// the widget subtype and field name to survive write-reload cycles; setting
    /// widgetFieldType and fieldName on the returned annotation may not be sufficient
    /// on all OS versions.
    private func makeWidget(
        name: String,
        fieldType: String,         // "Tx" for text, "Btn" for button
        rect: CGRect,
        extraProperties: [AnyHashable: Any] = [:]
    ) -> PDFAnnotation {
        var props: [AnyHashable: Any] = [
            PDFAnnotationKey.widgetFieldType: fieldType,
        ]
        for (k, v) in extraProperties { props[k] = v }
        let annotation = PDFAnnotation(bounds: rect, forType: .widget, withProperties: props)
        annotation.fieldName = name
        // Belt-and-suspenders: also set the typed properties in case the OS version
        // honours them directly.
        if fieldType == "Tx" {
            annotation.widgetFieldType = .text
        } else if fieldType == "Btn" {
            annotation.widgetFieldType = .button
            annotation.widgetControlType = .checkBoxControl
        }
        return annotation
    }

    /// One-page form: two text widgets (CompanyName, RegNumber) and one checkbox (Agree).
    private func makeFormPDF() throws -> URL {
        let page = PDFPage()
        page.setBounds(Self.pageBounds, for: .mediaBox)

        page.addAnnotation(makeWidget(
            name: "CompanyName", fieldType: "Tx",
            rect: CGRect(x: 50, y: 700, width: 300, height: 20)
        ))
        page.addAnnotation(makeWidget(
            name: "RegNumber", fieldType: "Tx",
            rect: CGRect(x: 50, y: 660, width: 300, height: 20)
        ))
        page.addAnnotation(makeWidget(
            name: "Agree", fieldType: "Btn",
            rect: CGRect(x: 50, y: 620, width: 20, height: 20)
        ))

        let document = PDFDocument()
        document.insert(page, at: 0)
        let url = tempURL("pdf")
        guard document.write(to: url) else { throw NSError(domain: "AcroFormFillTests.fixture", code: 1) }
        return url
    }

    /// Two-page form: each page carries a text widget named "CompanyName" (AcroForm
    /// treats same-named widgets on different pages as one logical field).
    private func makeTwoPageSameFieldPDF() throws -> URL {
        func makePage(y: CGFloat) -> PDFPage {
            let page = PDFPage()
            page.setBounds(Self.pageBounds, for: .mediaBox)
            page.addAnnotation(makeWidget(
                name: "CompanyName", fieldType: "Tx",
                rect: CGRect(x: 50, y: y, width: 300, height: 20)
            ))
            return page
        }

        let document = PDFDocument()
        document.insert(makePage(y: 700), at: 0)
        document.insert(makePage(y: 700), at: 1)
        let url = tempURL("pdf")
        guard document.write(to: url) else { throw NSError(domain: "AcroFormFillTests.fixture", code: 2) }
        return url
    }

    // MARK: - Helper: re-read all text-widget values from a saved PDF

    private func readTextWidgetValues(from url: URL) -> [String: String] {
        guard let doc = PDFDocument(url: url) else { return [:] }
        var result: [String: String] = [:]
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for annotation in page.annotations where annotation.widgetFieldType == .text {
                let name = annotation.fieldName ?? ""
                guard !name.isEmpty else { continue }
                result[name] = annotation.widgetStringValue
            }
        }
        return result
    }

    // MARK: - Tests

    func testEnumerateFindsTextWidgetsAndManualWidgets() throws {
        let url = try makeFormPDF()
        let form = try AcroFormFiller.enumerate(at: url)
        XCTAssertEqual(Set(form.textFieldNames), ["CompanyName", "RegNumber"],
                       "enumerate must surface both text widgets")
        XCTAssertEqual(Set(form.manualWidgetNames), ["Agree"],
                       "checkbox widget must appear in manualWidgetNames")
    }

    func testFillWritesValuesToNewFileAndOriginalUntouched() throws {
        let url = try makeFormPDF()
        let originalBytes = try Data(contentsOf: url)
        let out = tempURL("pdf")

        try AcroFormFiller.fill(
            original: url,
            values: ["CompanyName": "Acme Holdings Limited", "RegNumber": "1234567"],
            to: out
        )

        // Original must be byte-identical after fill.
        XCTAssertEqual(try Data(contentsOf: url), originalBytes,
                       "fill must never modify the original file")

        // Output must contain the filled values.
        let found = readTextWidgetValues(from: out)
        XCTAssertEqual(found["CompanyName"], "Acme Holdings Limited")
        XCTAssertEqual(found["RegNumber"], "1234567")
    }

    func testFillUnknownFieldNameThrowsStaleTarget() throws {
        let url = try makeFormPDF()
        let out = tempURL("pdf")
        XCTAssertThrowsError(
            try AcroFormFiller.fill(original: url, values: ["Vanished": "x"], to: out)
        ) { error in
            guard case AcroFormFiller.FillError.staleTarget(let missing) = error else {
                return XCTFail("expected staleTarget, got \(error)")
            }
            XCTAssertEqual(missing, ["Vanished"])
        }
    }

    func testNonFormPDFReportsNoFields() throws {
        // A plain page with no widgets: enumerate must return empty lists, not an error.
        let document = PDFDocument()
        let plainPage = PDFPage()
        plainPage.setBounds(Self.pageBounds, for: .mediaBox)
        document.insert(plainPage, at: 0)
        let url = tempURL("pdf")
        XCTAssertTrue(document.write(to: url), "fixture write must succeed")

        let form = try AcroFormFiller.enumerate(at: url)
        XCTAssertTrue(form.textFieldNames.isEmpty, "no text fields expected in a plain page")
        XCTAssertTrue(form.manualWidgetNames.isEmpty, "no manual widgets expected in a plain page")
    }

    /// AcroForm semantics: same-named widgets on different pages are one logical
    /// field. fill() writes the value to EVERY matching widget, not just the first.
    func testFillSameNamedWidgetOnBothPagesReceivesValue() throws {
        let url = try makeTwoPageSameFieldPDF()
        let out = tempURL("pdf")

        try AcroFormFiller.fill(
            original: url,
            values: ["CompanyName": "Global Ventures Inc"],
            to: out
        )

        guard let doc = PDFDocument(url: out) else {
            XCTFail("could not reload filled PDF")
            return
        }

        // Collect per-page widget values, confirming BOTH widgets carry the value.
        var pageValues: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for annotation in page.annotations where annotation.widgetFieldType == .text {
                if annotation.fieldName == "CompanyName" {
                    pageValues.append(annotation.widgetStringValue ?? "")
                }
            }
        }
        XCTAssertEqual(pageValues.count, 2,
                       "both pages must carry a CompanyName widget")
        XCTAssertTrue(pageValues.allSatisfy { $0 == "Global Ventures Inc" },
                      "every CompanyName widget must have the filled value; got \(pageValues)")
    }
}
