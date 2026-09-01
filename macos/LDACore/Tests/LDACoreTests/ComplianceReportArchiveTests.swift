//
//  ComplianceReportArchiveTests.swift
//  LDACoreTests
//
//  The encrypted compliance report file (.ldareport).
//
//  The headline test is testCiphertextRevealsNothingAboutItsContents. The
//  report names the matter and every document it processed, and in PRC legal
//  practice those names ARE the parties, which is why SessionRecordStore
//  encrypts the record they come from. A report written in the clear undoes
//  that at the last step, in the file whose whole purpose is to be handed to
//  somebody else.
//
//  The readable pair (report.md and report.pdf) is still reachable, because a
//  regulator or a client may have no copy of LDA. It is a separate, explicit
//  call, and testReadableFilesCarryTheNamesInTheClear is what proves that
//  choosing it is what puts the names on disk.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import XCTest
@testable import LDACore

final class ComplianceReportArchiveTests: XCTestCase {

    private var workDir: URL!

    private static let passphrase = "correct horse battery staple"
    private static let createdAt = "2026-08-31T09:00:00Z"
    private static let generatedAt = "2026-08-31T10:11:12Z"

    /// Distinctive strings that must never appear in an encrypted report.
    private static let matterLabel = "Nantong Textile v. Zhang"
    private static let firstDocument = "ZhangWeiming-arbitration-notice.txt"
    private static let secondDocument = "LiXiuying-settlement-draft.docx"

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ComplianceReportArchiveTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeRecord() -> SessionRecord {
        SessionRecord(
            createdAtISO8601: Self.createdAt,
            clientLabel: Self.matterLabel,
            documents: [
                SessionRecordDocument(
                    name: Self.firstDocument,
                    entityCount: 4,
                    entityTypes: ["PERSON", "PHONE"],
                    entityCountsByType: ["PERSON": 3, "PHONE": 1]
                ),
                SessionRecordDocument(
                    name: Self.secondDocument,
                    entityCount: 2,
                    entityTypes: ["PERSON"],
                    entityCountsByType: ["PERSON": 2]
                )
            ],
            protectedValueCount: 6
        )
    }

    private func makeBundle() -> ComplianceReportBundle {
        let markdown = ComplianceReport.markdown(
            record: makeRecord(),
            generatedAtISO8601: Self.generatedAt
        )
        // A stand-in for the rendered PDF. It carries the same names, because
        // the real PDF is a rendering of the same Markdown.
        let pdf = Data(("%PDF-1.4\n" + markdown).utf8)
        return ComplianceReportBundle(markdown: markdown, pdf: pdf)
    }

    // MARK: - Leak safety

    func testCiphertextRevealsNothingAboutItsContents() throws {
        let fileURL = workDir.appendingPathComponent("report.ldareport")
        try ComplianceReportArchive.write(
            makeBundle(),
            to: fileURL,
            passphrase: Self.passphrase
        )

        let bytes = try Data(contentsOf: fileURL)
        for secret in [Self.matterLabel, Self.firstDocument, Self.secondDocument,
                       "Nantong", "ZhangWeiming", "LiXiuying",
                       "Anonymization Processing Report", "%PDF"] {
            XCTAssertNil(
                bytes.range(of: Data(secret.utf8)),
                "the encrypted report leaks \(secret)"
            )
        }
    }

    func testTheFileIsNotConfusableWithAWorkspace() throws {
        let fileURL = workDir.appendingPathComponent("report.ldareport")
        try ComplianceReportArchive.write(
            makeBundle(),
            to: fileURL,
            passphrase: Self.passphrase
        )
        let bytes = try Data(contentsOf: fileURL)
        XCTAssertEqual(Array(bytes.prefix(6)), Array("LDARPT".utf8))

        // A workspace fed to the report reader fails on the magic, which is a
        // damaged file, not a passphrase the user should retype.
        let workspaceURL = workDir.appendingPathComponent("matter.ldawork")
        try WorkspaceArchive.container.save(
            Data("not a report".utf8),
            to: workspaceURL,
            protection: .passphrase(Self.passphrase)
        )
        XCTAssertThrowsError(
            try ComplianceReportArchive.read(from: workspaceURL, passphrase: Self.passphrase)
        ) { error in
            guard case ComplianceReportArchiveError.damagedFile = error else {
                return XCTFail("expected damagedFile, got \(error)")
            }
        }
    }

