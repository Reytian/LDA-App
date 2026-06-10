//
//  LDAServiceTests.swift
//  LDACoreTests
//
//  End-to-end tests for the LDAService facade. Every fixture is generated at
//  runtime under FileManager.temporaryDirectory, so no binary fixtures are
//  committed and the tests are fully hermetic and independent.
//
//  Coverage:
//  - .txt input: anonymize (passphrase protection) writes a redacted .txt that
//    carries tokens and an encrypted .ldamap sidecar; restore returns the EXACT
//    original text. The deterministic engine detects an email, a CN mobile, and a
//    checksum-valid 身份证.
//  - .docx input: anonymize preserves run formatting and restore round-trips back
//    to the original visible text.
//  - detect: returns the expected structured entity types.
//  - the .ldamap container is encrypted: a known plaintext surface value does not
//    appear in the on-disk bytes.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import CoreGraphics
import CoreText
@testable import LDACore

final class LDAServiceTests: XCTestCase {

    // MARK: - Constants

    /// A checksum-valid Chinese resident identity card number (ISO-7064 mod-11-2).
    /// Computed once and asserted valid below so the fixture stays self-checking.
    private static let validChineseID = "110101199003071233"

    /// A Chinese mainland mobile number (1 then 3-9 then nine more digits).
    private static let cnMobile = "13912345678"

    /// An email address the deterministic engine recognizes.
    private static let email = "jane.doe@example.com"

    /// Fixed ISO-8601 timestamp; the facade is clock-free so the caller supplies it.
    private static let createdAt = "2026-06-06T00:00:00Z"

