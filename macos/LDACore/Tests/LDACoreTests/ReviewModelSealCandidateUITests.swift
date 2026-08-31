//
//  ReviewModelSealCandidateUITests.swift
//  LDACoreTests
//
//  The GUI half of the image seal candidate channel. The channel shipped in
//  LDACore (SealCandidateDetector plus the candidate-aware ImageRedactor) and
//  on the CLI route, but the window's export path called the older
//  candidate-free overload, so a red-stamped receipt exported from the app
//  still showed the stamp with no count and no warning anywhere. These tests
//  pin the wiring: the export requests candidates, both image counts reach
//  the reported result, and the per-document toggle is honored.
//
//  Tests whose names start with testOCRRoundTrip_ run live Vision, matching
//  the ReviewModelImageTests sharding convention.
//
//  Claims discipline (docs/positioning-claims.md): red regions are
//  CANDIDATES. The wording tests assert that the UI copy never claims a seal
//  was detected or confirmed.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import CoreGraphics
@testable import LDAUI
@testable import LDACore

@MainActor
final class ReviewModelSealCandidateUITests: XCTestCase {

    private static let createdAt = "2026-08-31T12:00:00Z"

    /// The stamp ellipse, in CG bottom-left pixels, clear of the text lines.
    private static let stamp = CGRect(x: 1400, y: 40, width: 180, height: 180)

    private var workDir: URL!
    private var createdURLs: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewModelSealCandidateUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
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

    private func stampedFixture() throws -> URL {
        track(try ImageFixtureRenderer.writeStampedPNG(
            lines: ["联系电话 13812345678", "邮箱 user@example.com"],
            stamp: Self.stamp
        ))
    }