    // MARK: - Round trip

    func testRoundTripReturnsTheExactBundle() throws {
        let bundle = makeBundle()
        let fileURL = workDir.appendingPathComponent("report.ldareport")
        try ComplianceReportArchive.write(bundle, to: fileURL, passphrase: Self.passphrase)

        let reopened = try ComplianceReportArchive.read(
            from: fileURL,
            passphrase: Self.passphrase
        )
        XCTAssertEqual(reopened.markdown, bundle.markdown)
        XCTAssertEqual(reopened.pdf, bundle.pdf)
    }

    func testWrongPassphraseIsReportedAsSuch() throws {
        let fileURL = workDir.appendingPathComponent("report.ldareport")
        try ComplianceReportArchive.write(
            makeBundle(),
            to: fileURL,
            passphrase: Self.passphrase
        )
        XCTAssertThrowsError(
            try ComplianceReportArchive.read(from: fileURL, passphrase: "not the passphrase")
        ) { error in
            XCTAssertEqual(error as? ComplianceReportArchiveError, .wrongPassphrase)
        }
    }

    func testAReportFromANewerFormatSaysSo() throws {
        // Seal a payload that declares a schema this build cannot read. The
        // version check must run before any other field is decoded, so the
        // user is told to update rather than told the file is damaged.
        let future = #"{"formatVersion":99,"markdown":"x","pdf":""}"#
        let fileURL = workDir.appendingPathComponent("future.ldareport")
        try ComplianceReportArchive.container.save(
            Data(future.utf8),
            to: fileURL,
            protection: .passphrase(Self.passphrase)
        )
        XCTAssertThrowsError(
            try ComplianceReportArchive.read(from: fileURL, passphrase: Self.passphrase)
        ) { error in
            XCTAssertEqual(
                error as? ComplianceReportArchiveError,
                .createdByNewerVersion(
                    found: 99,
                    supported: ComplianceReportArchive.currentFormatVersion
                )
            )
        }
    }

    // MARK: - The explicit readable pair

    func testReadableFilesCarryTheNamesInTheClear() throws {
        let bundle = makeBundle()
        let written = try ComplianceReportArchive.writeReadable(bundle, into: workDir)

        XCTAssertEqual(written.markdown.lastPathComponent, "report.md")
        XCTAssertEqual(written.pdf.lastPathComponent, "report.pdf")
        let markdown = try String(contentsOf: written.markdown, encoding: .utf8)
        XCTAssertEqual(markdown, bundle.markdown)
        // This is the whole point of the choice being explicit: the names are
        // readable to anyone holding the file.
        XCTAssertTrue(markdown.contains(Self.matterLabel))
        XCTAssertTrue(markdown.contains(Self.firstDocument))
        XCTAssertEqual(try Data(contentsOf: written.pdf), bundle.pdf)
    }

    func testSecondReadableWriteUsesPairedSuffixAndPreservesFirstPair() throws {
        let first = ComplianceReportBundle(
            markdown: "first readable report\n",
            pdf: Data("%PDF-first-readable-report".utf8)
        )
        let second = ComplianceReportBundle(
            markdown: "second readable report\n",
            pdf: Data("%PDF-second-readable-report".utf8)
        )

        let firstWritten = try ComplianceReportArchive.writeReadable(first, into: workDir)
        let secondWritten = try ComplianceReportArchive.writeReadable(second, into: workDir)

        XCTAssertEqual(firstWritten.markdown.lastPathComponent, "report.md")
        XCTAssertEqual(firstWritten.pdf.lastPathComponent, "report.pdf")
        XCTAssertEqual(secondWritten.markdown.lastPathComponent, "report_2.md")
        XCTAssertEqual(secondWritten.pdf.lastPathComponent, "report_2.pdf")
        XCTAssertEqual(
            try String(contentsOf: firstWritten.markdown, encoding: .utf8),
            first.markdown,
            "a later export must not replace the first Markdown report"
        )
        XCTAssertEqual(
            try Data(contentsOf: firstWritten.pdf),
            first.pdf,
            "a later export must not replace the first PDF report"
        )
        XCTAssertEqual(
            try String(contentsOf: secondWritten.markdown, encoding: .utf8),
            second.markdown
        )
        XCTAssertEqual(try Data(contentsOf: secondWritten.pdf), second.pdf)
    }

