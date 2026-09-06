//
//  ReviewModelSourceIntegrityTests.swift
//  LDACoreTests
//
//  The review is of the text that was imported; a DOCX export re-reads the
//  file on disk to rebuild the document around the reviewed spans. Nothing
//  stops the user editing that file in Word between the scan and the export,
//  and when they do, whatever they added is copied into the "redacted"
//  document without ever having been reviewed, and every earlier edit shifts
//  the offsets the redaction is applied at.
//
//  The evidence this pins came from a probe against the real export: after
//  the source was rewritten with a second address,
//  `reviewedContainsAddedPII=false, exportedContainsAddedPII=true,
//  reportedRedactions=1` and the export succeeded.
//
//  Deterministic detection only; every fixture is built at runtime.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class ReviewModelSourceIntegrityTests: XCTestCase {

    private var workDir: URL!

    private static let reviewedEmail = "review-only@example.invalid"
    private static let addedSecret = "unreviewed-secret@example.invalid"
    private static let createdAt = "2026-09-06T00:00:00Z"

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewModelSourceIntegrityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func writeAgreement(to url: URL, appending extra: String? = nil) throws {
        var body = DocxTestPackage.paragraph(
            DocxTestPackage.run("Email \(Self.reviewedEmail).")
        )
        if let extra {
            body += DocxTestPackage.paragraph(DocxTestPackage.run(extra))
        }
        try DocxTestPackage.write(body: body, to: url)
    }

    /// Open and scan a DOCX with one email, patterns only.
    private func scannedModel(for source: URL) async throws -> ReviewModel {
        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        await model.open(source)
        await model.anonymize()
        XCTAssertTrue(model.exportAvailability.isAvailable, "fixture: the scan finished")
        XCTAssertEqual(model.entities.count, 1, "fixture: exactly the reviewed email")
        return model
    }

    private func filesWritten(to directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    // MARK: - The finding

    /// The file is edited in Word after the scan. The export must not write a
    /// document built from the edited file, because the added content was
    /// never reviewed and the reviewed offsets no longer describe it.
    func testADocxEditedAfterTheScanIsNotExported() async throws {
        let source = workDir.appendingPathComponent("synthetic.docx")
        try writeAgreement(to: source)
        let model = try await scannedModel(for: source)

        // The edit: a second, unreviewed address appears in the file.
        try writeAgreement(to: source, appending: "Bank contact: \(Self.addedSecret)")
        XCTAssertFalse(
            model.documentText.contains(Self.addedSecret),
            "premise: the reviewed text predates the edit"
        )

        let outDir = workDir.appendingPathComponent("out", isDirectory: true)
        do {
            let exported = try await model.export(
                to: outDir,
                passphrase: "SyntheticProbePassphrase",
                createdAtISO8601: Self.createdAt
            )
            let written = try DocxImporter().importDocument(exported.redactedURL).text
            XCTFail(
                "the export must refuse a source that changed after the scan; "
                    + "it wrote \(exported.redactedURL.lastPathComponent) "
                    + "containing the unreviewed address: \(written.contains(Self.addedSecret))"
            )
        } catch {
            // Refused, and the refusal says why in the words the banner uses.
            XCTAssertTrue(error is SourceChangedSinceScanError, "unexpected error: \(error)")
            XCTAssertEqual(
                error.localizedDescription,
                SaveAvailabilityPresentation.sentence(for: .sourceChangedSinceScan),
                "the one-line outcome and the standing banner must say the same thing"
            )
        }

        XCTAssertTrue(
            filesWritten(to: outDir).isEmpty,
            "a refused export leaves nothing behind: \(filesWritten(to: outDir))"
        )

        // The refusal is standing: the gate closes with the reason, so the
        // toolbar button goes dark and the banner explains it, until the
        // file is opened again.
        XCTAssertEqual(model.exportAvailability.blockReason, .sourceChangedSinceScan)
        XCTAssertNotNil(SaveAvailabilityPresentation.notice(model.exportAvailability))
    }

    /// The remedy the reason names has to be the one that works: opening the
    /// file again clears the refusal, and a scan of the reopened file exports
    /// with the added address redacted too.
    func testOpeningTheFileAgainClearsTheRefusalAndTheNewScanExports() async throws {
        let source = workDir.appendingPathComponent("reopened.docx")
        try writeAgreement(to: source)
        let model = try await scannedModel(for: source)
        try writeAgreement(to: source, appending: "Bank contact: \(Self.addedSecret)")
        let outDir = workDir.appendingPathComponent("out", isDirectory: true)
        _ = try? await model.export(to: outDir, passphrase: "SyntheticProbePassphrase", createdAtISO8601: Self.createdAt)
        XCTAssertEqual(model.exportAvailability.blockReason, .sourceChangedSinceScan, "fixture: refused")

        // A re-scan alone is NOT the remedy: it would scan the old text.
        await model.anonymize()
        XCTAssertEqual(
            model.exportAvailability.blockReason, .sourceChangedSinceScan,
            "a re-scan of the old text must not lift the refusal"
        )

        await model.open(source)
        XCTAssertEqual(
            model.exportAvailability.blockReason, .scanNotFinished,
            "opening the file again clears the refusal and asks for a scan"
        )
        await model.anonymize()
        XCTAssertEqual(model.entities.count, 2, "the reopened file's new address is found")

        let exported = try await model.export(
            to: outDir,
            passphrase: "SyntheticProbePassphrase",
            createdAtISO8601: Self.createdAt
        )
        let written = try DocxImporter().importDocument(exported.redactedURL).text
        XCTAssertFalse(written.contains(Self.addedSecret), "the added address is redacted this time")
        XCTAssertFalse(written.contains(Self.reviewedEmail))
    }

    /// The counterpart that must NOT change: a file that is exactly what was
    /// scanned still exports, and the redaction lands.
    func testAnUnchangedDocxStillExports() async throws {
        let source = workDir.appendingPathComponent("steady.docx")
        try writeAgreement(to: source)
        let model = try await scannedModel(for: source)

        let outDir = workDir.appendingPathComponent("out", isDirectory: true)
        // A passphrase gives the key a home beside the document; without one
        // (and without a workspace) export fails closed for an unrelated
        // reason, which would hide the thing this test is about.
        let exported = try await model.export(
            to: outDir,
            passphrase: "SyntheticProbePassphrase",
            createdAtISO8601: Self.createdAt
        )

        let written = try DocxImporter().importDocument(exported.redactedURL).text
        XCTAssertFalse(written.contains(Self.reviewedEmail), "the reviewed email is redacted")
        XCTAssertEqual(exported.entityCount, 1)
        XCTAssertTrue(model.exportAvailability.isAvailable, "a clean export leaves the gate open")
        XCTAssertFalse(model.sourceChangedSinceScan)
    }

    /// A plain-text export is written from the reviewed text alone, so a
    /// changed file cannot contribute to it and is not refused; what is
    /// exported is exactly what was reviewed.
    func testAPlainTextExportIsBuiltFromTheReviewedTextNotTheFile() async throws {
        let source = workDir.appendingPathComponent("notes.txt")
        try Data("Email \(Self.reviewedEmail).".utf8).write(to: source)
        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        await model.open(source)
        await model.anonymize()
        try Data("Email \(Self.reviewedEmail). Bank contact: \(Self.addedSecret)".utf8).write(to: source)

        let outDir = workDir.appendingPathComponent("out", isDirectory: true)
        let exported = try await model.export(
            to: outDir,
            passphrase: "SyntheticProbePassphrase",
            createdAtISO8601: Self.createdAt
        )

        let written = try String(contentsOf: exported.redactedURL, encoding: .utf8)
        XCTAssertFalse(written.contains(Self.addedSecret), "nothing from the changed file enters the export")
        XCTAssertFalse(written.contains(Self.reviewedEmail))
        XCTAssertTrue(model.exportAvailability.isAvailable)
    }
}
