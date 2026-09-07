//
//  RestoreSourceGuardTests.swift
//  LDACoreTests
//
//  R8: what the Restore preview showed must be what the approval writes.
//
//  The preview reads the file, computes the restored text and shows it. The
//  save panel comes afterwards, deliberately, so the reader has already seen
//  what they are saving. That leaves a window in which the file can change,
//  and the writer used to reread the original URL without asking whether it
//  was still the file the preview described. The verification review measured
//  the consequence with the real preview, approval and write path:
//
//    Preview: Pay Alice USD 100.
//    Outcome: written
//    Written: Pay Alice USD 999.
//
//  The reader approved one document and a different one was written, under
//  their approval. Nothing on screen said so.
//
//  Everything here is synthetic: one placeholder name and one amount.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

final class RestoreSourceGuardTests: XCTestCase {

    private static let createdAt = "2026-09-07T00:00:00Z"
    private static let previewedSource = "Pay {PERSON_1} USD 100."
    private static let editedSource = "Pay {PERSON_1} USD 999."
    private static let value = "Alice"

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RestoreSourceGuardTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func mapping() -> Mapping {
        Mapping(
            entries: [
                "{PERSON_1}": MappingEntry(
                    token: "{PERSON_1}",
                    value: Self.value,
                    type: .person,
                    surfaceText: Self.value,
                    aliases: []
                )
            ],
            createdAtISO8601: Self.createdAt,
            sourceFile: "edited.md"
        )
    }

    private func writeSource(_ text: String) throws -> URL {
        let url = workDir.appendingPathComponent("edited.md")
        try Data(text.utf8).write(to: url)
        return url
    }

    private var outputURL: URL {
        workDir.appendingPathComponent("restored.md")
    }

    /// The real writer, so "nothing was written" is a claim about the file
    /// system rather than about a spy.
    private func realWrite(_ file: URL, _ mapping: Mapping, _ output: URL) throws -> RestoreReport {
        try LDAService.restore(editedRedacted: file, mapping: mapping, output: output)
    }

    // MARK: - The review's scenario

    /// The file is edited while the preview is pending. The approval must
    /// refuse, and write nothing at all.
    func testAnEditBetweenThePreviewAndTheApprovalRefusesAndWritesNothing() throws {
        let mapping = mapping()
        let source = try writeSource(Self.previewedSource)
        let preview = try LDAService.restorePreview(editedRedacted: source, mapping: mapping)
        XCTAssertEqual(
            preview.restoredText, "Pay Alice USD 100.",
            "fixture: the preview must be the 100 document"
        )
        let previewedFingerprint = try SourceFingerprint.of(source)

        // The edit the reader never saw.
        try Data(Self.editedSource.utf8).write(to: source)

        let outcome = RestoreApproval.run(
            file: source,
            mapping: mapping,
            preview: preview,
            previewedSource: previewedFingerprint,
            amendments: [:],
            format: .markdown,
            chooseOutput: { _, _ in self.outputURL },
            write: realWrite
        )

        guard case .failed(let error) = outcome else {
            return XCTFail(
                "a source edited since the preview must be refused, got \(outcome)"
            )
        }
        XCTAssertTrue(
            error is RestoreSourceChangedError,
            "the refusal must name the changed source, got \(error)"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outputURL.path),
            "a refused approval must write nothing"
        )
    }

    /// The ordinary case is untouched: an unchanged source writes exactly the
    /// text the reader approved.
    func testAnUnchangedSourceStillWritesExactlyThePreviewedText() throws {
        let mapping = mapping()
        let source = try writeSource(Self.previewedSource)
        let preview = try LDAService.restorePreview(editedRedacted: source, mapping: mapping)
        let previewedFingerprint = try SourceFingerprint.of(source)

        let outcome = RestoreApproval.run(
            file: source,
            mapping: mapping,
            preview: preview,
            previewedSource: previewedFingerprint,
            amendments: [:],
            format: .markdown,
            chooseOutput: { _, _ in self.outputURL },
            write: realWrite
        )

        guard case .written(let report) = outcome else {
            return XCTFail("an unchanged source must still be written, got \(outcome)")
        }
        XCTAssertEqual(report.outputURL, outputURL)
        XCTAssertEqual(
            try String(contentsOf: outputURL, encoding: .utf8),
            preview.restoredText,
            "the written file must be byte for byte what the preview showed"
        )
    }

    /// A refusal reached only after the save panel, so the reader is told
    /// rather than left with an unexplained missing file.
    func testTheRefusalIsDecidedAfterTheDestinationIsChosenAndBeforeTheWrite() throws {
        let mapping = mapping()
        let source = try writeSource(Self.previewedSource)
        let preview = try LDAService.restorePreview(editedRedacted: source, mapping: mapping)
        let previewedFingerprint = try SourceFingerprint.of(source)
        try Data(Self.editedSource.utf8).write(to: source)

        var writeCalls = 0
        var panelCalls = 0
        let outcome = RestoreApproval.run(
            file: source,
            mapping: mapping,
            preview: preview,
            previewedSource: previewedFingerprint,
            amendments: [:],
            format: .markdown,
            chooseOutput: { _, _ in
                panelCalls += 1
                return self.outputURL
            },
            write: { file, mapping, output in
                writeCalls += 1
                return try self.realWrite(file, mapping, output)
            }
        )

        guard case .failed = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertEqual(panelCalls, 1, "the reader still chose a destination")
        XCTAssertEqual(writeCalls, 0, "the writer must never be reached")
    }

    // MARK: - The sentence the reader reads

    /// The refusal has to say what to do next, in every language the app
    /// ships, or a reader outside English gets an English sentence about a
    /// file they cannot save.
    func testTheRefusalSentenceReadsAsEachShippedLanguage() {
        let english = RestorePreviewPresentation.sourceChangedRefusal(language: .english)
        XCTAssertFalse(english.isEmpty)
        for language in [
            AppLanguage.french,
            AppLanguage.simplifiedChinese,
            AppLanguage.traditionalChinese
        ] {
            let translated = RestorePreviewPresentation.sourceChangedRefusal(language: language)
            XCTAssertFalse(
                translated.isEmpty,
                "\(language.rawValue) has no sentence for a changed restore source"
            )
            XCTAssertNotEqual(
                translated, english,
                "\(language.rawValue) falls back to the English sentence"
            )
        }
        XCTAssertEqual(
            RestoreSourceChangedError().errorDescription,
            RestorePreviewPresentation.sourceChangedRefusal(),
            "the error's description must be the same sentence the sheet renders"
        )
    }
}