    func testEitherExistingReadableMemberReservesThePairName() throws {
        let bundle = makeBundle()
        for existingName in ["report.md", "report.pdf"] {
            let directory = workDir.appendingPathComponent(existingName, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let existing = directory.appendingPathComponent(existingName)
            let marker = Data("existing-file-must-survive".utf8)
            try marker.write(to: existing)

            let written = try ComplianceReportArchive.writeReadable(bundle, into: directory)

            XCTAssertEqual(written.markdown.lastPathComponent, "report_2.md")
            XCTAssertEqual(written.pdf.lastPathComponent, "report_2.pdf")
            XCTAssertEqual(
                try Data(contentsOf: existing),
                marker,
                "an existing \(existingName) must not be overwritten"
            )
        }
    }

    func testConcurrentReadablePairReservationsUseUniqueSuffixes() throws {
        let workerCount = 12
        let start = DispatchSemaphore(value: 0)
        let acquired = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let lock = NSLock()
        var names: [String] = []
        var errors: [Error] = []

        for _ in 0 ..< workerCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                start.wait()
                do {
                    let reservation = try ComplianceReportArchive.reserveReadablePair(
                        in: self.workDir
                    )
                    lock.lock()
                    names.append(reservation.markdown.lastPathComponent)
                    lock.unlock()
                    acquired.signal()
                    release.wait()
                    reservation.release()
                } catch {
                    lock.lock()
                    errors.append(error)
                    lock.unlock()
                    acquired.signal()
                }
            }
        }

        for _ in 0 ..< workerCount { start.signal() }
        for _ in 0 ..< workerCount { acquired.wait() }

        lock.lock()
        let capturedNames = names
        let capturedErrors = errors
        lock.unlock()

        XCTAssertTrue(capturedErrors.isEmpty, "reservation errors: \(capturedErrors)")
        XCTAssertEqual(capturedNames.count, workerCount)
        XCTAssertEqual(Set(capturedNames).count, workerCount)

        for _ in 0 ..< workerCount { release.signal() }
        group.wait()
    }

    func testReadableWriteSkipsSuffixHeldByConcurrentExporter() throws {
        let held = try ComplianceReportArchive.reserveReadablePair(in: workDir)
        defer { held.release() }

        let written = try ComplianceReportArchive.writeReadable(makeBundle(), into: workDir)

        XCTAssertEqual(held.markdown.lastPathComponent, "report.md")
        XCTAssertEqual(written.markdown.lastPathComponent, "report_2.md")
        XCTAssertEqual(written.pdf.lastPathComponent, "report_2.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.markdown.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.pdf.path))
    }

    func testExtractingAnEncryptedReportProducesTheReadablePair() throws {
        let bundle = makeBundle()
        let fileURL = workDir.appendingPathComponent("report.ldareport")
        try ComplianceReportArchive.write(bundle, to: fileURL, passphrase: Self.passphrase)

        let outDir = workDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let reopened = try ComplianceReportArchive.read(
            from: fileURL,
            passphrase: Self.passphrase
        )
        let written = try ComplianceReportArchive.writeReadable(reopened, into: outDir)

        XCTAssertEqual(
            try String(contentsOf: written.markdown, encoding: .utf8),
            bundle.markdown
        )
    }
}
