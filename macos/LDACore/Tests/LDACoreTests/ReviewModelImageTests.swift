//
//  ReviewModelImageTests.swift
//  LDACoreTests
//
//  GUI review-surface coverage for standalone image documents: import shows
//  the OCR text in the existing review pane (the OCR text IS the original
//  text for this document kind), and export produces the redacted text plus
//  the redacted PNG. The export re-reads the image; if its recognized text no
//  longer matches the reviewed text the export fails closed rather than
//  shipping a PNG whose boxes might not line up.
//
//  Tests whose names start with testOCRRoundTrip_ run live Vision and are the
//  slow ones, so a future CI split can shard on the name.
//
//  House rules: all comments and strings in English (fixture content contains
//  Chinese by design). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDAUI
@testable import LDACore

final class ReviewModelImageTests: XCTestCase {

    private var workDir: URL!
    private var createdURLs: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewModelImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        createdURLs.removeAll()
        try super.tearDownWithError()
    }

    private func track(_ url: URL) -> URL {
        createdURLs.append(url)
        return url
    }

    // MARK: - Import into the review pane

    /// Opening an image yields its OCR text as the document text: the review
    /// pane renders it like any other document, entities and all.
    func testOCRRoundTrip_importTextFromImageReturnsOCRText() throws {
        let png = track(try ImageFixtureRenderer.writePNG(lines: [
            "原告：张伟，电话\(ImageTextExtractorTests.plantedPhone)"
        ]))

        let text = try ReviewModel.importText(from: png)

        XCTAssertTrue(
            ImageFixtureRenderer.digitsOnly(text).contains(ImageTextExtractorTests.plantedPhone),
            "review text must be the OCR text, got: \(text)"
        )
        XCTAssertFalse(text.contains("PNG"), "raster bytes must never be decoded as text")
    }

    // MARK: - Export

    /// Exporting a reviewed image writes the redacted .txt, the mapping, AND
    /// the redacted .png; the re-OCR of the png no longer shows the value the
    /// user accepted for redaction.
    func testOCRRoundTrip_performExportImageWritesRedactedTextAndPNG() throws {
        let png = track(try ImageFixtureRenderer.writePNG(lines: [
            "原告：张伟，电话\(ImageTextExtractorTests.plantedPhone)"
        ]))
        let ocrText = try ImageTextExtractor().extract(png).text
        let spans = DeterministicEngine().detect(ocrText)
        XCTAssertFalse(spans.isEmpty, "the deterministic engine must find the planted phone")

        let outcome = try ReviewModel.performExport(
            text: ocrText,
            acceptedSpans: spans,
            source: png,
            custom: [],
            useLLM: false,
            modelPath: nil,
            outputDir: workDir,
            passphrase: "test-passphrase",
            createdAtISO8601: "2026-08-30T12:00:00Z"
        )

        // Text artifact plus mapping, as for any other document.
        let redactedText = try String(contentsOf: outcome.export.redactedURL, encoding: .utf8)
        XCTAssertTrue(redactedText.contains("{PHONE_"))
        XCTAssertFalse(
            ImageFixtureRenderer.digitsOnly(redactedText).contains(ImageTextExtractorTests.plantedPhone)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.export.mappingURL.path))

        // Image artifact: present, differs from the source, and re-OCR shows
        // no trace of the accepted value.
        let imageURL = try XCTUnwrap(
            outcome.export.redactedImageURL,
            "image export must produce the redacted PNG"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertNotEqual(try Data(contentsOf: png), try Data(contentsOf: imageURL))

        let recovered: String
        do {
            recovered = try ImageTextExtractor().extract(imageURL).text
        } catch DocumentIOError.unreadable {
            recovered = ""
        }
        XCTAssertFalse(
            ImageFixtureRenderer.digitsOnly(recovered).contains(ImageTextExtractorTests.plantedPhone),
            "accepted value survived in the exported PNG: \(recovered)"
        )
    }

    /// A document source keeps redactedImageURL nil: only images get the
    /// extra artifact.
    func testPerformExportTextSourceHasNoImageArtifact() throws {
        let source = workDir.appendingPathComponent("notes.txt")
        try Data("Mail jane@example.com now.".utf8).write(to: source)
        let text = "Mail jane@example.com now."
        let spans = DeterministicEngine().detect(text)

        let outcome = try ReviewModel.performExport(
            text: text,
            acceptedSpans: spans,
            source: source,
            custom: [],
            useLLM: false,
            modelPath: nil,
            outputDir: workDir,
            passphrase: "test-passphrase",
            createdAtISO8601: "2026-08-30T12:00:00Z"
        )

        XCTAssertNil(outcome.export.redactedImageURL)
    }

    /// Fail closed: when the image's recognized text no longer matches the
    /// reviewed text (file changed on disk), the export throws instead of
    /// shipping a PNG whose boxes may sit on the wrong lines.
    func testOCRRoundTrip_performExportImageFailsClosedWhenTextDiverges() throws {
        let png = track(try ImageFixtureRenderer.writePNG(lines: [
            "原告：张伟，电话\(ImageTextExtractorTests.plantedPhone)"
        ]))

        XCTAssertThrowsError(
            try ReviewModel.performExport(
                text: "reviewed text that is not the OCR text",
                acceptedSpans: [],
                source: png,
                custom: [],
                useLLM: false,
                modelPath: nil,
                outputDir: workDir,
                passphrase: "test-passphrase",
                createdAtISO8601: "2026-08-30T12:00:00Z"
            )
        ) { error in
            guard case DocumentIOError.corrupt(let detail) = error else {
                return XCTFail("expected DocumentIOError.corrupt, got \(error)")
            }
            XCTAssertTrue(
                detail.lowercased().contains("no longer matches"),
                "error must explain the OCR text mismatch; got: \(detail)"
            )
        }
    }
}