    // MARK: - Hermetic working directory

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Sanity: the fixture ID must validate, otherwise detection would silently
        // drop it and the test would assert against a false premise.
        XCTAssertTrue(
            DeterministicEngine.isValidChineseID(Self.validChineseID),
            "fixture national ID must be checksum-valid"
        )
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDAServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        try super.tearDownWithError()
    }

    // MARK: - .txt end-to-end

    func testTextAnonymizeWritesTokensAndEncryptedMappingThenRestoresExactly() throws {
        // Arrange: a plain-text document carrying an email, a CN mobile, and a
        // checksum-valid national ID, plus surrounding prose to verify the
        // non-PII text is preserved verbatim.
        let original = """
        Engagement Letter

        Contact the client at \(Self.email) or by phone at \(Self.cnMobile).
        The client national ID on file is \(Self.validChineseID).
        Buyer and Seller agree to the terms herein.
        """
        let inputURL = workDir.appendingPathComponent("engagement.txt")
        try Data(original.utf8).write(to: inputURL)

        let outputDir = workDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let passphrase = "correct horse battery staple"

        // Act
        let result = try LDAService.anonymize(
            input: inputURL,
            outputDir: outputDir,
            protection: .passphrase(passphrase),
            createdAtISO8601: Self.createdAt
        )

        // Assert: a redacted .txt and a .ldamap sidecar exist; no review PDF.
        XCTAssertEqual(result.redactedFileURL.pathExtension.lowercased(), "txt")
        XCTAssertEqual(result.mappingFileURL.pathExtension.lowercased(), "ldamap")
        XCTAssertNil(result.visualPdfURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.redactedFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mappingFileURL.path))

        // The redacted text carries opaque tokens and no longer leaks any PII.
        let redactedText = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertFalse(redactedText.contains(Self.email), "email leaked into edit surface")
        XCTAssertFalse(redactedText.contains(Self.cnMobile), "mobile leaked into edit surface")
        XCTAssertFalse(redactedText.contains(Self.validChineseID), "national ID leaked into edit surface")
        XCTAssertTrue(redactedText.contains("{EMAIL_1}"))
        XCTAssertTrue(redactedText.contains("{PHONE_1}"))
        XCTAssertTrue(redactedText.contains("{NATIONALID_1}"))
        // Non-PII prose and role labels survive untouched.
        XCTAssertTrue(redactedText.contains("Engagement Letter"))
        XCTAssertTrue(redactedText.contains("Buyer and Seller agree"))

        // Three structured entities were tokenized.
        XCTAssertEqual(result.entityCount, 3)
        XCTAssertEqual(result.entities.count, 3)

        // The sidecar is encrypted: known plaintext surfaces are absent on disk.
        let onDisk = try Data(contentsOf: result.mappingFileURL)
        XCTAssertFalse(dataContains(onDisk, subsequence: Data(Self.email.utf8)),
                       "encrypted sidecar leaked the email")
        XCTAssertFalse(dataContains(onDisk, subsequence: Data(Self.cnMobile.utf8)),
                       "encrypted sidecar leaked the mobile")
        XCTAssertFalse(dataContains(onDisk, subsequence: Data(Self.validChineseID.utf8)),
                       "encrypted sidecar leaked the national ID")
        XCTAssertTrue(dataContains(onDisk, subsequence: Data("LDAMAP".utf8)),
                      "sidecar should carry the container magic header")

        // Act: restore on the unedited redacted edit surface.
        let restoredURL = workDir.appendingPathComponent("restored.txt")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase(passphrase),
            output: restoredURL
        )

        // Assert: the EXACT original text returns, with no orphan tokens.
        let restoredText = try String(contentsOf: restoredURL, encoding: .utf8)
        XCTAssertEqual(restoredText, original)
        XCTAssertEqual(report.restoredCount, 3)
        XCTAssertTrue(report.orphanTokens.isEmpty)
        XCTAssertEqual(report.outputURL, restoredURL)
    }

    // MARK: - .docx end-to-end

    func testDocxAnonymizePreservesFormattingAndRestoreRoundTrips() throws {
        // Arrange: a .docx whose runs carry bold run-properties. The email surface
        // is split across two runs so the cross-run redaction path is exercised.
        let inputURL = try writeFixtureDocx([
            ["Contact ", "jane.doe@", "example.com", " for details."],
            ["Phone ", Self.cnMobile, " is on file."]
        ])
        let importer = DocxImporter()
        let originalText = try importer.importDocument(inputURL).text

        let outputDir = workDir.appendingPathComponent("docx-out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let passphrase = "docx-round-trip-passphrase"

        // Act
        let result = try LDAService.anonymize(
            input: inputURL,
            outputDir: outputDir,
            protection: .passphrase(passphrase),
            createdAtISO8601: Self.createdAt
        )

        // Assert: a redacted .docx edit surface plus an encrypted sidecar, no PDF.
        XCTAssertEqual(result.redactedFileURL.pathExtension.lowercased(), "docx")
        XCTAssertNil(result.visualPdfURL)
        XCTAssertGreaterThanOrEqual(result.entityCount, 2)

        // Formatting survives: the bold run-properties remain and tokens are present
        // in the redacted document.xml, while the PII surfaces are gone.
        let redactedXML = try DocxZip.readEntry(docxMainPartPath, from: result.redactedFileURL)
        let xmlString = String(data: redactedXML, encoding: .utf8) ?? ""
        XCTAssertTrue(xmlString.contains("<w:b/>"), "run formatting should survive redaction")
        XCTAssertTrue(xmlString.contains("{EMAIL_1}"))
        XCTAssertFalse(xmlString.contains(Self.email), "email leaked into redacted docx")
        XCTAssertFalse(xmlString.contains(Self.cnMobile), "mobile leaked into redacted docx")

        // The redacted visible text holds tokens, not the original PII.
        let redactedText = try importer.importDocument(result.redactedFileURL).text
        XCTAssertFalse(redactedText.contains(Self.email))
        XCTAssertFalse(redactedText.contains(Self.cnMobile))
        XCTAssertTrue(redactedText.contains("{EMAIL_1}"))

        // The sidecar is encrypted: the email surface is absent from disk.
        let onDisk = try Data(contentsOf: result.mappingFileURL)
        XCTAssertFalse(dataContains(onDisk, subsequence: Data(Self.email.utf8)),
                       "encrypted sidecar leaked the docx email")

        // Act: restore on the unedited redacted .docx.
        let restoredURL = workDir.appendingPathComponent("restored.docx")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase(passphrase),
            output: restoredURL
        )

        // Assert: the original visible text returns and no orphan tokens remain.
        // For the docx path the facade substitutes token -> value on the runs and
        // then re-imports the restored docx to run the orphan guard, so the
        // restored visible text holds the original surfaces and zero tokens remain.
        let restoredText = try importer.importDocument(restoredURL).text
        XCTAssertEqual(restoredText, originalText)
        XCTAssertTrue(report.orphanTokens.isEmpty)
        XCTAssertFalse(restoredText.contains("{EMAIL_1}"))
        XCTAssertEqual(report.outputURL, restoredURL)
    }

    // MARK: - detect

    func testDetectReturnsExpectedStructuredEntityTypes() throws {
        let text = """
        Reach me at \(Self.email) or \(Self.cnMobile).
        National ID: \(Self.validChineseID). Effective 2026-01-15.
        """
        let inputURL = workDir.appendingPathComponent("detect.txt")
        try Data(text.utf8).write(to: inputURL)

        let spans = try LDAService.detect(input: inputURL)

        let types = Set(spans.map { $0.type })
        XCTAssertTrue(types.contains(.email))
        XCTAssertTrue(types.contains(.phone))
        XCTAssertTrue(types.contains(.nationalID))
        XCTAssertTrue(types.contains(.date))

        // Detection is deterministic-only in V1: no fuzzy PERSON/COMPANY/ADDRESS.
        XCTAssertFalse(types.contains(.person))
        XCTAssertFalse(types.contains(.company))
        XCTAssertFalse(types.contains(.address))

        // Every detected span carries the surface it covers and a deterministic
        // source, and spans are returned in ascending start order.
        for span in spans {
            XCTAssertEqual(span.source, .deterministic)
            XCTAssertFalse(span.text.isEmpty)
        }
        let starts = spans.map { $0.start }
        XCTAssertEqual(starts, starts.sorted())

        // The national ID span carries the exact, checksum-valid surface.
        let idSpan = try XCTUnwrap(spans.first { $0.type == .nationalID })
        XCTAssertEqual(idSpan.text, Self.validChineseID)
    }

    /// anonymize must create a missing output directory rather than failing, so a
    /// caller can point at a fresh path. Regression for an output-dir-not-created bug.
    func testAnonymizeCreatesMissingOutputDirectory() throws {
        let text = "Reach me at \(Self.email).\n"
        let inputURL = workDir.appendingPathComponent("fresh.txt")
        try Data(text.utf8).write(to: inputURL)

        // A nested directory that does not exist yet.
        let outDir = workDir
            .appendingPathComponent("does", isDirectory: true)
            .appendingPathComponent("not-exist-yet", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outDir.path))

        let result = try LDAService.anonymize(
            input: inputURL,
            outputDir: outDir,
            protection: .passphrase("pw"),
            createdAtISO8601: Self.createdAt
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.redactedFileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mappingFileURL.path))
    }

    // MARK: - Docx fixture builder

    /// Builds a minimal valid .docx whose paragraphs are ordered lists of run
    /// texts, each run carrying bold run-properties so a redact pass can be checked
    /// for formatting preservation. Returns a fresh temporary URL cleaned up at
    /// teardown.
    private func writeFixtureDocx(_ paragraphs: [[String]]) throws -> URL {
        let url = workDir.appendingPathComponent("fixture-\(UUID().uuidString).docx")

        var body = ""
        for runs in paragraphs {
            body += "<w:p>"
            for runText in runs {
                body += "<w:r><w:rPr><w:b/></w:rPr>"
                body += "<w:t xml:space=\"preserve\">"
                body += xmlEscape(runText)
                body += "</w:t></w:r>"
            }
            body += "</w:p>"
        }

        let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        let relsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>\(body)</w:body>
        </w:document>
        """

        try DocxZip.writeArchive(
            parts: [
                ("[Content_Types].xml", Data(contentTypesXML.utf8)),
                ("_rels/.rels", Data(relsXML.utf8)),
                ("word/document.xml", Data(documentXML.utf8))
            ],
            to: url
        )
        return url
    }

    /// XML-escapes the five predefined entities for safe inclusion in w:t.
    private func xmlEscape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }

    // MARK: - Image-PII channel integration tests

    /// A hybrid PDF (text layer + embedded raster image of "ZZSIGNZZ") must produce
    /// imageRedactionCount >= 1. The word is unique, absent from the typed body, and
    /// well clear of the text line, so any box over it proves the image channel ran.
    func testAnonymizeBoxesImageOnlySignatureOnHybridPdf() throws {
        let pdf = try makeHybridSignaturePdf()
        let result = try LDAService.anonymize(
            input: pdf, outputDir: workDir, protection: .passphrase("pw"),
            createdAtISO8601: Self.createdAt, llmModelPath: nil)

        XCTAssertGreaterThanOrEqual(result.imageRedactionCount, 1,
            "image-only signature was not redacted")
        XCTAssertNotNil(result.visualPdfURL)
        let review = try XCTUnwrap(result.visualPdfURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: review.path))
    }

    /// A PDF with no embedded images must have imageRedactionCount == 0: the image
    /// channel must not fire on a pure-text page.
    func testAnonymizeTextOnlyPdfHasNoImageRedactions() throws {
        let pdf = try makeTextOnlyPdf()
        let result = try LDAService.anonymize(
            input: pdf, outputDir: workDir, protection: .passphrase("pw"),
            createdAtISO8601: Self.createdAt, llmModelPath: nil)
        XCTAssertEqual(result.imageRedactionCount, 0)
    }

    // MARK: - PDF fixture builders

    private func makeHybridSignaturePdf() throws -> URL { try makePdf(imageWord: "ZZSIGNZZ") }
    private func makeTextOnlyPdf() throws -> URL { try makePdf(imageWord: nil) }

    /// One-page PDF with a typed text layer and, optionally, an image-only word
    /// drawn well clear of the text line so the image-PII pass can isolate it.
    private func makePdf(imageWord: String?) throws -> URL {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let url = workDir.appendingPathComponent("svc-\(UUID().uuidString).pdf")
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("no PDF context")
        }
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 26, nil)
        let body = NSAttributedString(string: "ENGAGEMENT LETTER FOR ACME CORP",
                                      attributes: [.font: font,
                                                   .foregroundColor: CGColor(gray: 0, alpha: 1)])
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(body), ctx)
        if let word = imageWord {
            guard let img = Self.wordImage(word) else {
                throw XCTSkip("CGContext unavailable to render the image fixture")
            }
            ctx.draw(img, in: CGRect(x: 72, y: 300, width: 360, height: 90))
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private static func wordImage(_ word: String) -> CGImage? {
        let w = 720, h = 180
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        let attr = NSAttributedString(string: word,
                                      attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)])
        c.textPosition = CGPoint(x: 20, y: 50)
        CTLineDraw(CTLineCreateWithAttributedString(attr), c)
        return c.makeImage()
    }

    // MARK: - Byte search helper

    /// Returns true when haystack contains the exact byte subsequence needle.
    private func dataContains(_ haystack: Data, subsequence needle: Data) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let hay = [UInt8](haystack)
        let need = [UInt8](needle)
        let lastStart = hay.count - need.count
        var start = 0
        while start <= lastStart {
            var matched = true
            var offset = 0
            while offset < need.count {
                if hay[start + offset] != need[offset] {
                    matched = false
                    break
                }
                offset += 1
            }
            if matched { return true }
            start += 1
        }
        return false
    }
    // MARK: - Restore same-path guard

    /// Restoring with output equal to the edited input used to delete the
    /// input before reading it (the rewrite clears the destination first),
    /// destroying the user's redacted file and failing with a confusing
    /// "corrupt" error. It must fail fast with a clear error instead.
    func testRestoreRefusesOutputEqualToInput() throws {
        let original = "Reach me at \(Self.email) please."
        let inputURL = workDir.appendingPathComponent("note.txt")
        try Data(original.utf8).write(to: inputURL)
        let outputDir = workDir.appendingPathComponent("out2", isDirectory: true)
        let result = try LDAService.anonymize(
            input: inputURL,
            outputDir: outputDir,
            protection: .passphrase("pw"),
            createdAtISO8601: Self.createdAt
        )

        XCTAssertThrowsError(
            try LDAService.restore(
                editedRedacted: result.redactedFileURL,
                mapping: result.mappingFileURL,
                protection: .passphrase("pw"),
                output: result.redactedFileURL
            )
        ) { error in
            XCTAssertEqual(error as? LDAServiceError, .outputEqualsInput)
        }

        // The redacted file must survive untouched.
        let stillThere = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertTrue(stillThere.contains("{EMAIL_1}"))
    }

}
