//
//  ZipImporterTests.swift
//  LDACoreTests
//
//  Tests for .zip session import (R19): a dropped archive expands into the
//  session's documents. Junk entries (__MACOSX, dotfiles), unsupported types,
//  and path-traversal entries are skipped.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import ZIPFoundation
@testable import LDACore

final class ZipImporterTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipImporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Expansions are process-wide until a host clears them; never leak one
        // into another suite.
        ZipImporter.cleanUpAllExpansions()
        try? FileManager.default.removeItem(at: workDir)
    }

    /// Build a zip whose single entry DECLARES a huge uncompressed size while
    /// carrying almost no bytes. This is the shape of a zip bomb, and the shape
    /// the entry-size budget is meant to reject before anything is written.
    private func makeOverDeclaredZip(declaredBytes: Int64) throws -> URL {
        let zipURL = workDir.appendingPathComponent("bomb.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let data = Data(repeating: 0x41, count: 1024)
        try archive.addEntry(
            with: "payload.txt",
            type: .file,
            uncompressedSize: declaredBytes,
            provider: { position, size in
                _ = position
                return Data(repeating: 0x41, count: min(size, data.count))
            }
        )
        return zipURL
    }

    /// Build a zip at workDir/archive.zip containing the given entries.
    private func makeZip(entries: [(path: String, content: String)]) throws -> URL {
        let zipURL = workDir.appendingPathComponent("archive.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        for entry in entries {
            let data = Data(entry.content.utf8)
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            )
        }
        return zipURL
    }

    func testExpandReturnsSupportedDocuments() throws {
        let zipURL = try makeZip(entries: [
            ("contract.txt", "Acme Corp agrees."),
            ("notes.md", "# Notes"),
            ("nested/intake.txt", "John Smith intake.")
        ])

        let urls = try ZipImporter.expand(zipURL).documents

        XCTAssertEqual(urls.count, 3)
        let names = Set(urls.map { $0.lastPathComponent })
        XCTAssertEqual(names, ["contract.txt", "notes.md", "intake.txt"])
        let contract = urls.first { $0.lastPathComponent == "contract.txt" }!
        XCTAssertEqual(try String(contentsOf: contract, encoding: .utf8), "Acme Corp agrees.")
    }

    func testExpandSkipsJunkAndUnsupportedEntries() throws {
        let zipURL = try makeZip(entries: [
            ("real.txt", "keep me"),
            ("__MACOSX/real.txt", "resource fork junk"),
            (".DS_Store", "finder junk"),
            ("photo.png", "not a document"),
            ("nested/.hidden.txt", "hidden")
        ])

        let urls = try ZipImporter.expand(zipURL).documents

        XCTAssertEqual(urls.map { $0.lastPathComponent }, ["real.txt"])
    }

    func testExpandSkipsPathTraversalEntries() throws {
        let zipURL = try makeZip(entries: [
            ("../evil.txt", "escape attempt"),
            ("good.txt", "safe")
        ])

        let urls = try ZipImporter.expand(zipURL).documents

        XCTAssertEqual(urls.map { $0.lastPathComponent }, ["good.txt"])
        // Nothing may have been written outside the expansion directory.
        let escaped = workDir.deletingLastPathComponent().appendingPathComponent("evil.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    }

    func testExpandRejectsNonZip() throws {
        let notZip = workDir.appendingPathComponent("plain.zip")
        try Data("this is not an archive".utf8).write(to: notZip)
        XCTAssertThrowsError(try ZipImporter.expand(notZip))
    }

    func testIsZipByExtension() {
        XCTAssertTrue(ZipImporter.isZip(URL(fileURLWithPath: "/tmp/a.zip")))
        XCTAssertTrue(ZipImporter.isZip(URL(fileURLWithPath: "/tmp/a.ZIP")))
        XCTAssertFalse(ZipImporter.isZip(URL(fileURLWithPath: "/tmp/a.docx")))
    }

    // MARK: - Temp-directory cleanup

    func testExpansionIsRegisteredUntilCleanedUp() throws {
        let zipURL = try makeZip(entries: [("contract.txt", "Acme Corp agrees.")])
        XCTAssertEqual(ZipImporter.liveExpansionCount, 0)

        let expansion = try ZipImporter.expand(zipURL)

        XCTAssertEqual(
            ZipImporter.liveExpansionCount, 1,
            "an expansion must be tracked so a host can clear it at a session boundary"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: expansion.directory.path))
    }

    func testCleanUpRemovesTheExtractedOriginals() throws {
        let zipURL = try makeZip(entries: [("contract.txt", "Acme Corp agrees.")])
        let expansion = try ZipImporter.expand(zipURL)
        let document = try XCTUnwrap(expansion.documents.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))

        XCTAssertTrue(expansion.cleanUp())

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: document.path),
            "the user's un-redacted original must not survive the session in temp"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: expansion.directory.path))
        XCTAssertEqual(ZipImporter.liveExpansionCount, 0)
    }

    func testCleanUpIsIdempotent() throws {
        let zipURL = try makeZip(entries: [("contract.txt", "x")])
        let expansion = try ZipImporter.expand(zipURL)
        XCTAssertTrue(expansion.cleanUp())
        XCTAssertTrue(expansion.cleanUp(), "a second cleanUp is a no-op, not a failure")
    }

    func testCleanUpAllExpansionsClearsEveryArchive() throws {
        let first = try makeZip(entries: [("a.txt", "one")])
        let expansionA = try ZipImporter.expand(first)
        // A second archive at a different path so both expansions coexist.
        let secondPath = workDir.appendingPathComponent("second.zip")
        let archive = try Archive(url: secondPath, accessMode: .create)
        let data = Data("two".utf8)
        try archive.addEntry(
            with: "b.txt",
            type: .file,
            uncompressedSize: Int64(data.count),
            provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) }
        )
        let expansionB = try ZipImporter.expand(secondPath)
        XCTAssertEqual(ZipImporter.liveExpansionCount, 2)

        let removed = ZipImporter.cleanUpAllExpansions()

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(ZipImporter.liveExpansionCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expansionA.directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expansionB.directory.path))
    }

    func testARejectedExpansionLeavesNothingBehind() throws {
        let zipURL = try makeOverDeclaredZip(
            declaredBytes: Int64(ImportLimits.maxArchiveUncompressedBytes) + 1
        )

        XCTAssertThrowsError(try ZipImporter.expand(zipURL))

        XCTAssertEqual(
            ZipImporter.liveExpansionCount, 0,
            "a rejected archive must not leave a partially written expansion registered"
        )
    }

    // MARK: - Archive ceilings

    func testArchiveExceedingTheUncompressedBudgetIsRejected() throws {
        let zipURL = try makeOverDeclaredZip(
            declaredBytes: Int64(ImportLimits.maxArchiveUncompressedBytes) + 1
        )

        XCTAssertThrowsError(try ZipImporter.expand(zipURL)) { error in
            guard case DocumentIOError.tooLarge = error else {
                XCTFail("Expected tooLarge for an over-declared archive, got \(error)")
                return
            }
        }
    }

    func testArchiveWithinTheBudgetIsAccepted() throws {
        // The budget must not reject an ordinary matter bundle.
        let zipURL = try makeZip(entries: [
            ("engagement.txt", String(repeating: "a", count: 4096)),
            ("intake.md", String(repeating: "b", count: 4096))
        ])
        let expansion = try ZipImporter.expand(zipURL)
        XCTAssertEqual(expansion.documents.count, 2)
    }

    func testArchiveWithTooManyEntriesIsRejected() throws {
        let zipURL = workDir.appendingPathComponent("many.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let data = Data("x".utf8)
        for index in 0 ... ImportLimits.maxArchiveEntries {
            try archive.addEntry(
                with: "doc\(index).txt",
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) }
            )
        }

        XCTAssertThrowsError(try ZipImporter.expand(zipURL)) { error in
            guard case DocumentIOError.tooLarge = error else {
                XCTFail("Expected tooLarge for too many entries, got \(error)")
                return
            }
        }
    }
}
