//
//  LDAServiceImageTests.swift
//  LDACoreTests
//
//  End-to-end tests for standalone image input through the service facade:
//  anonymize produces BOTH artifacts (redacted text companion plus redacted
//  PNG), the text artifact restores byte-identically, and restore of the
//  image artifact itself is refused with a clear error. The strongest leak
//  test re-OCRs the redacted PNG and greps for the planted values.
//
//  Tests whose names start with testOCRRoundTrip_ run live Vision and are the
//  slow ones, so a future CI split can shard on the name. No LLM model is
//  used anywhere here: the planted values are all deterministic-engine types.
//
//  House rules: all comments and strings in English (fixture content contains
//  Chinese by design). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class LDAServiceImageTests: XCTestCase {

    private let phone = ImageTextExtractorTests.plantedPhone
    private let idNumber = ImageTextExtractorTests.plantedID
    private let email = ImageTextExtractorTests.plantedEmail

    private var outputDir: URL!
    private var createdURLs: [URL] = []

    override func setUpWithError() throws {
        outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-image-service-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let outputDir {
            try? FileManager.default.removeItem(at: outputDir)
        }
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        createdURLs.removeAll()
    }

    private func track(_ url: URL) -> URL {
        createdURLs.append(url)
        return url
    }

    private func makeFixturePNG() throws -> URL {
        // The service tests ask one live Vision pass to recover four distinct
        // structured values. Larger glyphs keep that integration fixture
        // stable when the full suite runs several Vision tests concurrently.
        track(
            try ImageFixtureRenderer.writePNG(
                lines: ImageTextExtractorTests.fixtureLines,
                width: 2_200,
                fontSize: 80,
                lineHeight: 140
            )
        )
    }

    // MARK: - Anonymize (live Vision)

    /// The core image flow: anonymize produces a redacted .txt companion (the
    /// edit surface, restorable) plus a redacted .png (boxes over PII), the
    /// text carries placeholders instead of the planted values, and the
    /// mapping sidecar exists.
    func testOCRRoundTrip_anonymizeImageProducesTextAndImageArtifacts() throws {
        let input = try makeFixturePNG()

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: .passphrase("test-passphrase"),
            createdAtISO8601: "2026-08-30T12:00:00Z"
        )

        // Text artifact: same companion shape as the PDF path.
        XCTAssertEqual(result.redactedFileURL.pathExtension, "txt")
        let redactedText = try String(contentsOf: result.redactedFileURL, encoding: .utf8)

        let redactedDigits = ImageFixtureRenderer.digitsOnly(redactedText)
        XCTAssertFalse(redactedDigits.contains(phone), "phone leaked into redacted text")
        XCTAssertFalse(redactedDigits.contains(idNumber), "ID leaked into redacted text")
        XCTAssertFalse(redactedText.lowercased().contains(email), "email leaked into redacted text")

        // Token grammar strips underscores from type names ({NATIONALID_1}).
        XCTAssertTrue(redactedText.contains("{PHONE_"), "phone placeholder missing: \(redactedText)")
        XCTAssertTrue(redactedText.contains("{NATIONALID_"), "ID placeholder missing: \(redactedText)")
        XCTAssertTrue(redactedText.contains("{EMAIL_"), "email placeholder missing: \(redactedText)")
        XCTAssertTrue(redactedText.contains("{CASENUMBER_"), "case number placeholder missing: \(redactedText)")

        // Detection classified the planted values.
        let types = Set(result.entities.map { $0.type })
        XCTAssertTrue(types.contains(.phone))
        XCTAssertTrue(types.contains(.nationalID))
        XCTAssertTrue(types.contains(.email))
        XCTAssertTrue(types.contains(.caseNumber))

        // Image artifact: a PNG that differs from the source, with at least
        // one painted box and no unboxed values.
        let redactedImageURL = try XCTUnwrap(result.redactedImageURL, "image input must produce a redacted image")
        XCTAssertEqual(redactedImageURL.pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: redactedImageURL.path))
        XCTAssertNotEqual(try Data(contentsOf: input), try Data(contentsOf: redactedImageURL))
        XCTAssertGreaterThanOrEqual(result.imageRedactionCount, 4, "each planted value's line must be boxed")
        XCTAssertEqual(result.unboxedTokenCount, 0)
        XCTAssertNil(result.visualPdfURL, "an image is not a PDF; no review PDF is produced")

        // Mapping sidecar exists and holds the planted values.
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mappingFileURL.path))
        let mapping = try MappingStore.load(
            from: result.mappingFileURL,
            protection: .passphrase("test-passphrase")
        )
        let mappedDigits = mapping.entries.values.map { ImageFixtureRenderer.digitsOnly($0.value) }
        XCTAssertTrue(mappedDigits.contains { $0.contains(phone) }, "mapping must hold the phone value")
    }

    /// THE leak test: re-OCR the redacted PNG and require every planted value
    /// to be GONE from what a reader (human or OCR) can still recover.
    func testOCRRoundTrip_reOCROfRedactedImageFindsNoPlantedValues() throws {
        let input = try makeFixturePNG()

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: .passphrase("test-passphrase"),
            createdAtISO8601: "2026-08-30T12:00:00Z"
        )
        let redactedImageURL = try XCTUnwrap(result.redactedImageURL)

        // A fully covered image may legitimately OCR to nothing; that is the
        // best possible outcome for this assertion.
        let recovered: String
        do {
            recovered = try ImageTextExtractor().extract(redactedImageURL).text
        } catch DocumentIOError.unreadable {
            recovered = ""
        }

        let recoveredDigits = ImageFixtureRenderer.digitsOnly(recovered)
        XCTAssertFalse(recoveredDigits.contains(phone), "phone survived in the redacted image: \(recovered)")
        XCTAssertFalse(recoveredDigits.contains(idNumber), "ID survived in the redacted image: \(recovered)")
        XCTAssertFalse(recoveredDigits.contains("12345"), "case serial survived in the redacted image: \(recovered)")
        XCTAssertFalse(recovered.lowercased().contains("zhangwei"), "email survived in the redacted image: \(recovered)")
        XCTAssertFalse(recovered.lowercased().contains("example.com"), "email domain survived in the redacted image: \(recovered)")
    }

    /// The text artifact is the round-trip surface: restoring it against the
    /// mapping reproduces the OCR text byte-identically.
    func testOCRRoundTrip_imageTextArtifactRestoresByteIdentical() throws {
        let input = try makeFixturePNG()
        let sourceText = try ImageTextExtractor().extract(input).text

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: .passphrase("test-passphrase"),
            createdAtISO8601: "2026-08-30T12:00:00Z"
        )

        let restoredURL = outputDir.appendingPathComponent("restored.txt")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("test-passphrase"),
            output: restoredURL
        )

        XCTAssertGreaterThan(report.restoredCount, 0)
        XCTAssertTrue(report.orphanTokens.isEmpty)
        let restoredText = try String(contentsOf: restoredURL, encoding: .utf8)
        XCTAssertEqual(restoredText, sourceText, "restore must reproduce the OCR text byte-identically")
    }

    /// A misnamed image (PNG bytes under a .txt name, exactly what the vault
    /// produces for a staged image today) must still route through the image
    /// branch instead of being decoded as Latin-1 mojibake.
    func testOCRRoundTrip_misnamedImageStillRoutesThroughImageBranch() throws {
        let png = try makeFixturePNG()
        let misnamed = track(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("original-\(UUID().uuidString).txt")
        )
        try FileManager.default.copyItem(at: png, to: misnamed)

        let result = try LDAService.anonymize(
            input: misnamed,
            outputDir: outputDir,
            protection: .passphrase("test-passphrase"),
            createdAtISO8601: "2026-08-30T12:00:00Z"
        )

        XCTAssertNotNil(result.redactedImageURL, "magic-byte dispatch must reach the image branch")
        let redactedText = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertTrue(redactedText.contains("{PHONE_"), "misnamed image must still be OCR'd and redacted")
    }

    // MARK: - Restore refusal (no Vision)

    /// Restore of an image artifact is refused with a clear error: the boxes
    /// are destructive, so there is nothing to restore in the pixels. The
    /// guard fires before the mapping is even opened.
    func testRestoreRefusesImageArtifact() throws {
        let image = try ImageFixtureRenderer.render(lines: ["X"], width: 200, fontSize: 24, lineHeight: 40)
        let pngURL = track(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("redacted-\(UUID().uuidString).png")
        )
        try ImageFixtureRenderer.write(image: image, to: pngURL, typeIdentifier: "public.png")

        let bogusMapping = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).ldamap")

        XCTAssertThrowsError(
            try LDAService.restore(
                editedRedacted: pngURL,
                mapping: bogusMapping,
                protection: .passphrase("irrelevant"),
                output: FileManager.default.temporaryDirectory
                    .appendingPathComponent("out-\(UUID().uuidString).txt")
            )
        ) { error in
            guard case DocumentIOError.unsupportedFormat(let detail) = error else {
                return XCTFail("expected DocumentIOError.unsupportedFormat, got \(error)")
            }
            XCTAssertTrue(
                detail.lowercased().contains("cannot be restored"),
                "error must explain that an image cannot be restored; got: \(detail)"
            )
        }
    }
}