    private func outputDir(_ name: String) throws -> URL {
        let url = workDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The export path requests candidates

    /// The regression this file exists for: the window's own export worker,
    /// left at its defaults, boxes the stamp and reports how many candidates
    /// entered the coverage.
    func testOCRRoundTrip_windowExportBoxesSealCandidatesByDefault() throws {
        let png = try stampedFixture()
        let extraction = try ImageTextExtractor().extract(png)
        let spans = DeterministicEngine().detect(extraction.text)
        XCTAssertFalse(spans.isEmpty, "fixture: the planted phone and email must be detected")

        let outcome = try ReviewModel.performExport(
            text: extraction.text,
            acceptedSpans: spans,
            source: png,
            custom: [],
            useLLM: false,
            modelPath: nil,
            outputDir: try outputDir("default"),
            passphrase: "test-passphrase",
            createdAtISO8601: Self.createdAt
        )

        XCTAssertGreaterThanOrEqual(
            outcome.export.sealCandidateCount,
            1,
            "the window export must box the stamp region, as the CLI route does"
        )
        XCTAssertNotNil(outcome.export.redactedImageURL)
    }

    /// Turning the per-document choice off drops the candidate boxes: the
    /// count goes to zero and the rendered PNG is a different image.
    func testOCRRoundTrip_windowExportHonorsTheCandidateToggle() throws {
        let png = try stampedFixture()
        let extraction = try ImageTextExtractor().extract(png)
        let spans = DeterministicEngine().detect(extraction.text)

        let withCandidates = try ReviewModel.performExport(
            text: extraction.text,
            acceptedSpans: spans,
            source: png,
            custom: [],
            useLLM: false,
            modelPath: nil,
            outputDir: try outputDir("on"),
            passphrase: "test-passphrase",
            createdAtISO8601: Self.createdAt,
            style: .token,
            includeSealCandidates: true
        )
        let withoutCandidates = try ReviewModel.performExport(
            text: extraction.text,
            acceptedSpans: spans,
            source: png,
            custom: [],
            useLLM: false,
            modelPath: nil,
            outputDir: try outputDir("off"),
            passphrase: "test-passphrase",
            createdAtISO8601: Self.createdAt,
            style: .token,
            includeSealCandidates: false
        )

        XCTAssertGreaterThanOrEqual(withCandidates.export.sealCandidateCount, 1)
        XCTAssertEqual(
            withoutCandidates.export.sealCandidateCount,
            0,
            "the toggle must reach the redactor, not just the reported count"
        )
        let boxed = try Data(contentsOf: XCTUnwrap(withCandidates.export.redactedImageURL))
        let unboxed = try Data(contentsOf: XCTUnwrap(withoutCandidates.export.redactedImageURL))
        XCTAssertNotEqual(
            boxed,
            unboxed,
            "with candidates off the stamp must actually stay unpainted"
        )
    }

    /// Ranges the image geometry cannot box are counted, never dropped. A
    /// replaced range sitting on the newline BETWEEN two observation lines
    /// belongs to no line box, which is exactly the shape of the real failure
    /// (a value the text companion redacted that the exported image may still
    /// show). The fixture carries no red, so the candidate count stays 0 and
    /// the two counts are proven independent.
    func testOCRRoundTrip_windowExportReportsRangesItCouldNotBox() throws {
        let png = track(try ImageFixtureRenderer.writePNG(lines: [
            "联系电话 13812345678",
            "邮箱 user@example.com"
        ]))
        let extraction = try ImageTextExtractor().extract(png)
        try XCTSkipUnless(
            extraction.lines.count >= 2,
            "fixture: two observation lines are needed for a separator newline"
        )
        let separator = extraction.lines[0].range.upperBound
        let unlocatable = Span(
            start: separator,
            end: separator + 1,
            type: .person,
            text: "\n",
            source: .manual,
            confidence: 1,
            priority: 1
        )

        let outcome = try ReviewModel.performExport(
            text: extraction.text,
            acceptedSpans: [unlocatable],
            source: png,
            custom: [],
            useLLM: false,
            modelPath: nil,
            outputDir: try outputDir("unboxed"),
            passphrase: "test-passphrase",
            createdAtISO8601: Self.createdAt
        )

        XCTAssertEqual(
            outcome.export.unboxedTokenCount,
            1,
            "a replaced range with no line box must reach the reported result"
        )
        XCTAssertEqual(outcome.export.sealCandidateCount, 0, "this fixture has no red regions")
    }

    // MARK: - The model gate and the per-document choice

    /// The choice exists for image documents and for nothing else, and it is
    /// read through the model's gate rather than re-derived per control.
    func testOCRRoundTrip_theCandidateChoiceIsGatedToImageDocuments() async throws {
        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        XCTAssertFalse(model.canChooseSealCandidates, "no document, no choice")

        let text = workDir.appendingPathComponent("notes.txt")
        try Data("Mail jane@example.com now.".utf8).write(to: text)
        await model.open(text)
        XCTAssertFalse(model.canChooseSealCandidates, "a text document has no image artifact")

        await model.open(try stampedFixture())
        XCTAssertTrue(model.canChooseSealCandidates)
        XCTAssertTrue(model.includeSealCandidates, "covering is the default")
    }

    /// The whole window path, end to end: open, scan, export. The default run
    /// boxes candidates, and the same model with the choice turned off does
    /// not. Opening the next document restores the covering default.
    func testOCRRoundTrip_exportThroughTheModelFollowsThePerDocumentChoice() async throws {
        let png = try stampedFixture()
        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        await model.open(png)
        await model.anonymize()
        XCTAssertTrue(model.canExport, "fixture: the scan must finish ready to export")

        let covering = try await model.export(
            to: try outputDir("model-on"),
            passphrase: "test-passphrase",
            createdAtISO8601: Self.createdAt
        )
        XCTAssertGreaterThanOrEqual(covering.sealCandidateCount, 1)

        model.includeSealCandidates = false
        let bare = try await model.export(
            to: try outputDir("model-off"),
            passphrase: "test-passphrase",
            createdAtISO8601: Self.createdAt
        )
        XCTAssertEqual(bare.sealCandidateCount, 0)

        await model.open(png)
        XCTAssertTrue(
            model.includeSealCandidates,
            "the choice is per document, so the next document starts covering"
        )
    }

    // MARK: - Reported wording

    func testCandidateDetailIsSilentWithoutCandidatesAndCountsThemOtherwise() throws {
        XCTAssertNil(ImageExportPresentation.sealCandidateDetail(count: 0))

        let one = try XCTUnwrap(ImageExportPresentation.sealCandidateDetail(count: 1))
        XCTAssertTrue(one.contains("1 red region boxed"))
        let many = try XCTUnwrap(ImageExportPresentation.sealCandidateDetail(count: 3))
        XCTAssertTrue(many.contains("3 red regions boxed"))
    }

    /// The claim boundary: candidate wording only, and no detection verb at
    /// all. "Detected", "found", or "identified" would each promise something
    /// a red-pixel scan cannot deliver, and the copy is what a buyer reads.
    /// Negations are allowed and are the point ("not confirmed seals"), so the
    /// rule is about the verbs, not about the word seal.
    func testCandidateWordingNeverClaimsACertainDetection() throws {
        let copy = [
            try XCTUnwrap(ImageExportPresentation.sealCandidateDetail(count: 2)),
            ImageExportPresentation.sealCandidateToggleHelp
        ]
        for line in copy {
            let lowered = line.lowercased()
            XCTAssertTrue(
                lowered.contains("candidate"),
                "candidate wording is the whole claim; got: \(line)"
            )
            for verb in ["detected", "identified", "found"] {
                XCTAssertFalse(
                    lowered.contains(verb),
                    "\(verb) claims a certain detection; got: \(line)"
                )
            }
        }
    }

    /// Unlocated ranges are surfaced as a WARNING, and only when there are any.
    func testUnboxedWarningIsSilentAtZeroAndWarnsOtherwise() throws {
        XCTAssertNil(ImageExportPresentation.unboxedWarning(count: 0))

        let single = try XCTUnwrap(ImageExportPresentation.unboxedWarning(count: 1))
        XCTAssertTrue(single.hasPrefix("Warning:"))
        XCTAssertTrue(single.contains("1 redacted value"))

        let plural = try XCTUnwrap(ImageExportPresentation.unboxedWarning(count: 4))
        XCTAssertTrue(plural.contains("4 redacted values"))
        XCTAssertTrue(
            plural.lowercased().contains("may still show"),
            "the warning must say what the exported image can still reveal"
        )
    }
}
